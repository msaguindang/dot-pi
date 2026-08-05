#!/usr/bin/env bash
set -euo pipefail

# Usage: validate_handoff.sh <handoff_doc.md>
# Lints a handoff document against ~/.agents/standards/handoff-doc-standard.md:
#   1. All mandatory sections present (parsed live from the standard, not hardcoded).
#   2. Every CONFIRMED bullet carries an evidence-source indicator.
#   3. No relative paths (./ ../ ~/) anywhere in the doc.
#
# Exit codes:
#   0: doc is clean.
#   1: one or more lint failures found.
#   2: invalid usage / files unreadable / standard unparsable.

STANDARD="${HANDOFF_STANDARD:-$HOME/.agents/standards/handoff-doc-standard.md}"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <handoff_doc.md>" >&2
    exit 2
fi

DOC="$1"

if [ ! -f "$DOC" ] || [ ! -r "$DOC" ]; then
    echo "Error: cannot read handoff doc: $DOC" >&2
    exit 2
fi

if [ ! -f "$STANDARD" ] || [ ! -r "$STANDARD" ]; then
    echo "Error: cannot read standard: $STANDARD" >&2
    exit 2
fi

FAIL=0

# --- 1. Required sections, parsed live from the standard's numbered list ---
# e.g. "1. **Ignition Block** — a ready-to-copy-paste prompt..."
mapfile -t SECTIONS < <(
    awk '/^## Required Sections/{f=1; next} /^## /{f=0} f' "$STANDARD" \
        | grep -oP '^\d+\.\s+\*\*\K[^*]+(?=\*\*)'
)

if [ "${#SECTIONS[@]}" -eq 0 ]; then
    echo "Error: could not parse required sections from $STANDARD" >&2
    exit 2
fi

DOC_HEADINGS=$(grep -nE '^#{1,6}[[:space:]]' "$DOC" || true)

echo "== Section check (against $STANDARD) =="
for section in "${SECTIONS[@]}"; do
    # Keyword = section name with any trailing parenthetical/em-dash stripped.
    keyword=$(echo "$section" | sed -E 's/[[:space:]]*[—(].*//')

    if [[ "$keyword" == *"CONFIRMED"* && "$keyword" == *"ASSUMED"* ]]; then
        # In practice this combined section is split into two headings.
        has_confirmed=$(echo "$DOC_HEADINGS" | grep -ciF "CONFIRMED" || true)
        has_assumed=$(echo "$DOC_HEADINGS" | grep -ciF "ASSUMED" || true)
        if [ "$has_confirmed" -eq 0 ] || [ "$has_assumed" -eq 0 ]; then
            echo "MISSING: \"$section\" (need headings covering both CONFIRMED and ASSUMED)"
            FAIL=1
        else
            echo "OK: $section"
        fi
        continue
    fi

    if echo "$DOC_HEADINGS" | grep -qiF "$keyword"; then
        echo "OK: $section"
    else
        echo "MISSING: \"$section\""
        FAIL=1
    fi
done

# --- 2. CONFIRMED items need an evidence-source indicator ---
# Convention per tool-policy.md §4 (evidence_source: tag) plus what the
# exemplar handoffs actually use: an inline "Evidence:" citation, a
# `file:line` / "line N" reference, a commit hash, a URL, or a screenshot.
echo ""
echo "== CONFIRMED evidence check =="
EVIDENCE_RE='evidence_source:|evidence:|`[0-9a-f]{7,40}`|~?line[[:space:]]*[0-9]|`[^`]+`.*:[0-9]|screenshot|https?://'

CONFIRMED_START=$(echo "$DOC_HEADINGS" | grep -iF "CONFIRMED" | head -1 | cut -d: -f1 || true)
if [ -z "${CONFIRMED_START:-}" ]; then
    echo "SKIPPED: no CONFIRMED heading found"
else
    CONFIRMED_END=$(echo "$DOC_HEADINGS" | awk -F: -v start="$CONFIRMED_START" '$1>start{print $1; exit}')
    if [ -z "$CONFIRMED_END" ]; then
        CONFIRMED_END=$(wc -l < "$DOC")
    else
        CONFIRMED_END=$((CONFIRMED_END - 1))
    fi
    # Combined "CONFIRMED vs ASSUMED" heading (one heading, bold sub-labels
    # e.g. "**ASSUMED:**") — clip the range at the ASSUMED sub-label so its
    # bullets aren't mistaken for unlabeled CONFIRMED claims.
    ASSUMED_MARKER=$(awk -v start="$CONFIRMED_START" -v end="$CONFIRMED_END" \
        'NR>start && NR<=end && /ASSUMED/ {print NR; exit}' "$DOC")
    if [ -n "$ASSUMED_MARKER" ]; then
        CONFIRMED_END=$((ASSUMED_MARKER - 1))
    fi

    UNLABELED=0
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"
        text="${hit#*:}"
        if ! echo "$text" | grep -qiE "$EVIDENCE_RE"; then
            echo "UNLABELED (line $lineno): ${text:0:110}"
            UNLABELED=1
            FAIL=1
        fi
    done < <(awk -v start="$CONFIRMED_START" -v end="$CONFIRMED_END" \
        'NR>start && NR<=end && /^[[:space:]]*-[[:space:]]/ {print NR":"$0}' "$DOC")

    if [ "$UNLABELED" -eq 0 ]; then
        echo "OK: every CONFIRMED item carries an evidence-source indicator"
    fi
fi

# --- 3. No relative paths (./  ../  ~/) ---
echo ""
echo "== Relative path check =="
REL_RE='(^|[[:space:](`])\.\./|(^|[[:space:](`])\./|~/'
REL_HITS=$(grep -nE "$REL_RE" "$DOC" || true)
if [ -n "$REL_HITS" ]; then
    while IFS= read -r hit; do
        lineno="${hit%%:*}"
        text="${hit#*:}"
        echo "RELATIVE PATH (line $lineno): ${text:0:110}"
    done <<< "$REL_HITS"
    FAIL=1
else
    echo "OK: no relative paths found"
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
    echo "FAIL: $DOC does not meet the handoff doc standard." >&2
    exit 1
fi

echo "OK: $DOC meets the handoff doc standard."
exit 0
