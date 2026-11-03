#!/usr/bin/env bash
set -euo pipefail

# Self-contained TickTick CLI.
# Sends a one-shot JSON-RPC 2.0 request to the TickTick MCP HTTP endpoint.
# Usage: ticktick.sh <method> '<params_json>'
#   <method>       e.g. ticktick_list_projects, ticktick_create_task, or tools/list
#   <params_json>  JSON object of arguments (default '{}')

readonly TICKTICK_ENDPOINT="https://mcp.ticktick.com/"
readonly INFISICAL_DOMAIN="http://localhost:8080"
readonly INFISICAL_TIMEOUT_SECONDS=15
readonly CREDS_DIR="${HOME}/.config/infisical-machine/ticktick"

# Fetch the TickTick key with a dedicated machine identity. It renews without a
# browser and gives up fast, so an expired personal login can never hang this script.
load_api_key() {
    local file access_token
    local -A creds=()
    for file in client-id client-secret project-id path; do
        if [[ ! -r "${CREDS_DIR}/${file}" ]]; then
            echo "Error: missing ${CREDS_DIR}/${file}" >&2
            return 1
        fi
        creds[$file]="$(<"${CREDS_DIR}/${file}")"
    done

    if ! access_token="$(timeout "$INFISICAL_TIMEOUT_SECONDS" infisical login --method=universal-auth \
        --client-id="${creds[client-id]}" --client-secret="${creds[client-secret]}" \
        --plain --silent --domain "$INFISICAL_DOMAIN" </dev/null 2>/dev/null)" || [[ -z "$access_token" ]]; then
        echo "Error: Infisical machine login failed or timed out" >&2
        return 1
    fi

    if ! TICKTICK_API_KEY="$(INFISICAL_TOKEN="$access_token" timeout "$INFISICAL_TIMEOUT_SECONDS" \
        infisical secrets get TICKTICK_API_KEY --plain --silent --domain "$INFISICAL_DOMAIN" \
        --projectId "${creds[project-id]}" --env dev --path "${creds[path]}" </dev/null 2>/dev/null)" \
        || [[ -z "$TICKTICK_API_KEY" ]]; then
        echo "Error: could not read TICKTICK_API_KEY from Infisical" >&2
        return 1
    fi
    export TICKTICK_API_KEY
}

main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: ticktick.sh <method> [params_json]" >&2
        exit 1
    fi

    local method="$1"
    local params_json="${2:-}"
    [[ -z "$params_json" ]] && params_json="{}"

    # Validate params JSON early so we fail before the network call.
    if ! echo "$params_json" | jq empty >/dev/null 2>&1; then
        echo "Error: params_json is not valid JSON: ${params_json}" >&2
        exit 1
    fi

    # Auth: use existing env var, else load it from Infisical.
    if [[ -z "${TICKTICK_API_KEY:-}" ]]; then
        load_api_key || exit 1
    fi
    : "${TICKTICK_API_KEY:?TICKTICK_API_KEY not set}"

    # Build the JSON-RPC 2.0 body. tools/list takes empty params; everything
    # else is framed as a tools/call with the method as the tool name.
    local body
    if [[ "$method" == "tools/list" ]]; then
        body="$(jq -nc \
            --argjson id "$(date +%s%3N)" \
            '{jsonrpc: "2.0", id: $id, method: "tools/list", params: {}}')"
    else
        body="$(jq -nc \
            --argjson id "$(date +%s%3N)" \
            --arg name "$method" \
            --argjson args "$params_json" \
            '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $name, arguments: $args}}')"
    fi

    # POST with Bearer auth. Capture body + HTTP status; do not swallow errors.
    local response http_code
    response="$(curl -sS -w $'\n%{http_code}' \
        -X POST "$TICKTICK_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${TICKTICK_API_KEY}" \
        --data "$body")"

    http_code="$(echo "$response" | tail -n1)"
    response="$(echo "$response" | sed '$d')"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        echo "HTTP Error: ${http_code}" >&2
        echo "Response: ${response}" >&2
        exit 1
    fi

    # Surface JSON-RPC errors instead of printing null result.
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "JSON-RPC Error: $(echo "$response" | jq '.error')" >&2
        exit 1
    fi

    echo "$response" | jq '.result'
}

main "$@"
