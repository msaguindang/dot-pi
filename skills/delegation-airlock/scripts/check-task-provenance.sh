#!/usr/bin/env bash
set -uo pipefail

# Usage: check-task-provenance.sh <task-file-path>
#
# Verifies a task file was actually produced by create-task.sh rather than
# hand-written straight to /tmp — checks the generated_by / generated_at
# frontmatter stamp create-task.sh writes into every file it generates.
#
# Run this BEFORE dispatching a worker against ANY task file. MANDATORY
# (per SKILL.md) for task files targeting release/build/QA-candidate/deploy
# work — a hand-written task file for that category is a hard stop.
#
# Exit: 0 provenance verified (PASS), 1 missing/malformed marker — file is
# hand-written or tampered with (FAIL), 2 usage error.

EXPECTED_TOOL="delegation-airlock/create-task.sh"

[ "$#" -eq 1 ] || { echo "Usage: check-task-provenance.sh <task-file-path>" >&2; exit 2; }

FILE="$1"

[ -f "$FILE" ] || { echo "FAIL: $FILE does not exist" >&2; exit 1; }

# Frontmatter is the block between the first two '---' lines.
FRONTMATTER=$(awk '/^---$/{n++; next} n==1' "$FILE")

if [ -z "$FRONTMATTER" ]; then
    echo "FAIL: $FILE has no YAML frontmatter — not produced by create-task.sh" >&2
    exit 1
fi

GENERATED_BY=$(printf '%s\n' "$FRONTMATTER" | grep -m1 '^generated_by:' | sed 's/^generated_by: *//')
GENERATED_AT=$(printf '%s\n' "$FRONTMATTER" | grep -m1 '^generated_at:' | sed 's/^generated_at: *//')

if [ -z "$GENERATED_BY" ] || [ -z "$GENERATED_AT" ]; then
    echo "FAIL: $FILE is missing generated_by/generated_at frontmatter — hand-written task file, not created via create-task.sh. Re-create with: scripts/create-task.sh <slug> <title> <count> <fence>" >&2
    exit 1
fi

if [ "$GENERATED_BY" != "$EXPECTED_TOOL" ]; then
    echo "FAIL: $FILE 'generated_by: $GENERATED_BY' does not match expected '$EXPECTED_TOOL'" >&2
    exit 1
fi

if ! [[ "$GENERATED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:?[0-9]{2}|Z)$ ]]; then
    echo "FAIL: $FILE 'generated_at: $GENERATED_AT' is not a well-formed ISO8601 timestamp" >&2
    exit 1
fi

echo "PASS: $FILE provenance verified (generated_by: $GENERATED_BY, generated_at: $GENERATED_AT)"
exit 0
