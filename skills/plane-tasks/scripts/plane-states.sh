#!/usr/bin/env bash

set -euo pipefail

# --- secrets: Plane Integration project via machine identity ---
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plane-env.sh" || exit 1
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"


curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$1/states/" | jq -c '.results[] | {id, name, group}'
