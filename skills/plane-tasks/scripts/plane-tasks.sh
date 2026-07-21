#!/usr/bin/env bash

set -euo pipefail

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set. Run via 'infisical run -- <script>'}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"


# --- secrets: load from Infisical (agent root: ~/.pi/agent) ---
INFISICAL_ROOT="$HOME/.pi/agent"
if command -v infisical &>/dev/null && [[ -f "$INFISICAL_ROOT/.infisical.json" ]]; then
    eval "$(infisical export --format=dotenv-export --silent --path / 2>/dev/null)" || true
fi

# --- validate required vars ---
: "${PLANE_API_KEY:?PLANE_API_KEY not set — run: cd ~/.pi/agent && infisical secrets set PLANE_API_KEY=...}"
: "${PLANE_BASE_URL:?PLANE_BASE_URL not set — run: cd ~/.pi/agent && infisical secrets set PLANE_BASE_URL=...}"
: "${PLANE_WORKSPACE_SLUG:?PLANE_WORKSPACE_SLUG not set — run: cd ~/.pi/agent && infisical secrets set PLANE_WORKSPACE_SLUG=...}"

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
