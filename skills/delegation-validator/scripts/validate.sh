#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   validate.sh <prompt_string_or_file_path>            Single-task mode: scans for
#                                                        relative context phrases; warns
#                                                        (non-fatal) if a file has no
#                                                        declared output.path.
#   validate.sh --batch <task-file-1> [task-file-2 ...]  Batch mode: extracts each task
#                                                        file's output.path and fails if
#                                                        two or more collide.

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

# --- shared helpers for output.path extraction (used by both modes) ---

# Print the YAML frontmatter block (lines between the first two "---" lines).
extract_frontmatter() {
    awk '
        NR==1 && $0!="---" { exit }
        $0=="---" { c++; if (c==2) exit; next }
        c==1 { print }
    ' "$1"
}

# Extract output.path / output.artifact_path, flat or nested, from a task file.
extract_output_path() {
    local file="$1" fm raw
    fm=$(extract_frontmatter "$file")

    raw=$(echo "$fm" | grep -E '^[[:space:]]*output\.(path|artifact_path)[[:space:]]*:' | head -1 \
        | sed -E 's/^[[:space:]]*output\.(path|artifact_path)[[:space:]]*:[[:space:]]*//')

    if [ -z "$raw" ]; then
        raw=$(echo "$fm" | awk '
            /^output:[[:space:]]*$/ { f=1; next }
            f && /^[^[:space:]]/ { f=0 }
            f
        ' | grep -E '^[[:space:]]*(path|artifact_path)[[:space:]]*:' | head -1 \
            | sed -E 's/^[[:space:]]*(path|artifact_path)[[:space:]]*:[[:space:]]*//')
    fi

    raw="${raw%\"}"; raw="${raw#\"}"
    raw="${raw%\'}"; raw="${raw#\'}"
    echo "$raw"
}

# Extract an id / task.id field, if present, for error labeling.
extract_task_id() {
    local file="$1" fm
    fm=$(extract_frontmatter "$file")
    echo "$fm" | grep -E '^[[:space:]]*(task\.id|id)[[:space:]]*:' | head -1 \
        | sed -E 's/^[[:space:]]*(task\.id|id)[[:space:]]*:[[:space:]]*//' \
        | sed -E "s/^[\"']//; s/[\"']\$//"
}

# Resolve a raw output.path value to an absolute path, relative to the task
# file's own directory. Caller must first filter out ${VAR} references.
resolve_output_path() {
    local raw="$1" task_dir="$2"

    if [[ "$raw" == "~"* ]]; then
        raw="${HOME}${raw#\~}"
    fi

    if [[ "$raw" == /* ]]; then
        echo "$raw"
        return
    fi

    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$task_dir/$raw"
    else
        echo "$task_dir/$raw"
    fi
}

# --- batch mode: output-path collision detection ---
if [ "${1:-}" = "--batch" ]; then
    shift
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 --batch <task-file-1> [task-file-2 ...]" >&2
        exit 2
    fi

    declare -A PATHS_TO_LABELS
    FAIL=0

    for f in "$@"; do
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
            echo "ERROR: cannot read task file: $f" >&2
            FAIL=1
            continue
        fi

        raw=$(extract_output_path "$f")
        if [ -z "$raw" ]; then
            echo "WARNING: $f — output.path not declared; artifact may be lost if cwd-sensitive" >&2
            continue
        fi

        if [[ "$raw" == *'${'*'}'* ]]; then
            echo "WARNING: $f — output.path '$raw' contains a variable reference validate.sh cannot resolve; use an absolute or file-relative path" >&2
            continue
        fi

        task_dir=$(cd "$(dirname "$f")" && pwd)
        resolved=$(resolve_output_path "$raw" "$task_dir")
        id=$(extract_task_id "$f")
        if [ -n "$id" ]; then
            label="Task $id ($f)"
        else
            label="$f"
        fi

        if [ -n "${PATHS_TO_LABELS[$resolved]+x}" ]; then
            PATHS_TO_LABELS["$resolved"]="${PATHS_TO_LABELS[$resolved]}"$'\n'"$label"
        else
            PATHS_TO_LABELS["$resolved"]="$label"
        fi
    done

    for path in "${!PATHS_TO_LABELS[@]}"; do
        labels="${PATHS_TO_LABELS[$path]}"
        count=$(echo "$labels" | grep -c .)
        if [ "$count" -gt 1 ]; then
            echo "ERROR: Output path collision detected!" >&2
            while IFS= read -r label; do
                echo "  $label: $path" >&2
            done <<< "$labels"
            echo "Recommendation: change all but one task's output.path to a unique file." >&2
            FAIL=1
        fi
    done

    if [ "$FAIL" -eq 1 ]; then
        exit 1
    fi

    echo "OK: no output path collisions detected across $# task file(s)."
    exit 0
fi

# --- single-task mode (original behavior) ---
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <prompt_string_or_file_path>" >&2
    echo "       $0 --batch <task-file-1> [task-file-2 ...]" >&2
    exit 2
fi

INPUT="$1"

# If input is a file path and exists, read it; otherwise treat as string
if [ -f "$INPUT" ] && [ -r "$INPUT" ]; then
    PROMPT_TEXT=$(cat "$INPUT")

    OUTPUT_PATH=$(extract_output_path "$INPUT")
    if [ -z "$OUTPUT_PATH" ]; then
        echo "WARNING: output.path not declared; artifact may be lost if cwd-sensitive" >&2
    fi
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
