#!/usr/bin/env bash

set -euo pipefail

# Create-if-missing a label and apply it to an issue, without clobbering any
# labels already on that issue. See CLAUDE.md's "Ticket Conventions" section
# (per-component shipped-version labels, decided 2026-08-24) for the naming
# rule this exists to support: player-server-X.Y.Z / player-ui-A.B.C, applied
# at the same point a ticket is marked Done.

# --- secrets: load from Infisical ---
INFISICAL_ROOT="${PI_CODING_AGENT_DIR:-${HOME:?}/.pi/agent}"
if command -v infisical &>/dev/null && [[ -f "$INFISICAL_ROOT/.infisical.json" ]]; then
    eval "$(cd "$INFISICAL_ROOT" && infisical export --format=dotenv-export --silent --path / 2>/dev/null)" || true
fi

: "${PLANE_API_KEY:?PLANE_API_KEY not set}"
: "${PLANE_BASE_URL:?PLANE_BASE_URL not set}"
: "${PLANE_WORKSPACE_SLUG:?PLANE_WORKSPACE_SLUG not set}"

API="$PLANE_BASE_URL/api/v1"

PROJECT_ID=""
ISSUE_SEQ=""
LABEL_NAME=""
COLOR="#3B82F6"

while [[ $# -gt 0 ]]; do
    case $1 in
        --project) PROJECT_ID="$2"; shift 2 ;;
        --issue) ISSUE_SEQ="$2"; shift 2 ;;
        --label) LABEL_NAME="$2"; shift 2 ;;
        --color) COLOR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$PROJECT_ID" || -z "$ISSUE_SEQ" || -z "$LABEL_NAME" ]]; then
    echo "Usage: plane-labels.sh --project <project_id> --issue <sequence_id> --label <name> [--color <hex>]" >&2
    exit 1
fi
if ! [[ "$ISSUE_SEQ" =~ ^[0-9]+$ ]]; then
    echo "Issue sequence must be numeric: $ISSUE_SEQ" >&2
    exit 1
fi

BASE="$API/workspaces/$PLANE_WORKSPACE_SLUG/projects/$PROJECT_ID"

# 1. Resolve issue sequence id to UUID (paginated; per_page=100 covers this board today)
ISSUE_UUID=$(curl -fsSL -H "X-Api-Key: $PLANE_API_KEY" "$BASE/issues/?per_page=100" \
    | jq -r --argjson seq "$ISSUE_SEQ" '.results[] | select(.sequence_id == $seq) | .id')
[[ -n "$ISSUE_UUID" ]] || { echo "Issue #$ISSUE_SEQ not found in project $PROJECT_ID" >&2; exit 1; }

# 2. Find-or-create the label
LABEL_ID=$(curl -fsSL -H "X-Api-Key: $PLANE_API_KEY" "$BASE/labels/" \
    | jq -r --arg name "$LABEL_NAME" '(.results // .)[]? | select(.name == $name) | .id' | head -n1)

if [[ -z "$LABEL_ID" ]]; then
    LABEL_ID=$(curl -fsSL -X POST \
        -H "X-Api-Key: $PLANE_API_KEY" -H "Content-Type: application/json" \
        -d "$(jq -cn --arg name "$LABEL_NAME" --arg color "$COLOR" '{name: $name, color: $color}')" \
        "$BASE/labels/" | jq -r '.id')
    echo "Created label: $LABEL_NAME ($LABEL_ID)"
fi

# 3. Merge into the issue's existing labels (never overwrite someone else's)
EXISTING_LABELS=$(curl -fsSL -H "X-Api-Key: $PLANE_API_KEY" "$BASE/issues/$ISSUE_UUID/" | jq -c '.labels // []')
MERGED_LABELS=$(echo "$EXISTING_LABELS" | jq -c --arg lid "$LABEL_ID" '. + (if index($lid) then [] else [$lid] end)')

curl -fsSL -X PATCH \
    -H "X-Api-Key: $PLANE_API_KEY" -H "Content-Type: application/json" \
    -d "$(jq -cn --argjson labels "$MERGED_LABELS" '{labels: $labels}')" \
    "$BASE/issues/$ISSUE_UUID/" | jq -r '"#" + (.sequence_id | tostring) + " labels: " + (.labels | join(", "))'
