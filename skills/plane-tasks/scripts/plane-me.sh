#!/usr/bin/env bash

set -euo pipefail

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set. Run via 'infisical run -- <script>'}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"


CACHE=~/.cache/plane/me.uuid
if [ ! -f "$CACHE" ] || [ -z "$(find "$CACHE" -mmin -1440)" ]; then
    curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/members/me/" | jq -r '.id' > "$CACHE"
fi
cat "$CACHE"
