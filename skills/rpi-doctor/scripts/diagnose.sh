#!/bin/bash
set -euo pipefail

# ============================================================
# RPI Doctor: Context-Aware SSH Diagnostics
# ============================================================
# Usage: ./diagnose.sh <device_or_ip> <category> [app_name_or_command]
# Categories: health | app | general | custom
# Example: ./diagnose.sh test-pi app player-server
# Example: ./diagnose.sh 192.168.0.50 health
# ============================================================

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${RPI_INVENTORY:-$script_dir/../device-inventory.json}"
TARGET=$1
CATEGORY=$2
ARG=${3:-} # Either an app name (like 'player-server') or a custom command

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# 1. Resolve Target (Name -> IP mapping)
HOST="$TARGET"
USER="${RPI_USER:-pi}" # Default user — override with RPI_USER env var
AUTH="password" # Lab fleet default is password auth (pi/raspberry); key auth is the exception

if [[ -f "$INVENTORY_FILE" ]]; then
    # Simple JSON extraction for the specific target
    DEVICE_JSON=$(grep -A 5 "\"name\": \"$TARGET\"" "$INVENTORY_FILE" || true)
    
    if [[ -n "$DEVICE_JSON" ]]; then
        HOST=$(echo "$DEVICE_JSON" | grep '"host"' | cut -d '"' -f 4)
        USER=$(echo "$DEVICE_JSON" | grep '"user"' | cut -d '"' -f 4)
        AUTH=$(echo "$DEVICE_JSON" | grep '"auth"' | cut -d '"' -f 4)
        if [[ -z "$HOST" || -z "$USER" || -z "$AUTH" ]]; then
            log_error "Found '$TARGET' in inventory but failed to extract host/user/auth (malformed entry — check device-inventory.json field order/format near '$TARGET')."
        fi
        log_info "Found '$TARGET' in local inventory. Resolved to: $USER@$HOST ($AUTH auth)"
    else
        log_info "Target '$TARGET' not found in inventory. Assuming it's a direct IP/Hostname."
    fi
else
    log_info "No local inventory found. Assuming '$TARGET' is a direct IP/Hostname."
fi

# 2. Build the Context-Aware Command
case "$CATEGORY" in
    health)
        log_info "Diagnosing System Health..."
        CMD="echo '--- UPTIME ---' && uptime && \
             echo -e '\n--- MEMORY ---' && free -h && \
             echo -e '\n--- DISK SPACE ---' && df -h / && \
             echo -e '\n--- TOP PROCESSES ---' && top -b -n 1 | head -n 15"
        ;;
    app)
        if [[ -z "$ARG" ]]; then
            log_error "You must provide an app name when using the 'app' category."
        fi
        log_info "Diagnosing specific service: $ARG..."
        CMD="echo '--- PM2 STATUS ---' && pm2 status && \
             echo -e '\n--- RECENT LOGS ($ARG) ---' && pm2 logs $ARG --lines 50 --nostream"
        ;;
    general)
        log_info "Running general checks..."
        CMD="echo '--- UPTIME ---' && uptime && \
             echo -e '\n--- PM2 OVERVIEW ---' && pm2 status"
        ;;
    custom)
        if [[ -z "$ARG" ]]; then
            log_error "You must provide a command when using the 'custom' category."
        fi
        log_info "Running custom command: $ARG"
        CMD="$ARG"
        ;;
    *)
        log_error "Unknown category: $CATEGORY. Use 'health', 'app', 'general', or 'custom'."
        ;;
esac

# 3. Execute SSH with Strict Timeouts
# -o ConnectTimeout=5: Fail fast if the IP is offline (very common for dynamic IPs)
# -o StrictHostKeyChecking=accept-new: Don't get stuck on the first connection prompt
# Key auth is tried first (BatchMode=yes fails fast instead of prompting); on failure
# we fall back to password auth via sshpass — most lab Pis use password auth, not keys.

log_info "Connecting to $HOST..."
echo "============================================================"

set +e # Don't exit script if ssh fails; we want to capture the error

if [[ "$AUTH" == "password" ]]; then
    # Use password auth
    sshpass -p "${RPI_PASS:-raspberry}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$HOST" "$CMD"
else
    # Try key-based first, then fallback to password
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$USER@$HOST" "$CMD" 2>/dev/null; then
        log_info "Key-based SSH failed, trying password fallback..."
        sshpass -p "${RPI_PASS:-raspberry}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$HOST" "$CMD"
    fi
fi

SSH_EXIT_CODE=$?
set -e

echo "============================================================"

if [[ $SSH_EXIT_CODE -eq 255 ]]; then
    log_error "Connection failed (Timeout, No Route to Host, or Key Rejected). Ensure the device is online and your SSH keys are configured."
elif [[ $SSH_EXIT_CODE -ne 0 ]]; then
    log_error "SSH command executed but returned a non-zero exit code ($SSH_EXIT_CODE)."
fi

log_info "Diagnostics complete."
