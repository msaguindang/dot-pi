#!/usr/bin/env bash
# gen-checksums.sh — generate checksums.sha256 for a release directory.
# Covers *.zip and *.sh (the files that get uploaded to S3). release.yaml and
# *.md are gitops records, not S3 artifacts, and are not checksummed
# (matches existing releases in fleet-gitops).
#
# Usage: gen-checksums.sh <release-dir>
set -euo pipefail

DIR="${1:?Usage: gen-checksums.sh <release-dir>}"
[[ -d "$DIR" ]] || { echo "ERROR: not a directory: $DIR" >&2; exit 1; }

cd "$DIR"
rm -f checksums.sha256

files=()
for f in *.zip *.sh; do
    [[ -f "$f" ]] && files+=("$f")
done

if [[ ${#files[@]} -eq 0 ]]; then
    echo "ERROR: no *.zip or *.sh files in $DIR — nothing to checksum." >&2
    exit 1
fi

sha256sum "${files[@]}" > checksums.sha256

# Sanity: every line must be <64-hex>  <filename>
while IFS= read -r line; do
    if ! [[ "$line" =~ ^[0-9a-f]{64}\ \ .+$ ]]; then
        echo "ERROR: malformed checksum line: $line" >&2
        exit 1
    fi
done < checksums.sha256

echo "Wrote $(wc -l < checksums.sha256) checksums to $DIR/checksums.sha256"
sha256sum --check --quiet checksums.sha256
echo "Self-check passed."
