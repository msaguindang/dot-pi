#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/validate-release-metadata.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass_count=0

write_metadata() {
    local repository_path="$1"
    local version="$2"
    local heading_version="${3:-$version}"

    printf '{"name":"fixture","version":"%s"}\n' "$version" > "$repository_path/package.json"
    printf '{"name":"fixture","version":"%s","lockfileVersion":3,"packages":{"":{"name":"fixture","version":"%s"}}}\n' \
        "$version" "$version" > "$repository_path/package-lock.json"
    printf '# Changelog\n\n## [%s]\n\n- Candidate change\n' "$heading_version" > "$repository_path/CHANGELOG.md"
}

create_repository() {
    local repository_path="$1"
    local version="$2"

    mkdir -p "$repository_path"
    git -C "$repository_path" init -q
    git -C "$repository_path" config user.name 'Release Metadata Test'
    git -C "$repository_path" config user.email 'release-metadata@example.invalid'
    write_metadata "$repository_path" "$version"
    git -C "$repository_path" add package.json package-lock.json CHANGELOG.md
    git -C "$repository_path" commit -q -m "fixture: add $version metadata"
}

assert_pass() {
    local description="$1"
    shift
    if output="$("$@" 2>&1)"; then
        echo "PASS: $description"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $description" >&2
        echo "$output" >&2
        exit 1
    fi
}

assert_fail() {
    local description="$1"
    shift
    if output="$("$@" 2>&1)"; then
        echo "FAIL: $description (unexpected success)" >&2
        exit 1
    else
        echo "PASS: $description"
        pass_count=$((pass_count + 1))
    fi
}

stable_repo="$TMP_DIR/valid-stable"
create_repository "$stable_repo" '1.2.3'
assert_pass 'valid stable metadata' "$VALIDATOR" "$stable_repo" '1.2.3'

zero_repo="$TMP_DIR/valid-zero"
create_repository "$zero_repo" '0.0.0'
assert_pass 'valid zero-valued stable metadata' "$VALIDATOR" "$zero_repo" '0.0.0'

rc_zero_repo="$TMP_DIR/valid-rc-zero"
create_repository "$rc_zero_repo" '1.2.3-rc.0'
assert_pass 'valid zero-valued RC identifier' "$VALIDATOR" "$rc_zero_repo" '1.2.3-rc.0'

leading_zero_major_repo="$TMP_DIR/leading-zero-major"
create_repository "$leading_zero_major_repo" '01.2.3'
assert_fail 'leading-zero major version' "$VALIDATOR" "$leading_zero_major_repo" '01.2.3'

leading_zero_minor_repo="$TMP_DIR/leading-zero-minor"
create_repository "$leading_zero_minor_repo" '1.02.3'
assert_fail 'leading-zero minor version' "$VALIDATOR" "$leading_zero_minor_repo" '1.02.3'

leading_zero_patch_repo="$TMP_DIR/leading-zero-patch"
create_repository "$leading_zero_patch_repo" '1.2.03'
assert_fail 'leading-zero patch version' "$VALIDATOR" "$leading_zero_patch_repo" '1.2.03'

leading_zero_rc_repo="$TMP_DIR/leading-zero-rc"
create_repository "$leading_zero_rc_repo" '1.2.3-rc.01'
assert_fail 'leading-zero RC identifier' "$VALIDATOR" "$leading_zero_rc_repo" '1.2.3-rc.01'

rc_repo="$TMP_DIR/valid-rc"
create_repository "$rc_repo" '1.2.3'
rc_base="$(git -C "$rc_repo" rev-parse HEAD)"
write_metadata "$rc_repo" '1.2.4-rc.1'
printf '# Changelog\n\n## [1.2.4-rc.1] - 2026-07-30\n\n- Candidate change\n' > "$rc_repo/CHANGELOG.md"
git -C "$rc_repo" add package.json package-lock.json CHANGELOG.md
git -C "$rc_repo" commit -q -m 'fixture: add release candidate metadata'
assert_pass 'valid RC metadata with committed changelog change relative to base' \
    "$VALIDATOR" "$rc_repo" '1.2.4-rc.1' "$rc_base"

missing_heading_repo="$TMP_DIR/missing-heading"
create_repository "$missing_heading_repo" '1.2.3'
printf '# Changelog\n\n## [1.2.30]\n' > "$missing_heading_repo/CHANGELOG.md"
git -C "$missing_heading_repo" add CHANGELOG.md
git -C "$missing_heading_repo" commit -q -m 'fixture: use substring-only heading'
assert_fail 'missing exact heading rejects substring-only heading' \
    "$VALIDATOR" "$missing_heading_repo" '1.2.3'

stale_lock_repo="$TMP_DIR/stale-lock"
create_repository "$stale_lock_repo" '1.2.3'
# JavaScript template literal is intentionally single-quoted for Bash.
# shellcheck disable=SC2016
node -e '
const fs = require("fs");
const file = process.argv[1];
const lock = JSON.parse(fs.readFileSync(file, "utf8"));
lock.version = "1.2.2";
fs.writeFileSync(file, `${JSON.stringify(lock)}\n`);
' "$stale_lock_repo/package-lock.json"
git -C "$stale_lock_repo" add package-lock.json
git -C "$stale_lock_repo" commit -q -m 'fixture: stale lock version'
assert_fail 'stale lock version' "$VALIDATOR" "$stale_lock_repo" '1.2.3'

dirty_repo="$TMP_DIR/dirty-changelog"
create_repository "$dirty_repo" '1.2.3'
printf '\n- Uncommitted change\n' >> "$dirty_repo/CHANGELOG.md"
assert_fail 'uncommitted changelog' "$VALIDATOR" "$dirty_repo" '1.2.3'

staged_repo="$TMP_DIR/staged-changelog"
create_repository "$staged_repo" '1.2.3'
printf '\n- Staged change\n' >> "$staged_repo/CHANGELOG.md"
git -C "$staged_repo" add CHANGELOG.md
assert_fail 'staged changelog' "$VALIDATOR" "$staged_repo" '1.2.3'

root_lock_repo="$TMP_DIR/stale-root-lock"
create_repository "$root_lock_repo" '1.2.3'
# JavaScript template literal is intentionally single-quoted for Bash.
# shellcheck disable=SC2016
node -e '
const fs = require("fs");
const file = process.argv[1];
const lock = JSON.parse(fs.readFileSync(file, "utf8"));
lock.packages[""].version = "1.2.2";
fs.writeFileSync(file, `${JSON.stringify(lock)}\n`);
' "$root_lock_repo/package-lock.json"
git -C "$root_lock_repo" add package-lock.json
git -C "$root_lock_repo" commit -q -m 'fixture: stale root lock version'
assert_fail 'stale lock packages root version' "$VALIDATOR" "$root_lock_repo" '1.2.3'

unchanged_repo="$TMP_DIR/unchanged-changelog"
create_repository "$unchanged_repo" '1.2.3'
unchanged_base="$(git -C "$unchanged_repo" rev-parse HEAD)"
printf 'fixture\n' > "$unchanged_repo/README.md"
git -C "$unchanged_repo" add README.md
git -C "$unchanged_repo" commit -q -m 'fixture: unrelated branch change'
assert_fail 'unchanged changelog relative to supplied base' \
    "$VALIDATOR" "$unchanged_repo" '1.2.3' "$unchanged_base"

untracked_repo="$TMP_DIR/untracked-metadata"
mkdir -p "$untracked_repo"
git -C "$untracked_repo" init -q
git -C "$untracked_repo" config user.name 'Release Metadata Test'
git -C "$untracked_repo" config user.email 'release-metadata@example.invalid'
printf 'tracked fixture\n' > "$untracked_repo/README.md"
git -C "$untracked_repo" add README.md
git -C "$untracked_repo" commit -q -m 'fixture: initialize repository'
write_metadata "$untracked_repo" '1.2.3'
assert_fail 'untracked required metadata' "$VALIDATOR" "$untracked_repo" '1.2.3'

assert_fail 'invalid base ref' "$VALIDATOR" "$stable_repo" '1.2.3' 'missing/base-ref'
assert_fail 'malformed expected version' "$VALIDATOR" "$stable_repo" '1.2'
assert_fail 'non-RC prerelease expected version' "$VALIDATOR" "$stable_repo" '1.2.3-beta.1'

echo "All $pass_count release metadata validation tests passed."
