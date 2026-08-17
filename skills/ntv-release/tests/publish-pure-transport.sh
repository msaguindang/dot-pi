#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SH="$SKILL_DIR/scripts/release.sh"
HELPER_SH="$TEST_DIR/helper.sh"
cat <<EOF > "$HELPER_SH"
#!/usr/bin/env bash
source "$RELEASE_SH"
get_build_id "\$1"
EOF
chmod +x "$HELPER_SH"
HELPER="$HELPER_SH"

echo "=== Testing BUILD_ID parsing (get-build-id.sh) ==="
YAML_TEST="$TEST_DIR/test.yaml"

# 1. quoted and unquoted
cat <<EOF > "$YAML_TEST"
source_build_id: "11111111-1111-1111-1111-111111111111"
s3:
  build_id: 12345678-1234-1234-1234-123456789012
EOF
[[ "$(bash "$HELPER" "$YAML_TEST")" == "12345678-1234-1234-1234-123456789012" ]] || { echo "FAIL: unquoted uuid"; exit 1; }

cat <<EOF > "$YAML_TEST"
source_build_id: "11111111-1111-1111-1111-111111111111"
s3:
  build_id: "12345678-1234-1234-1234-123456789012"
EOF
[[ "$(bash "$HELPER" "$YAML_TEST")" == "12345678-1234-1234-1234-123456789012" ]] || { echo "FAIL: quoted uuid"; exit 1; }

# 2. source-only fails
cat <<EOF > "$YAML_TEST"
source_build_id: "11111111-1111-1111-1111-111111111111"
s3:
  bucket: test
EOF
! bash "$HELPER" "$YAML_TEST" >/dev/null 2>&1 || { echo "FAIL: source-only must fail"; exit 1; }

# 3. duplicate fails
cat <<EOF > "$YAML_TEST"
s3:
  build_id: "12345678-1234-1234-1234-123456789012"
  build_id: "22345678-1234-1234-1234-123456789012"
EOF
! bash "$HELPER" "$YAML_TEST" >/dev/null 2>&1 || { echo "FAIL: duplicate must fail"; exit 1; }

# 4. empty fails
cat <<EOF > "$YAML_TEST"
s3:
  build_id: ""
EOF
! bash "$HELPER" "$YAML_TEST" >/dev/null 2>&1 || { echo "FAIL: empty must fail"; exit 1; }

# 5. malformed fails
cat <<EOF > "$YAML_TEST"
s3:
  build_id: "not-a-uuid"
EOF
! bash "$HELPER" "$YAML_TEST" >/dev/null 2>&1 || { echo "FAIL: malformed must fail"; exit 1; }

echo "=== Testing deterministic manifest ==="
GEN_SH="$SKILL_DIR/scripts/gen-checksums.sh"
REL_DIR="$TEST_DIR/release"
mkdir -p "$REL_DIR"
touch "$REL_DIR/c.zip" "$REL_DIR/a.zip" "$REL_DIR/b.sh" "$REL_DIR/a.sh"
bash "$GEN_SH" "$REL_DIR" >/dev/null
# Order must match current gen-checksums.sh expansion (*.zip *.sh)
ORDER="$(awk '{print $2}' "$REL_DIR/checksums.sha256" | tr '\n' ' ')"
[[ "$ORDER" == "a.zip c.zip a.sh b.sh " ]] || { echo "FAIL: wrong checksum manifest order: $ORDER"; exit 1; }

echo "=== Testing publisher pure transport ==="
# publisher source has no checksum generation or Git commit path in publish
if awk '/^cmd_publish\(\)/,0' "$RELEASE_SH" | grep -q "gen-checksums.sh"; then
    echo "FAIL: publisher invokes gen-checksums.sh"
    exit 1
fi
if awk '/^cmd_publish\(\)/,0' "$RELEASE_SH" | grep -q "git commit"; then
    echo "FAIL: publisher invokes git commit"
    exit 1
fi

GITOPS="$TEST_DIR/gitops"
mkdir -p "$GITOPS/player-apps/tools"
cat <<'EOF' > "$GITOPS/player-apps/tools/validate-release.sh"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$GITOPS/player-apps/tools/validate-release.sh"
cd "$GITOPS"
git init -b main >/dev/null 2>&1 || git init >/dev/null
git config user.name "Test"
git config user.email "test@test.com"

# Prepare release dir
REL_ID="2026-08-12_2.0.0-server_3.0.0-ui"
REL_DIR="$GITOPS/player-apps/releases/$REL_ID"
mkdir -p "$REL_DIR"
cat <<EOF > "$REL_DIR/release.yaml"
s3:
  build_id: "12345678-1234-1234-1234-123456789012"
EOF
echo '#!/usr/bin/env bash' > "$REL_DIR/a.sh"
touch "$REL_DIR/b.zip"
cd "$REL_DIR"
bash "$GEN_SH" . >/dev/null

# Track non-zip files
cd "$GITOPS"
git add "$REL_DIR/release.yaml" "$REL_DIR/a.sh" "$REL_DIR/checksums.sha256"
git commit --no-verify -m "commit release record" >/dev/null

# dry-run with exact untracked zips: PASS
out=$(bash "$RELEASE_SH" publish "$REL_DIR" --gitops "$GITOPS" 2>&1) || { echo "FAIL: valid dry-run rejected"; exit 1; }

# verify bytes unchanged
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "FAIL: bytes or git status mutated after dry-run"
    exit 1
fi

# add unexpected untracked file -> FAIL
touch "$REL_DIR/unexpected.txt"
! bash "$RELEASE_SH" publish "$REL_DIR" --gitops "$GITOPS" >/dev/null 2>&1 || { echo "FAIL: unexpected untracked file allowed"; exit 1; }
rm "$REL_DIR/unexpected.txt"

# modify a tracked file -> FAIL
echo "# modified" >> "$REL_DIR/a.sh"
! bash "$RELEASE_SH" publish "$REL_DIR" --gitops "$GITOPS" >/dev/null 2>&1 || { echo "FAIL: modified file allowed"; exit 1; }
git checkout -- "$REL_DIR/a.sh"

# track a zip -> FAIL
git add "$REL_DIR/b.zip"
! bash "$RELEASE_SH" publish "$REL_DIR" --gitops "$GITOPS" >/dev/null 2>&1 || { echo "FAIL: tracked zip allowed"; exit 1; }

echo "ALL TESTS PASSED"
