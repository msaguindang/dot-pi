#!/usr/bin/env bash

set -euo pipefail

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set. Run via 'infisical run -- <script>'}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"


ISSUE_SEQ="$1"
PROJECT_ID="$2"
STATE_NAME="$3"

# 1. Resolve State Name to UUID
STATE_UUID=$(curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID/states/" | jq -r ".results[] | select(.name == \"$STATE_NAME\") | .id")

# 2. Resolve Issue Sequence ID to Issue UUID
ISSUE_UUID=$(curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID/work-items/" | jq -r ".results[] | select(.sequence_id == $ISSUE_SEQ) | .id")

# 3. Patch Issue
curl -fsSL -X PATCH \
  -H "X-API-Key: $PLANE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"state\": \"$STATE_UUID\"}" \
  "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID/work-items/$ISSUE_UUID/"
