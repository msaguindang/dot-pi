#!/bin/bash
set -euo pipefail

# ============================================================
# RPi Deploy — thin orchestrator over the repos' native
# build:upload pipelines (player-server / player-ui).
# ============================================================
# Usage:
#   deploy_to_pi.sh <branch> <env> <ui|server|both> [--yes] [--allow-dirty]
#
#   Without --yes the script runs PREFLIGHT ONLY and prints the
#   deployment plan (dirs, branch, commit, resolved hosts).
#   The agent must show that plan to the user and get explicit
#   confirmation, then re-run with --yes.
#
# Envs map to the repos' own npm scripts (build:upload:<env>):
#   dev | stg (alias: staging) | prod (alias: production) | local | sandbox
#   ("jenkins" is interactive in the repos and not supported here.)
#
# This script never scp/rsyncs anything itself. Target paths are
# owned by each repo's gulpfile (server -> remotePath from its
# sshConfig.js, UI -> /var/www/html/ui via its sshConfig.js).
# ============================================================

NTV_DIR="${NTV_DIR:-/data/dev/work/ntv}"
SERVER_REPO="$NTV_DIR/player-server"
UI_REPO="$NTV_DIR/player-ui"

log_info()    { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_warn()    { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_success() { echo -e "\033[1;32m[OK]\033[0m $*"; }
die()         { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -n '3,25p' | sed 's/^# \{0,1\}//'
    exit 1
}

# ---------- argument parsing ----------
[[ $# -ge 3 ]] || usage
BRANCH="$1"
RAW_ENV="$2"
SCOPE="$3"
shift 3

CONFIRMED=false
ALLOW_DIRTY=false
SMOKE_TEST=false
for arg in "$@"; do
    case "$arg" in
        --yes)         CONFIRMED=true ;;
        --allow-dirty) ALLOW_DIRTY=true ;;
        --smoke-test)  SMOKE_TEST=true ;;
        *) die "Unknown flag: $arg" ;;
    esac
done

case "$SCOPE" in ui|server|both) ;; *) die "Scope must be ui, server, or both (got: $SCOPE)" ;; esac

# Normalize env to the repos' npm script suffixes (build:upload:<env>)
case "$RAW_ENV" in
    production) ENV="prod" ;;
    staging)    ENV="stg" ;;
    dev|stg|prod|local|sandbox) ENV="$RAW_ENV" ;;
    *) die "Unknown env '$RAW_ENV'. Valid: dev, stg/staging, prod/production, local, sandbox." ;;
esac

# Branch dir naming convention: '/' -> '-'  (e.g. release/v2.9.44 -> release-v2.9.44)
DIR_BRANCH="${BRANCH//\//-}"

# ---------- helpers ----------

# Resolve the checkout for <branch>: repo root if it is on the branch,
# otherwise .worktrees/<sanitized-branch>. Asserts the result really is
# on the requested branch — no silent fallback.
resolve_repo_dir() {
    local repo_root="$1" out_var="$2"
    local dir current
    if [[ "$(git -C "$repo_root" branch --show-current 2>/dev/null)" == "$BRANCH" ]]; then
        dir="$repo_root"
    else
        dir="$repo_root/.worktrees/$DIR_BRANCH"
    fi
    [[ -d "$dir" ]] || die "No checkout for branch '$BRANCH': not at $repo_root root and $dir does not exist."
    current="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
    [[ "$current" == "$BRANCH" ]] || die "$dir is on branch '${current:-<detached>}', expected '$BRANCH'."
    printf -v "$out_var" '%s' "$dir"
}

assert_clean_tree() {
    local dir="$1"
    if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
        if $ALLOW_DIRTY; then
            log_warn "############################################################"
            log_warn "# DIRTY WORKING TREE in $dir"
            log_warn "# Deploying UNCOMMITTED changes (--allow-dirty)."
            log_warn "############################################################"
        else
            die "Working tree not clean in $dir. Commit/stash first, or pass --allow-dirty."
        fi
    fi
}

# Read a field from the repo's own sshConfig.js for the target env.
# No fallback: missing file or unresolvable field is a hard failure.
ssh_field() {
    local dir="$1" field="$2"
    [[ -f "$dir/sshConfig.js" ]] || die "$dir/sshConfig.js not found (gitignored, per-checkout). Copy it from another worktree of the same repo."
    NODE_ENV="$ENV" node -p "const v = require('$dir/sshConfig.js')['$field']; if (v === undefined) throw new Error('missing'); v" 2>/dev/null \
        || die "Could not resolve '$field' for env '$ENV' from $dir/sshConfig.js"
}

remote_exec() {
    # remote_exec <dir> <command...> — ssh to the device defined by <dir>'s sshConfig.js
    local dir="$1"; shift
    local host port user pass
    host="$(ssh_field "$dir" host)"
    port="$(ssh_field "$dir" port)"
    user="$(ssh_field "$dir" username)"
    pass="$(ssh_field "$dir" password)"
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$port" "$user@$host" "$@"
}

preflight_repo() {
    local label="$1" dir="$2"
    local commit version host
    assert_clean_tree "$dir"
    host="$(ssh_field "$dir" host)"
    commit="$(git -C "$dir" rev-parse --short HEAD)"
    version="$(node -p "require('$dir/package.json').version")"
    echo "  $label"
    echo "    dir     : $dir"
    echo "    branch  : $BRANCH @ $commit (v$version)"
    echo "    target  : $host ($ENV) via npm run build:upload:$ENV"
}

# ---------- resolve scope dirs ----------
SERVER_DIR="" UI_DIR=""
[[ "$SCOPE" == "server" || "$SCOPE" == "both" ]] && resolve_repo_dir "$SERVER_REPO" SERVER_DIR
[[ "$SCOPE" == "ui"     || "$SCOPE" == "both" ]] && resolve_repo_dir "$UI_REPO" UI_DIR

# ---------- preflight ----------
echo "============================================================"
echo " DEPLOYMENT PLAN   branch=$BRANCH  env=$ENV  scope=$SCOPE"
echo "============================================================"
[[ -n "$UI_DIR" ]]     && preflight_repo "player-ui" "$UI_DIR"
[[ -n "$SERVER_DIR" ]] && {
    preflight_repo "player-server" "$SERVER_DIR"
    [[ -f "$SERVER_DIR/.env" ]] || die "$SERVER_DIR/.env missing — the server bundle requires it. Copy it from another player-server worktree and review its values."
}
echo "============================================================"

if ! $CONFIRMED; then
    log_info "PREFLIGHT ONLY — nothing deployed."
    log_info "Show the plan above to the user. After explicit confirmation, re-run with --yes."
    exit 0
fi

# ---------- build + upload (native repo pipelines) ----------
if [[ -n "$UI_DIR" ]]; then
    log_info "player-ui: npm run build:upload:$ENV  (gulp uploadWithBanner -> tarball -> /var/www/html/ui)"
    (cd "$UI_DIR" && npm run "build:upload:$ENV")
    log_success "player-ui build:upload finished."
fi

if [[ -n "$SERVER_DIR" ]]; then
    log_info "player-server: npm run build:upload:$ENV  (tsc + gulp bundle/stopPlayer/uploadWithBanner)"
    (cd "$SERVER_DIR" && npm run "build:upload:$ENV")
    log_success "player-server build:upload finished."
fi

# ---------- post-deploy verification ----------
FAILURES=0
DIRTY_DEPLOYS=0

# flag_dirty_build <label> <build_info_json> — parse .dirty from a build-info
# payload; a dirty build downgrades the final verdict (not a FAILURE: dirty
# deploys are gated behind --allow-dirty, which the operator chose).
flag_dirty_build() {
    local label="$1" info="$2" dirty
    if ! dirty="$(echo "$info" | jq -er '.dirty // empty' 2>/dev/null)"; then
        dirty=""
    fi
    if [[ "$dirty" == "true" ]]; then
        log_warn "$label: DIRTY build deployed — commit hash matches HEAD but working tree had uncommitted changes; commit match is NOT proof of content."
        DIRTY_DEPLOYS=$((DIRTY_DEPLOYS + 1))
    fi
}

if [[ -n "$UI_DIR" ]]; then
    log_info "Verifying player-ui via build-info.json on device..."
    ui_remote_path="$(ssh_field "$UI_DIR" remotePath)"; ui_remote_path="${ui_remote_path%/}"
    local_commit="$(git -C "$UI_DIR" rev-parse --short HEAD)"
    if build_info="$(remote_exec "$UI_DIR" "cat $ui_remote_path/build-info.json" 2>/dev/null)"; then
        echo "$build_info" | jq . 2>/dev/null || echo "$build_info"
        if ! remote_commit="$(echo "$build_info" | jq -er '.commitHash // empty' 2>/dev/null)"; then
            log_warn "UI build-info.json on device is not valid JSON or lacks commitHash — cannot verify."
            FAILURES=$((FAILURES + 1))
        elif [[ -z "$remote_commit" || "${#remote_commit}" -lt 7 ]]; then
            log_warn "UI build-info commitHash on device ('$remote_commit') is empty or too short — refusing prefix compare."
            FAILURES=$((FAILURES + 1))
        elif [[ "$remote_commit" == "$local_commit"* || "$local_commit" == "$remote_commit"* ]]; then
            log_success "UI commit on device ($remote_commit) matches local HEAD ($local_commit)."
        else
            log_warn "UI COMMIT MISMATCH: device=$remote_commit local=$local_commit"
            FAILURES=$((FAILURES + 1))
        fi
        if ! remote_branch="$(echo "$build_info" | jq -er '.branch // empty' 2>/dev/null)"; then
            remote_branch=""
        fi
        [[ "$remote_branch" == "$BRANCH" ]] || log_warn "UI build-info branch is '${remote_branch:-<missing>}', expected '$BRANCH'."
        flag_dirty_build "player-ui" "$build_info"
    else
        log_warn "Could not read $ui_remote_path/build-info.json on device."
        FAILURES=$((FAILURES + 1))
    fi

    # HTTP check through nginx — catches a wrong remotePath in sshConfig.js
    # (ssh check above reads the same path the deploy wrote, so it alone
    # cannot detect deploying to a directory nginx does not serve).
    # NOTE: nginx try_files returns 200 + index.html for a missing
    # /ui/build-info.json, so the payload must be parsed defensively.
    ui_host="$(ssh_field "$UI_DIR" host)"
    if http_info="$(curl -fsS -m 10 "http://$ui_host/ui/build-info.json" 2>/dev/null)"; then
        if ! http_commit="$(echo "$http_info" | jq -er '.commitHash // empty' 2>/dev/null)"; then
            log_warn "http://$ui_host/ui/build-info.json is not valid JSON or lacks commitHash (nginx likely served index.html for a missing file) — cannot verify served UI."
            FAILURES=$((FAILURES + 1))
        elif [[ -z "$http_commit" || "${#http_commit}" -lt 7 ]]; then
            log_warn "UI commitHash served by nginx ('$http_commit') is empty or too short — refusing prefix compare."
            FAILURES=$((FAILURES + 1))
        elif [[ "$http_commit" == "$local_commit"* || "$local_commit" == "$http_commit"* ]]; then
            log_success "UI served by nginx (http://$ui_host/ui) matches local HEAD ($local_commit)."
        else
            log_warn "UI SERVED BY NGINX IS STALE: nginx=$http_commit local=$local_commit — remotePath in sshConfig.js likely points somewhere nginx does not serve."
            FAILURES=$((FAILURES + 1))
        fi
    else
        log_warn "Could not fetch http://$ui_host/ui/build-info.json — nginx may serve the UI from a different path than the deploy target."
        FAILURES=$((FAILURES + 1))
    fi
fi

if [[ -n "$SERVER_DIR" ]]; then
    log_info "Verifying player-server via build-info.json on device..."
    srv_remote_path="$(ssh_field "$SERVER_DIR" remotePath)"; srv_remote_path="${srv_remote_path%/}"
    srv_host="$(ssh_field "$SERVER_DIR" host)"
    srv_local_commit="$(git -C "$SERVER_DIR" rev-parse --short HEAD)"
    local_version="$(node -p "require('$SERVER_DIR/package.json').version")"

    # Primary check: build-info.json sidecar written by the server gulpfile's
    # writeBuildInfo task (lands at <remotePath>/build-info.json after extract).
    if srv_build_info="$(remote_exec "$SERVER_DIR" "cat $srv_remote_path/build-info.json" 2>/dev/null)"; then
        echo "$srv_build_info" | jq . 2>/dev/null || echo "$srv_build_info"
        if ! srv_remote_commit="$(echo "$srv_build_info" | jq -er '.commitHash // empty' 2>/dev/null)"; then
            log_warn "Server build-info.json on device is not valid JSON or lacks commitHash — cannot verify."
            FAILURES=$((FAILURES + 1))
        elif [[ -z "$srv_remote_commit" || "${#srv_remote_commit}" -lt 7 ]]; then
            log_warn "Server build-info commitHash on device ('$srv_remote_commit') is empty or too short — refusing prefix compare."
            FAILURES=$((FAILURES + 1))
        elif [[ "$srv_remote_commit" == "$srv_local_commit"* || "$srv_local_commit" == "$srv_remote_commit"* ]]; then
            log_success "Server commit on device ($srv_remote_commit) matches local HEAD ($srv_local_commit)."
        else
            log_warn "SERVER COMMIT MISMATCH: device=$srv_remote_commit local=$srv_local_commit"
            FAILURES=$((FAILURES + 1))
        fi
        if ! srv_remote_branch="$(echo "$srv_build_info" | jq -er '.branch // empty' 2>/dev/null)"; then
            srv_remote_branch=""
        fi
        [[ "$srv_remote_branch" == "$BRANCH" ]] || log_warn "Server build-info branch is '${srv_remote_branch:-<missing>}', expected '$BRANCH'."
        flag_dirty_build "player-server" "$srv_build_info"
    else
        log_warn "Could not read $srv_remote_path/build-info.json on device — the server bundle predates sidecar versioning; redeploy to fix."
        FAILURES=$((FAILURES + 1))
    fi

    # Secondary check: remote package.json version.
    remote_version="$(remote_exec "$SERVER_DIR" "node -p \"require('$srv_remote_path/package.json').version\"" 2>/dev/null || echo "unreadable")"
    if [[ "$remote_version" == "$local_version" ]]; then
        log_success "Server version on device ($remote_version) matches local ($local_version)."
    else
        log_warn "SERVER VERSION MISMATCH: device=$remote_version local=$local_version"
        FAILURES=$((FAILURES + 1))
    fi

    # pm2 status + crash-loop watch (restart counter must not climb).
    pm2_snapshot() {
        remote_exec "$SERVER_DIR" "pm2 jlist" 2>/dev/null \
            | jq -r '.[] | select(.name == "player-server") | "\(.pm2_env.status) \(.pm2_env.restart_time)"'
    }
    read -r status1 restarts1 <<< "$(pm2_snapshot || echo "unknown -1")"
    log_info "pm2 player-server: status=$status1 restarts=$restarts1 — watching 20s for crash loops..."
    sleep 20
    read -r status2 restarts2 <<< "$(pm2_snapshot || echo "unknown -1")"
    if [[ "$status2" == "online" && "$restarts2" == "$restarts1" ]]; then
        log_success "pm2 player-server stable (online, restart count unchanged at $restarts2)."
    else
        log_warn "pm2 player-server UNSTABLE: status=$status2 restarts $restarts1 -> $restarts2"
        log_warn "Inspect with: ssh pi@$srv_host 'pm2 logs player-server --lines 100 --nostream'"
        FAILURES=$((FAILURES + 1))
    fi

    # API reachability (port 3215 from the server's .env).
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$srv_host:3215/api/checkup/ping")" || http_code=000
    if [[ "$http_code" =~ ^0+$ ]]; then
        log_warn "player-server API unreachable at http://$srv_host:3215 (no HTTP response)."
        FAILURES=$((FAILURES + 1))
    elif [[ "$http_code" =~ ^2 ]]; then
        log_success "GET /api/checkup/ping -> $http_code"
    else
        # /checkup/ping proxies an upstream ping; non-2xx can mean the device
        # has no internet while the server itself is fine.
        log_warn "GET /api/checkup/ping -> $http_code (server responded; upstream ping may have failed — investigate if unexpected)."
    fi
fi

echo "============================================================"
if [[ "$FAILURES" -gt 0 ]]; then
    die "Deployment finished with $FAILURES verification failure(s). Do NOT assume the device is healthy."
elif [[ "$DIRTY_DEPLOYS" -gt 0 ]]; then
    log_warn "Deployment complete but NOT fully verifiable due to $DIRTY_DEPLOYS dirty build(s) (branch=$BRANCH env=$ENV scope=$SCOPE). Commit hashes matched, but dirty builds mean the deployed content may differ from those commits."
else
    log_success "Deployment complete and verified (branch=$BRANCH env=$ENV scope=$SCOPE)."
fi

# ---------- optional post-deploy smoke test ----------
# Build-info verification proves the right bytes landed; the smoke test proves
# the player actually boots and rotates content. Opt-in via --smoke-test.
# Only meaningful when the server is part of the deploy (it restarts both
# player-server and player-chromium and asserts the boot->playback chain).
if [[ "$SMOKE_TEST" == true ]]; then
    SMOKE_DIR="${PI_SMOKE_TEST_DIR:-$NTV_DIR/pi-smoke-test}"
    if [[ ! -f "$SMOKE_DIR/src/cli.js" ]]; then
        log_warn "Smoke test requested but not found at $SMOKE_DIR — skipping. (Set PI_SMOKE_TEST_DIR to override.)"
    else
        # Resolve the device host from whichever repo was deployed.
        smoke_dir_for_host="${SERVER_DIR:-$UI_DIR}"
        smoke_host="$(ssh_field "$smoke_dir_for_host" host)"
        smoke_user="$(ssh_field "$smoke_dir_for_host" username)"
        smoke_pass="$(ssh_field "$smoke_dir_for_host" password)"
        smoke_port="$(ssh_field "$smoke_dir_for_host" port)"
        smoke_args=(--host "$smoke_host" --user "$smoke_user" --password "$smoke_pass" --port "$smoke_port" --phase 1)
        # Feed the just-deployed versions in as expected values so the smoke test's
        # build-match check (1.2) actually asserts the right artifact is live,
        # instead of running informational-only.
        if [[ -n "$SERVER_DIR" && -n "${local_version:-}" ]]; then
            smoke_args+=(--expect-server-version "$local_version")
        fi
        if [[ -n "$UI_DIR" ]]; then
            ui_version="$(node -p "require('$UI_DIR/package.json').version" 2>/dev/null || echo "")"
            [[ -n "$ui_version" ]] && smoke_args+=(--expect-ui-version "$ui_version")
        fi
        log_info "Running pi-smoke-test (phase 1) against $smoke_host ..."
        if (cd "$SMOKE_DIR" && node src/cli.js "${smoke_args[@]}"); then
            log_success "Smoke test passed."
        else
            die "Smoke test FAILED — deploy landed but the player is not healthy. Inspect the report under $SMOKE_DIR/runs/."
        fi
    fi
fi
