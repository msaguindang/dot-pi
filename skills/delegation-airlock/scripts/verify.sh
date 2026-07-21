#!/usr/bin/env bash
set -uo pipefail
# NOTE: no `set -e` — individual check failures are recorded, aggregated, and
# reported; the script exits non-zero at the end if any check failed.

# Parent verification runner (Step 4). Never trust the worker report alone.
#
# Usage:
#   verify.sh <slug> [--repo DIR] [--fence file1,file2,...] [--script PATH]... [--skip-push] [--allow-dirty]
#
#   <slug>         task slug; evidence log goes to /tmp/verify-<slug>-evidence.txt
#   --repo DIR     git repo to verify (default: current directory)
#   --fence LIST   comma-separated paths (relative to repo root) that HEAD is
#                  allowed to mutate; any other mutated file = scope-fence
#                  violation = exit non-zero
#   --script PATH  run `bash -n` on this script (repeatable)
#   --skip-push    skip the local-HEAD-is-on-remote check (e.g. no remote yet)
#   --allow-dirty  do not fail on uncommitted working-tree changes
#
# Exit: 0 all checks passed, 1 one or more failures (see evidence log), 2 usage.

[ "$#" -ge 1 ] || { echo "Usage: verify.sh <slug> [--repo DIR] [--fence f1,f2] [--script PATH]... [--skip-push] [--allow-dirty]" >&2; exit 2; }

SLUG="$1"; shift
REPO="$PWD"
FENCE=""
SKIP_PUSH=0
ALLOW_DIRTY=0
SCRIPTS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --fence)       FENCE="$2"; shift 2 ;;
        --script)      SCRIPTS+=("$2"); shift 2 ;;
        --skip-push)   SKIP_PUSH=1; shift ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

LOG="/tmp/verify-${SLUG}-evidence.txt"
FAILURES=0

log() { echo "$@" | tee -a "$LOG"; }

# run <label> <cmd...> : runs cmd, logs command + output with timestamp,
# records a failure if the command exits non-zero.
run() {
    local label="$1"; shift
    local out rc
    log ""
    log "[$(date -Is)] CHECK: $label"
    log "\$ $*"
    out=$("$@" 2>&1); rc=$?
    log "$out"
    if [ "$rc" -ne 0 ]; then
        log "DEVIATION: '$label' exited $rc"
        FAILURES=$((FAILURES + 1))
    fi
    return 0
}

: > "$LOG"
log "=== delegation-airlock parent verification ==="
log "slug: $SLUG"
log "repo: $REPO"
log "started: $(date -Is)"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    log "DEVIATION: $REPO is not a git repository"
    log "RESULT: FAIL"
    exit 1
fi

# 1. Working tree state — confirm committed
run "git status (confirm committed)" git -C "$REPO" status --short --branch
DIRTY=$(git -C "$REPO" status --short)
if [ -n "$DIRTY" ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
    log "DEVIATION: working tree has uncommitted changes (worker should have committed):"
    log "$DIRTY"
    FAILURES=$((FAILURES + 1))
fi

# 2. Last commit — verify message matches scope (human judgment; logged as evidence)
run "git log (commit message vs scope)" git -C "$REPO" log --oneline -1

# 3. Mutated files vs scope fence
run "git show (mutated files in HEAD)" git -C "$REPO" show --name-only --format= HEAD
if [ -n "$FENCE" ]; then
    MUTATED=$(git -C "$REPO" show --name-only --format= HEAD)
    IFS=',' read -r -a FENCE_ARR <<< "$FENCE"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        ok=0
        for allowed in "${FENCE_ARR[@]}"; do
            [ "$f" = "$allowed" ] && ok=1 && break
        done
        if [ "$ok" -eq 0 ]; then
            log "DEVIATION: SCOPE-FENCE VIOLATION — '$f' mutated but not in declared fence [$FENCE]"
            FAILURES=$((FAILURES + 1))
        fi
    done <<< "$MUTATED"
else
    log ""
    log "NOTE: no --fence supplied; scope-fence check skipped. Compare the mutated"
    log "file list above against the task's Hard Scope Fence manually."
fi

# 4. Pushed — local HEAD must exist on the remote
if [ "$SKIP_PUSH" -eq 0 ]; then
    LOCAL_HEAD=$(git -C "$REPO" rev-parse HEAD)
    run "git ls-remote (confirm pushed)" git -C "$REPO" ls-remote origin
    if ! git -C "$REPO" ls-remote origin 2>/dev/null | grep -q "$LOCAL_HEAD"; then
        log "DEVIATION: local HEAD $LOCAL_HEAD not found on remote 'origin' (not pushed?)"
        FAILURES=$((FAILURES + 1))
    fi
else
    log ""
    log "NOTE: push check skipped (--skip-push)."
fi

# 5. Script syntax checks
for s in ${SCRIPTS[@]+"${SCRIPTS[@]}"}; do
    run "bash -n $s (syntax check)" bash -n "$s"
done

log ""
log "finished: $(date -Is)"
if [ "$FAILURES" -gt 0 ]; then
    log "RESULT: FAIL ($FAILURES deviation(s)) — do NOT dispatch reviewer."
    log "Scope creep? Dispatch a revert-worker (SKILL.md, recovery pattern b)."
    exit 1
fi
log "RESULT: PASS — safe to dispatch reviewer."
exit 0
