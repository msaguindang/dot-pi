#!/usr/bin/env bash

set -euo pipefail

# --- secrets: load from Infisical regardless of caller's cwd (agent root: ~/.pi/agent) ---
INFISICAL_ROOT="$HOME/.pi/agent"
if command -v infisical &>/dev/null && [[ -f "$INFISICAL_ROOT/.infisical.json" ]]; then
    eval "$(cd "$INFISICAL_ROOT" && infisical export --format=dotenv-export --silent --path / 2>/dev/null)" || true
fi

# Enforce Infisical Secrets
: "${PLANE_API_KEY:?Error: PLANE_API_KEY not set. Run via 'infisical run -- <script>'}"
: "${PLANE_BASE_URL:?Error: PLANE_BASE_URL not set.}"
: "${PLANE_WORKSPACE_SLUG:?Error: PLANE_WORKSPACE_SLUG not set.}"

PROJECT_ID=""
OUTPUT="json"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project) PROJECT_ID="$2"; shift ;;
        --output) OUTPUT="$2"; shift ;;
    esac
    shift
done

if [[ -z "$PROJECT_ID" ]]; then
    echo "Error: --project <id> is required" >&2
    exit 1
fi

# GET helper: exits 1 on 4xx/5xx (also covers 401/403/404 cases)
api_get() {
    local path="$1"
    local resp status body
    resp=$(curl -sS -w '\n%{http_code}' -H "X-API-Key: $PLANE_API_KEY" "$PLANE_BASE_URL/api/v1/workspaces/$PLANE_WORKSPACE_SLUG/$path")
    status="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    if [[ "$status" -ge 400 ]]; then
        echo "Error: GET $path returned HTTP $status" >&2
        exit 1
    fi
    echo "$body"
}

# Project detail doubles as the "does this project exist" check and gives us
# the ticket prefix (e.g. "PV1") for sequence_number.
IDENTIFIER=$(api_get "projects/$PROJECT_ID/" | jq -r '.identifier')

# expand=state inlines the full state object (id, name, group) on each item,
# so there's no need for a separate /states/ fetch + manual UUID join.
ITEMS=$(api_get "projects/$PROJECT_ID/work-items/?expand=state")

JQ_ROWS='.results[] | select(.id and .sequence_id) |
    {id, sequence_number: ($prefix + "-" + (.sequence_id|tostring)), name, state_name: (.state.name // null), priority}'

if [[ "$OUTPUT" == "table" ]]; then
    {
        printf 'ID\tSeq\tName\tState\tPriority\n'
        echo "$ITEMS" | jq -r --arg prefix "$IDENTIFIER" \
            "$JQ_ROWS | [.id, .sequence_number, .name, (.state_name // \"?\"), .priority] | @tsv"
    } | column -t -s $'\t'
else
    echo "$ITEMS" | jq -c --arg prefix "$IDENTIFIER" "$JQ_ROWS"
fi
