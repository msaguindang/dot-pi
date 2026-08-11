#!/usr/bin/env bash

set -euo pipefail

# --- secrets: load from Infisical ---
INFISICAL_ROOT="$HOME/.pi/agent"
if command -v infisical &>/dev/null && [[ -f "$INFISICAL_ROOT/.infisical.json" ]]; then
    eval "$(cd "$INFISICAL_ROOT" && infisical export --format=dotenv-export --silent --path / 2>/dev/null)" || true
fi

: "${PLANE_API_KEY:?PLANE_API_KEY not set}"
: "${PLANE_BASE_URL:?PLANE_BASE_URL not set}"
: "${PLANE_WORKSPACE_SLUG:?PLANE_WORKSPACE_SLUG not set}"

API="$PLANE_BASE_URL/api/v1"

PROJECT_ARG=""
TITLE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT_ARG="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$PROJECT_ARG" || -z "$TITLE" ]]; then
    echo "Usage: plane-create.sh --project <slug_or_id> --title <title>" >&2
fi

PROJECT_ID="$PROJECT_ARG"
if ! [[ "$PROJECT_ARG" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    PROJECT_ID=$(echo "$projects_response" | jq -r --arg name "$PROJECT_ARG" '.results[] | select(.name == $name or .identifier == $name) | .id' | head -n1)
fi

response=$(curl -fsSL -X POST \
    -H "X-Api-Key: $PLANE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$TITLE\"}" \
    "$API/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID/work-items/")
echo "$response" | jq -r '"Created: #" + (.sequence_id | tostring) + " - " + .name'
