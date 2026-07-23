#!/usr/bin/env bash
set -euo pipefail

# Usage: create-task.sh [slug] [title] [acceptance_count] [scope_fence]
# Missing args are prompted interactively.
# Writes /tmp/<slug>-task.md and runs delegation-validator on it.
#
# REMINDERS baked into output:
#   - Absolute paths only in the context list.
#   - Every criterion must be independently verifiable (no "as discussed above").

VALIDATOR="/home/codeweaver/.pi/agent/skills/delegation-validator/scripts/validate.sh"

SLUG="${1:-}"; TITLE="${2:-}"; COUNT="${3:-}"; FENCE="${4:-}"
[ -n "$SLUG" ]  || read -rp "Task slug (kebab-case): " SLUG
[ -n "$TITLE" ] || read -rp "Title: " TITLE
[ -n "$COUNT" ] || read -rp "Acceptance criteria count (6-17 typical): " COUNT
[ -n "$FENCE" ] || read -rp "Scope fence (riskiest mutation): " FENCE

case "$COUNT" in (''|*[!0-9]*) echo "ERROR: acceptance_count must be a number" >&2; exit 2;; esac

OUT="/tmp/${SLUG}-task.md"
if [ -e "$OUT" ]; then
    echo "ERROR: $OUT already exists (parallel-dispatch collision guard). Pick a distinct slug." >&2
    exit 1
fi

# Provenance stamp — checked by scripts/check-task-provenance.sh. This is
# what distinguishes a task file that went through the airlock from one
# hand-written straight to /tmp. Do not backfill this on hand-written files.
GENERATED_AT="$(date -Is)"

{
cat <<EOF
---
slug: ${SLUG}
title: ${TITLE}
acceptance_count: ${COUNT}
scope_fence: ${FENCE}
generated_by: delegation-airlock/create-task.sh
generated_at: ${GENERATED_AT}
---

## Context Files (Read FIRST — absolute paths)

<!-- Path-only checklist. Absolute paths MANDATORY. -->
- [ ] /absolute/path/to/file1
- [ ] /absolute/path/to/file2

## Exact Changes

[Describe mutations with precision: line numbers, old->new, semantic intent.
Each change must stand alone without prior conversation context.]

## Hard Scope Fence

Mutate only: [list files/functions]
Do NOT touch: [list files/boundaries]

## Acceptance Criteria

<!-- Each criterion must be independently verifiable.
     Evidence types: code diff | git status | API response | file presence. -->
EOF
i=1
while [ "$i" -le "$COUNT" ]; do
    echo "${i}. [Objectively checkable criterion — evidence type: code diff | git status | API response | file presence]"
    i=$((i + 1))
done
} > "$OUT"

echo "Wrote $OUT"
echo "Fill in the placeholders, then re-run the validator before dispatch:"
echo "  bash $VALIDATOR $OUT"
echo ""
bash "$VALIDATOR" "$OUT"
