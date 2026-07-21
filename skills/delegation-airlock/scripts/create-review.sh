#!/usr/bin/env bash
set -euo pipefail

# Usage: create-review.sh [slug]
# Reads /tmp/<slug>-task.md, copies its Acceptance Criteria section VERBATIM,
# and writes /tmp/review-<slug>-task.md with auto-populated frontmatter.

SLUG="${1:-}"
[ -n "$SLUG" ] || read -rp "Task slug: " SLUG

SRC="/tmp/${SLUG}-task.md"
OUT="/tmp/review-${SLUG}-task.md"

if [ ! -f "$SRC" ]; then
    echo "ERROR: task file not found: $SRC" >&2
    exit 1
fi
if [ -e "$OUT" ]; then
    echo "ERROR: $OUT already exists (parallel-dispatch collision guard)." >&2
    exit 1
fi

COUNT=$(awk -F': *' '/^acceptance_count:/ { sub(/ *#.*/, "", $2); print $2; exit }' "$SRC")
[ -n "$COUNT" ] || { echo "ERROR: no acceptance_count in $SRC frontmatter" >&2; exit 1; }

# Verbatim extraction: everything under "## Acceptance Criteria" until next H2 or EOF.
CRITERIA=$(awk '/^## Acceptance Criteria/ { f = 1; next } f && /^## / { f = 0 } f' "$SRC")
[ -n "$CRITERIA" ] || { echo "ERROR: no '## Acceptance Criteria' section in $SRC" >&2; exit 1; }

{
cat <<EOF
---
slug: review-${SLUG}
task_ref: ${SRC}
acceptance_count: ${COUNT}
---

## Acceptance Criteria (copied verbatim from task)

${CRITERIA}

## Code Style Reference

/home/codeweaver/.agents/standards/code-style.md

## Criterion Checklist

EOF
i=1
while [ "$i" -le "$COUNT" ]; do
    echo "${i}. [PASS/FAIL/BLOCKER] — evidence: <file>:<line>"
    i=$((i + 1))
done
cat <<'EOF'

## Worker Report Summary

[Paste worker's structured report here, including commit hashes for reference.]
EOF
} > "$OUT"

echo "Wrote $OUT (criteria copied verbatim from $SRC)"
echo "Paste the worker report into the summary section before dispatching the reviewer."
