#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || fail "usage: ${0##*/} <repository-path> <expected-version> [base-ref]"

REPOSITORY_PATH="$1"
EXPECTED_VERSION="$2"
BASE_REF="${3:-}"

[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
    || fail "expected version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rc.N: $EXPECTED_VERSION"
[[ -d "$REPOSITORY_PATH" ]] || fail "repository path does not exist: $REPOSITORY_PATH"
git -C "$REPOSITORY_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "not a Git worktree: $REPOSITORY_PATH"

REQUIRED_FILES=(package.json package-lock.json CHANGELOG.md)
for file_path in "${REQUIRED_FILES[@]}"; do
    [[ -f "$REPOSITORY_PATH/$file_path" ]] \
        || fail "required release metadata file is missing: $REPOSITORY_PATH/$file_path"
done

# JavaScript template literals are intentionally single-quoted for Bash.
# shellcheck disable=SC2016
package_version="$(node -e '
const fs = require("fs");
const file = process.argv[1];
try {
    const value = JSON.parse(fs.readFileSync(file, "utf8")).version;
    if (typeof value !== "string") throw new Error("version is not a string");
    process.stdout.write(value);
} catch (error) {
    console.error(`ERROR: cannot read package version from ${file}: ${error.message}`);
    process.exit(1);
}
' "$REPOSITORY_PATH/package.json")"
[[ "$package_version" == "$EXPECTED_VERSION" ]] \
    || fail "package.json.version is $package_version, expected $EXPECTED_VERSION"

# JavaScript template literals are intentionally single-quoted for Bash.
# shellcheck disable=SC2016
node -e '
const fs = require("fs");
const file = process.argv[1];
const expected = process.argv[2];
try {
    const lock = JSON.parse(fs.readFileSync(file, "utf8"));
    if (lock.version !== expected) {
        throw new Error(`top-level version is ${String(lock.version)}, expected ${expected}`);
    }
    const rootVersion = lock.packages?.[""]?.version;
    if (rootVersion !== undefined && rootVersion !== expected) {
        throw new Error(`packages[""].version is ${String(rootVersion)}, expected ${expected}`);
    }
} catch (error) {
    console.error(`ERROR: invalid release version in ${file}: ${error.message}`);
    process.exit(1);
}
' "$REPOSITORY_PATH/package-lock.json" "$EXPECTED_VERSION"

# JavaScript template literals are intentionally single-quoted for Bash.
# shellcheck disable=SC2016
node -e '
const fs = require("fs");
const file = process.argv[1];
const version = process.argv[2];
const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const heading = new RegExp(`^## \\[${escaped}\\](?: - .+)?$`, "m");
if (!heading.test(fs.readFileSync(file, "utf8"))) {
    console.error(`ERROR: ${file} lacks an exact level-2 heading for [${version}]`);
    process.exit(1);
}
' "$REPOSITORY_PATH/CHANGELOG.md" "$EXPECTED_VERSION"

for file_path in "${REQUIRED_FILES[@]}"; do
    git -C "$REPOSITORY_PATH" ls-files --error-unmatch -- "$file_path" >/dev/null 2>&1 \
        || fail "required release metadata is untracked: $file_path"
    git -C "$REPOSITORY_PATH" diff --quiet -- "$file_path" \
        || fail "required release metadata has unstaged changes: $file_path"
    git -C "$REPOSITORY_PATH" diff --cached --quiet -- "$file_path" \
        || fail "required release metadata has staged changes: $file_path"
done

if [[ -n "$BASE_REF" ]]; then
    git -C "$REPOSITORY_PATH" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null \
        || fail "base ref does not resolve to a commit: $BASE_REF"
    changelog_changes="$(git -C "$REPOSITORY_PATH" diff --name-only "$BASE_REF...HEAD" -- CHANGELOG.md)"
    [[ "$changelog_changes" == "CHANGELOG.md" ]] \
        || fail "CHANGELOG.md is not committed in the $BASE_REF...HEAD change set"
fi

echo "Release metadata valid: $REPOSITORY_PATH @ $EXPECTED_VERSION"
