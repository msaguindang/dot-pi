#!/bin/bash
set -euo pipefail

# ============================================================
# N-Compass TV Worktree Manager Script
# ============================================================
# Usage: ./manage_worktrees.sh <type> <id> <description> <repos...>
# Example: ./manage_worktrees.sh feat 123 add-button api ui
# ============================================================

# Logging helpers
log_info() { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# NTV_DIR is required — fail loudly if not set
if [ -z "${NTV_DIR:-}" ]; then
    log_error "NTV_DIR is not set. Export it before running this script."
    log_error "  e.g. export NTV_DIR=\$HOME/Projects/work/ntv"
    exit 1
fi

export NTV_API_DIR="$NTV_DIR/api-v1"
export NTV_DASH_DIR="$NTV_DIR/dashboard-v1"
export NTV_PLAYER_SERVER_DIR="$NTV_DIR/player-server"
export NTV_PLAYER_UI_DIR="$NTV_DIR/player-ui"

if [ $# -lt 4 ]; then
    log_error "Usage: $0 <type> <id> <description> <repos...>"
    log_error "  repos: one or more of: api dash server ui"
    exit 1
fi

TYPE=$1
ID=$2
DESC=$3
shift 3
REPOS=("$@")

BRANCH_NAME="${TYPE}/${ID}-${DESC}"
log_info "Creating branch: $BRANCH_NAME"

for repo in "${REPOS[@]}"; do
    case "$repo" in
        api)    BASE_DIR="$NTV_API_DIR" ;;
        dash)   BASE_DIR="$NTV_DASH_DIR" ;;
        server) BASE_DIR="$NTV_PLAYER_SERVER_DIR" ;;
        ui)     BASE_DIR="$NTV_PLAYER_UI_DIR" ;;
        *)
            log_warn "Unknown repo '$repo' — skipping."
            continue
            ;;
    esac

    WT_PATH="$BASE_DIR/.worktrees/$BRANCH_NAME"

    log_info "[$repo] Fetching origin..."
    cd "$BASE_DIR"
    git fetch origin

    if [ -d "$WT_PATH" ]; then
        log_warn "[$repo] Worktree already exists: $WT_PATH"
    else
        log_info "[$repo] Adding worktree at $WT_PATH"
        mkdir -p "$BASE_DIR/.worktrees"
        git worktree add "$WT_PATH" -b "$BRANCH_NAME" origin/main
        log_info "[$repo] Done → $WT_PATH"
        # Uncomment to auto-install dependencies:
        # cd "$WT_PATH" && npm ci
    fi
done

log_info "All repos processed. Branch: $BRANCH_NAME"
