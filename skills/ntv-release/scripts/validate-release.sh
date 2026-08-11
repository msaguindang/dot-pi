#!/usr/bin/env bash
# validate-release.sh — 5-stage release validation + S3 presence/content check.
#
# Stages 1–5 (files present, sha256sum --check, YAML parse, bash -n, deploy-script
# lint — the lint stage was added 2026-08-11) are delegated to fleet-gitops' own
# validator — the source of truth:
#   <gitops>/player-apps/tools/validate-release.sh
# Stage 6 (this script) verifies every checksummed file is present in
# s3://ncompasstv-prod-player-apps/secure-rc/<BUILD_ID>/ via `aws s3 ls`, then
# re-derives/compares content hashes against the uploaded bytes (not just
# filename presence) via `aws s3api head-object` ETag-vs-local-MD5, falling
# back to a streamed `aws s3 cp - | sha256sum` for any object whose ETag
# indicates a multipart upload (ETag containing '-', not a plain MD5).
#
# Usage:
#   validate-release.sh <release-dir | BUILD_ID> [--local-only] [--gitops <path>]
#
# --local-only  skip the S3 stage (use before upload).
#
# Exit 0 on PASS, non-zero on FAIL.
# Evidence log: /tmp/validate-<BUILD_ID>.log
set -euo pipefail

GITOPS="${NTV_GITOPS:-/data/dev/work/ntv/fleet-gitops}"
LOCAL_ONLY=false
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-only) LOCAL_ONLY=true; shift ;;
        --gitops) GITOPS="${2:?--gitops needs a path}"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -16; exit 0 ;;
        *) TARGET="$1"; shift ;;
    esac
done

[[ -n "$TARGET" ]] || { echo "ERROR: release-dir or BUILD_ID required." >&2; exit 1; }

RELEASES_DIR="$GITOPS/player-apps/releases"
UPSTREAM_VALIDATOR="$GITOPS/player-apps/tools/validate-release.sh"
[[ -f "$UPSTREAM_VALIDATOR" ]] || { echo "ERROR: fleet-gitops validator not found: $UPSTREAM_VALIDATOR" >&2; exit 1; }

# --- Resolve target: directory path, or BUILD_ID looked up in releases/ ---
if [[ -d "$TARGET" ]]; then
    RELEASE_DIR="$(cd "$TARGET" && pwd)"
else
    match="$(grep -rl "build_id: $TARGET" "$RELEASES_DIR"/*/release.yaml 2>/dev/null | head -1 || true)"
    [[ -n "$match" ]] || { echo "ERROR: no release dir found for BUILD_ID '$TARGET' under $RELEASES_DIR" >&2; exit 1; }
    RELEASE_DIR="$(dirname "$match")"
fi

BUILD_ID="$(grep 'build_id:' "$RELEASE_DIR/release.yaml" | head -1 | awk '{print $2}' | tr -d '\"')"
[[ -n "$BUILD_ID" ]] || { echo "ERROR: no build_id in $RELEASE_DIR/release.yaml" >&2; exit 1; }

LOG="/tmp/validate-${BUILD_ID}.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== ntv-release validation ==="
echo "Release dir: $RELEASE_DIR"
echo "BUILD_ID:    $BUILD_ID"
echo "Log:         $LOG"
echo ""

FAIL=0

# --- Stages 1–5: fleet-gitops validator (files, checksums, yaml, bash -n, lint) ---
echo "--- Stages 1-5: fleet-gitops validate-release.sh ---"
if bash "$UPSTREAM_VALIDATOR" "$RELEASE_DIR"; then
    echo "[PASS] local validation (files/checksums/yaml/bash -n)"
else
    echo "[FAIL] local validation"
    FAIL=1
fi
echo ""

# --- Stage 6: S3 presence ---
if [[ "$LOCAL_ONLY" == "true" ]]; then
    echo "--- Stage 6: S3 presence — SKIPPED (--local-only) ---"
else
    echo "--- Stage 6: S3 presence (aws s3 ls) ---"
    if ! command -v aws >/dev/null 2>&1; then
        echo "[FAIL] aws CLI not found — cannot verify S3."
        FAIL=1
    else
        S3_BUCKET="ncompasstv-prod-player-apps"
        S3_PREFIX="s3://${S3_BUCKET}/secure-rc/${BUILD_ID}/"
        listing="$(aws s3 ls "$S3_PREFIX" 2>&1 || true)"
        echo "$listing"
        # Every checksummed file + checksums.sha256 must be present in S3.
        while IFS= read -r fname; do
            if grep -q " ${fname}\$" <<< "$listing"; then
                echo "[OK]   in S3: $fname"
            else
                echo "[FAIL] MISSING in S3: $fname"
                FAIL=1
            fi
        done < <(awk '{print $2}' "$RELEASE_DIR/checksums.sha256"; echo "checksums.sha256")
    fi
fi
echo ""

# --- Stage 6b: S3 content verification (uploaded bytes vs checksums.sha256) -
# Presence (stage 6) only proves a same-named object exists — not that its
# bytes match what was checksummed locally. For each checksummed artifact,
# pull the live object's ETag via head-object. A plain (non-multipart) S3
# upload's ETag is the object's raw MD5 hex, so it's compared against a local
# md5sum without downloading. `release.sh`'s upload is a single `aws s3 cp`
# per file (no --checksum-algorithm), and current artifact sizes (~1.4MB
# server zip, ~0.5MB UI zip, plain-text shell scripts) sit far under the AWS
# CLI's default 8MiB multipart threshold, so plain PutObject/MD5 ETags are
# expected in practice. Multipart ETags (containing '-') are still detected
# and handled: fall back to a streamed `aws s3 cp - | sha256sum` compared
# against the recorded sha256, since a multipart ETag is not a usable hash.
if [[ "$LOCAL_ONLY" == "true" ]]; then
    echo "--- Stage 6b: S3 content verification — SKIPPED (--local-only) ---"
elif ! command -v aws >/dev/null 2>&1; then
    : # already reported as [FAIL] in stage 6 above
else
    echo "--- Stage 6b: S3 content verification (head-object ETag / streamed sha256 fallback) ---"
    while IFS=$'\t' read -r sha256 fname; do
        [[ -n "$fname" ]] || continue
        key="secure-rc/${BUILD_ID}/${fname}"
        # `if ! var=$(cmd)` (not a bare assignment) so a failing head-object
        # is caught here instead of tripping `set -e` and killing the script.
        if ! etag_raw="$(aws s3api head-object --bucket "$S3_BUCKET" --key "$key" --query 'ETag' --output text 2>&1)" || [[ -z "$etag_raw" ]]; then
            echo "[FAIL] head-object failed for $fname: $etag_raw"
            FAIL=1
            continue
        fi
        etag="${etag_raw//\"/}"
        if [[ "$etag" == *-* ]]; then
            # Multipart upload — ETag is not a content hash. Fall back to a
            # streamed download + sha256 compared against the recorded hash.
            # Same set -e/pipefail guard as above.
            if ! remote_sha="$(aws s3 cp "s3://${S3_BUCKET}/${key}" - 2>/dev/null | sha256sum | awk '{print $1}')"; then
                remote_sha=""
            fi
            if [[ -n "$remote_sha" && "$remote_sha" == "$sha256" ]]; then
                echo "[OK]   content verified (multipart, streamed sha256): $fname"
            else
                echo "[FAIL] CONTENT MISMATCH (multipart, streamed sha256): $fname (expected $sha256, got ${remote_sha:-<empty>})"
                FAIL=1
            fi
        else
            if ! local_md5="$(md5sum "$RELEASE_DIR/$fname" | awk '{print $1}')"; then
                local_md5=""
            fi
            if [[ "$etag" == "$local_md5" ]]; then
                echo "[OK]   content verified (ETag==MD5): $fname"
            else
                echo "[FAIL] CONTENT MISMATCH (ETag==MD5): $fname (local md5 $local_md5, S3 ETag $etag)"
                FAIL=1
            fi
        fi
    done < <(awk '{print $1"\t"$2}' "$RELEASE_DIR/checksums.sha256")
fi
echo ""

if [[ "$FAIL" -eq 0 ]]; then
    echo "RESULT: PASS — evidence in $LOG"
    exit 0
else
    echo "RESULT: FAIL — evidence in $LOG"
    exit 1
fi
