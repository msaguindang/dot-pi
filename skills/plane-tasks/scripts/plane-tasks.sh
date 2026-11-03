#!/usr/bin/env bash

set -euo pipefail

# --- secrets: Plane Integration project via machine identity ---
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plane-env.sh" || exit 1

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"

# --- validate required vars ---
: "${PLANE_API_KEY:?PLANE_API_KEY not set — store it in the Plane Integration Infisical project}"
: "${PLANE_BASE_URL:?PLANE_BASE_URL not set — store it in the Plane Integration Infisical project}"
: "${PLANE_WORKSPACE_SLUG:?PLANE_WORKSPACE_SLUG not set — store it in the Plane Integration Infisical project}"

# API helper
plane_api() {
    local method="${1:-GET}"
    local path="$2"
    local data="${3:-}"
    
    curl -s -X "$method" \
        -H "X-Api-Key: $PLANE_API_KEY" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} \
        "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/$path"
}

case "${1:-}" in
    list-my-tasks)
        # Get my ID
        ME=$(plane_api GET "members/me/" | jq -r '.id')
        # Get tasks
        plane_api GET "projects/$2/work-items/?assignees=$ME&expand=state" | jq -c '.results[]'
        ;;
    get-task)
        plane_api GET "projects/$3/work-items/$2/?expand=assignees,state"
        ;;
    update-status)
        # Expects: task-id, project-id, state-id
        plane_api PATCH "projects/$3/work-items/$2/" "{\"state\": \"$4\"}"
        ;;
    *)
        echo "Usage: plane-tasks [list-my-tasks|get-task|update-status]"
        ;;
esac
