#!/usr/bin/env bash

set -euo pipefail

# --- secrets: Plane Integration project via machine identity ---
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plane-env.sh" || exit 1
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"

# Validate all scripts in the skill directory
for s in ~/.pi/agent/skills/plane-tasks/scripts/*.sh; do
    if [[ "$s" == *"test-bench.sh"* ]]; then continue; fi
    echo "Checking $s..."
    if command -v shellcheck &>/dev/null; then
        shellcheck "$s"
    else
        echo "shellcheck not found, skipping lint"
    fi
    bash -n "$s"
done
