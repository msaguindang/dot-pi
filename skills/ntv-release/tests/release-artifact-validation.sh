#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/ntv-release/scripts/release.sh
source "$SCRIPT_DIR/../scripts/release.sh"

for tool in zip unzip stat truncate; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "FAIL: required test tool not found: $tool" >&2
        exit 1
    }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

UI_VERSION="3.0.50"
VALID_SERVER_ZIP="$TMP_DIR/player-server-2.10.2.zip"
SMALL_SERVER_ZIP="$TMP_DIR/player-server-small.zip"
VALID_UI_ZIP="$TMP_DIR/player-ui-${UI_VERSION}.zip"
CORRUPT_UI_ZIP="$TMP_DIR/player-ui-corrupt.zip"
WRONG_LAYOUT_UI_ZIP="$TMP_DIR/player-ui-wrong-layout.zip"

mkdir -p "$TMP_DIR/valid/player-ui-${UI_VERSION}" "$TMP_DIR/wrong/player-ui-wrong"
printf '<html></html>\n' > "$TMP_DIR/valid/player-ui-${UI_VERSION}/index.html"
printf '<html></html>\n' > "$TMP_DIR/wrong/player-ui-wrong/index.html"
(
    cd "$TMP_DIR/valid"
    zip -q "$VALID_UI_ZIP" "player-ui-${UI_VERSION}/index.html"
)
(
    cd "$TMP_DIR/wrong"
    zip -q "$WRONG_LAYOUT_UI_ZIP" "player-ui-wrong/index.html"
)
printf 'not a zip\n' > "$CORRUPT_UI_ZIP"
truncate -s 1048577 "$VALID_SERVER_ZIP"
truncate -s 1048575 "$SMALL_SERVER_ZIP"

[[ "$(stat -c%s "$VALID_UI_ZIP")" -lt 1048576 ]] || {
    echo "FAIL: valid UI fixture must remain below 1 MiB" >&2
    exit 1
}

assert_pass() {
    local description="$1"
    shift
    if ("$@"); then
        echo "PASS: $description"
    else
        echo "FAIL: $description" >&2
        exit 1
    fi
}

assert_fail() {
    local description="$1"
    shift
    if ("$@") >/dev/null 2>&1; then
        echo "FAIL: $description" >&2
        exit 1
    else
        echo "PASS: $description"
    fi
}

assert_pass "valid sub-1-MiB UI artifact passes" \
    validate_release_artifacts "$VALID_SERVER_ZIP" "$VALID_UI_ZIP" "$UI_VERSION"
assert_fail "corrupt UI artifact fails" \
    validate_release_artifacts "$VALID_SERVER_ZIP" "$CORRUPT_UI_ZIP" "$UI_VERSION"
assert_fail "wrong-layout UI artifact fails" \
    validate_release_artifacts "$VALID_SERVER_ZIP" "$WRONG_LAYOUT_UI_ZIP" "$UI_VERSION"
assert_fail "sub-1-MiB server artifact fails" \
    validate_release_artifacts "$SMALL_SERVER_ZIP" "$VALID_UI_ZIP" "$UI_VERSION"
