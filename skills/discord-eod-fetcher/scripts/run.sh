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

# If an Infisical token is provided, export using it
if [[ -n "${INFISICAL_TOKEN:-}" ]]; then
    echo "[INFO] Using Infisical Service Token..." >&2
    eval "$(infisical export --domain http://localhost:8080 --format=dotenv-export 2>/dev/null)"
# Otherwise, if a Machine Identity is provided via environment variables, log in headlessly first
elif [[ -n "${INFISICAL_CLIENT_ID:-}" && -n "${INFISICAL_CLIENT_SECRET:-}" ]]; then
    echo "[INFO] Authenticating Infisical via Machine Identity..." >&2
    infisical login --method=universal-auth --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" --silent --domain http://localhost:8080
    eval "$(infisical export --domain http://localhost:8080 --format=dotenv-export 2>/dev/null)"
else
    # Fallback to local session (fragile for timers)
    eval "$(infisical export --domain http://localhost:8080 --format=dotenv-export 2>/dev/null)"
fi

exec python3 "$(dirname "$0")/fetch_discord.py" --lookback-days 2 "$@"
