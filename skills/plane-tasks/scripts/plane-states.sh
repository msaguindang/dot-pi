#!/usr/bin/env bash

set -euo pipefail

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set. Run via 'infisical run -- <script>'}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"


curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$1/states/" | jq -c '.results[] | {id, name, group}'
