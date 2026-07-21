#!/usr/bin/env bash
set -euo pipefail

# Usage: validate.sh <prompt_string_or_file_path>
# Scans a delegation task prompt for relative context references.

# Suspicious phrases (lowercase, pipe-separated for grep -E)
SUSPICIOUS_PATTERNS=(
    "previously discussed"
    "as above"
    "as specified"
    "as mentioned"
    "the spec we agreed on"
    "the plan from earlier"
    "per the prior"
    "as you know"
    "from before"
)

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <prompt_string_or_file_path>" >&2
    exit 2
fi

INPUT="$1"

# If input is a file path and exists, read it; otherwise treat as string
if [ -f "$INPUT" ] && [ -r "$INPUT" ]; then
    PROMPT_TEXT=$(cat "$INPUT")
else
    PROMPT_TEXT="$INPUT"
fi

# Convert to lowercase for case-insensitive matching
PROMPT_LOWER=$(echo "$PROMPT_TEXT" | tr '[:upper:]' '[:lower:]')

FOUND=0
MATCHES=()

for pattern in "${SUSPICIOUS_PATTERNS[@]}"; do
    if echo "$PROMPT_LOWER" | grep -qF "$pattern"; then
        FOUND=1
        MATCHES+=("$pattern")
    fi
done

if [ "$FOUND" -eq 1 ]; then
    echo "WARNING: Suspicious relative context references detected:" >&2
    for match in "${MATCHES[@]}"; do
        echo "  - \"$match\"" >&2
    done
    echo "" >&2
    echo "Forked subagents cannot access parent session memory." >&2
    echo "Materialize referenced content to a file or inline it in the task prompt." >&2
    exit 1
fi

echo "OK: No suspicious relative context references found."
exit 0
