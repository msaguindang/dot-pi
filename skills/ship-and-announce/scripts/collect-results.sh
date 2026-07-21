#!/usr/bin/env bash
# Aggregate the 4 worker result files for a fix-id into one markdown block.
# Usage: collect-results.sh <fix-id>
set -euo pipefail
FIX_ID="${1:?usage: collect-results.sh <fix-id>}"

for w in source docs plane announce; do
  f="/tmp/ship-$w-$FIX_ID-result.md"
  echo "## $w ($f)"
  if [[ -f $f ]]; then
    # ponytail: line-oriented "key: value" grep, fragile to creative workers; JSON results if it bites
    grep -E '^[a-z_]+: ' "$f" || echo "status: unparseable (no key: value header lines)"
  else
    echo "status: missing"
  fi
  echo
done
