#!/usr/bin/env bash

set -euo pipefail

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set. Run via 'infisical run -- <script>'}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"


PROJECT_ID=""
PRIORITY=""
JSON=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project) PROJECT_ID="$2"; shift ;;
        --priority) PRIORITY="$2"; shift ;;
        --json) JSON=true ;;
    esac
    shift
done

ME=$(~/.pi/agent/skills/plane-tasks/scripts/plane-me.sh)
STATES=$(curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID/states/" | jq -r '[.results[] | select(.group != "completed" and .group != "cancelled") | .id] | join(",")')

URL="$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID/work-items/?assignees=$ME&state=$STATES"
[ -n "$PRIORITY" ] && URL="$URL&priority=$PRIORITY"

RES=$(curl -fsSL -H "X-API-Key: $PLANE_API_KEY" "$URL")
if [ "$JSON" = true ]; then
    echo "$RES" | jq -c '.results[]'
else
    echo "$RES" | jq -r '.results[] | "\(.sequence_id): \(.name) [\(.priority)]"'
fi
