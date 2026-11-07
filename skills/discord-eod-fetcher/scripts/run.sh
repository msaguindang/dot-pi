#!/usr/bin/env bash
set -euo pipefail

# Wait for Infisical to be reachable before injecting secrets.
# Handles boot-time race: Docker + containers may still be starting.
INFISICAL_URL="http://localhost:8080/api/status"
MAX_WAIT=60  # seconds
INTERVAL=5

elapsed=0
while ! curl -sf "$INFISICAL_URL" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "[ERROR] Infisical not reachable after ${MAX_WAIT}s — aborting" >&2
        exit 1
    fi
    echo "[INFO] Waiting for Infisical (${elapsed}s elapsed)..." >&2
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

# Load the bot token with a dedicated Discord-only machine identity. It renews
# without a browser and gives up fast. Any INFISICAL_TOKEN inherited from the
# service's environment file is ignored on purpose.
readonly INFISICAL_DOMAIN="http://localhost:8080"
readonly INFISICAL_TIMEOUT_SECONDS=15
readonly CREDS_DIR="${HOME}/.config/infisical-machine/discord"

load_bot_token() {
    local file access_token
    local -A creds=()
    for file in client-id client-secret project-id; do
        if [[ ! -r "${CREDS_DIR}/${file}" ]]; then
            echo "[ERROR] missing ${CREDS_DIR}/${file}" >&2
            return 1
        fi
        creds[$file]="$(<"${CREDS_DIR}/${file}")"
    done

    if ! access_token="$(env -u INFISICAL_TOKEN timeout "$INFISICAL_TIMEOUT_SECONDS" infisical login \
        --method=universal-auth --client-id="${creds[client-id]}" --client-secret="${creds[client-secret]}" \
        --plain --silent --domain "$INFISICAL_DOMAIN" </dev/null 2>/dev/null)" || [[ -z "$access_token" ]]; then
        echo "[ERROR] Infisical machine login failed or timed out" >&2
        return 1
    fi

    if ! DISCORD_BOT_TOKEN="$(INFISICAL_TOKEN="$access_token" timeout "$INFISICAL_TIMEOUT_SECONDS" \
        infisical secrets get DISCORD_BOT_TOKEN --plain --silent --domain "$INFISICAL_DOMAIN" \
        --projectId "${creds[project-id]}" --env dev </dev/null 2>/dev/null)" || [[ -z "$DISCORD_BOT_TOKEN" ]]; then
        echo "[ERROR] could not read DISCORD_BOT_TOKEN from Infisical" >&2
        return 1
    fi
    export DISCORD_BOT_TOKEN
}

if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
    load_bot_token || exit 1
fi

exec python3 "$(dirname "$0")/fetch_discord.py" --lookback-days 2 "$@"
