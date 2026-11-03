#!/usr/bin/env bash
# Sourced by the plane-*.sh scripts (not run directly): sets PLANE_API_KEY,
# PLANE_BASE_URL and PLANE_WORKSPACE_SLUG from the Plane Integration Infisical
# project through a dedicated machine identity. It renews without a browser and
# gives up fast, so an expired personal login can never hang a script.
# If all three variables are already exported, nothing is fetched.

readonly PLANE_INFISICAL_DOMAIN="http://localhost:8080"
readonly PLANE_INFISICAL_TIMEOUT_SECONDS=15
readonly PLANE_CREDS_DIR="${PLANE_CREDS_DIR:-${HOME}/.config/infisical-machine/plane}"

plane_load_env() {
    local file name access_token
    local -A creds=()

    if [[ -n "${PLANE_API_KEY:-}" && -n "${PLANE_BASE_URL:-}" && -n "${PLANE_WORKSPACE_SLUG:-}" ]]; then
        return 0
    fi

    for file in client-id client-secret project-id; do
        if [[ ! -r "${PLANE_CREDS_DIR}/${file}" ]]; then
            echo "Error: missing ${PLANE_CREDS_DIR}/${file}" >&2
            return 1
        fi
        creds[$file]="$(<"${PLANE_CREDS_DIR}/${file}")"
    done

    if ! access_token="$(timeout "$PLANE_INFISICAL_TIMEOUT_SECONDS" infisical login --method=universal-auth \
        --client-id="${creds[client-id]}" --client-secret="${creds[client-secret]}" \
        --plain --silent --domain "$PLANE_INFISICAL_DOMAIN" </dev/null 2>/dev/null)" || [[ -z "$access_token" ]]; then
        echo "Error: Infisical machine login failed or timed out" >&2
        return 1
    fi

    for name in PLANE_API_KEY PLANE_BASE_URL PLANE_WORKSPACE_SLUG; do
        if ! printf -v "$name" '%s' "$(INFISICAL_TOKEN="$access_token" timeout "$PLANE_INFISICAL_TIMEOUT_SECONDS" \
            infisical secrets get "$name" --plain --silent --domain "$PLANE_INFISICAL_DOMAIN" \
            --projectId "${creds[project-id]}" --env dev </dev/null 2>/dev/null)" || [[ -z "${!name}" ]]; then
            echo "Error: could not read ${name} from Infisical" >&2
            return 1
        fi
        export "${name?}"
    done
}

plane_load_env
