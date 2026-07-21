#!/usr/bin/env bash
set -euo pipefail
GIT_TERMINAL_PROMPT=0

THRESHOLD=500
FORCE=false

# Handle --force flag
if [[ "${2:-}" == "--force" ]]; then
    FORCE=true
    INPUT=$1
else
    INPUT=$1
fi

# Count total changes (additions + deletions)
if [[ "$INPUT" =~ ^[0-9a-f]{40}$ ]]; then
    NUMSTAT=$(git diff --numstat "$INPUT"^! --)
else
    NUMSTAT=$(git diff --numstat origin/next..."$INPUT" --)
fi

TOTAL_LINES=$(echo "$NUMSTAT" | awk '{s+=$1+$2} END {print s+0}')

if [ "$TOTAL_LINES" -gt "$THRESHOLD" ] && [ "$FORCE" = false ]; then
    echo "Massive PR detected ($TOTAL_LINES lines). Aborting execution to prevent token overflow. Run with --force to override." >&2
    exit 1
fi

# Get Diff and Files
if [[ "$INPUT" =~ ^[0-9a-f]{40}$ ]]; then
    DIFF=$(git diff "$INPUT"^! --)
    FILES=$(git show --stat "$INPUT" | tail -n +5)
else
    DIFF=$(git diff origin/next..."$INPUT" --)
    FILES=$(git diff --name-only origin/next..."$INPUT" --)
fi

# Truncate diff to ~800 lines
LINE_COUNT=$(echo "$DIFF" | wc -l)
echo "$DIFF" | head -n 800

if [ "$LINE_COUNT" -gt 800 ]; then
    echo -e "\n[WARNING: Diff truncated (800 of $LINE_COUNT lines shown)]" >&2
fi
