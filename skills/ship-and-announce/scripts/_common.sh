#!/usr/bin/env bash
# Shared helpers for ship-and-announce scripts. Source, don't execute.

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$SKILL_DIR/templates"
VALIDATOR="/home/codeweaver/.pi/agent/skills/delegation-validator/scripts/validate.sh"

# render_template <template> <output> KEY=value...
# Replaces {{KEY}} with value. Fails if any {{...}} remain unresolved.
render_template() {
  local tpl="$1" out="$2"; shift 2
  local content kv k v
  content="$(cat "$tpl")"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # Quoted pattern+replacement: keeps '&' and '\' in values literal
    # (bash 5.2 patsub_replacement would otherwise re-expand '&' to the match).
    content="${content//"{{$k}}"/"$v"}"
  done
  if grep -q '{{[A-Z_]\+}}' <<<"$content"; then
    echo "ERROR: unresolved placeholders in $out:" >&2
    grep -o '{{[A-Z_]\+}}' <<<"$content" | sort -u >&2
    return 1
  fi
  printf '%s\n' "$content" > "$out"
}

# validate_task <task-file>
# Runs delegation-validator; fails (exit 1) if the task file has relative
# context references. Task files must be self-contained.
validate_task() {
  if [[ -x "$VALIDATOR" ]]; then
    if ! "$VALIDATOR" "$1"; then
      echo "ERROR: delegation-validator flagged $1 as not self-contained" >&2
      return 1
    fi
  else
    echo "WARN: delegation-validator not found at $VALIDATOR; skipping scan" >&2
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }
