#!/usr/bin/env bash
# Pre-dispatch validation for ship-and-announce.
# Prints PASS/FAIL per check with evidence. Exit 0 = all pass, 1 = any fail.
set -uo pipefail   # no -e: run every check, report all failures

FIX_BRANCH=""
REPO_DIR="/data/dev/work/ntv/player-server"
OBSIDIAN_DIR="$HOME/Dropbox/Obsidian/2. Areas/01 Work/02 Fleet & Infra"
CONFLUENCE_URL="https://n-compass.atlassian.net/wiki/spaces/NCTV"
PLANE_TASKS_DIR="/home/codeweaver/.pi/agent/skills/plane-tasks"

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix-branch) FIX_BRANCH="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --obsidian-dir) OBSIDIAN_DIR="$2"; shift 2 ;;
    --confluence-url) CONFLUENCE_URL="$2"; shift 2 ;;
    --plane-tasks-dir) PLANE_TASKS_DIR="$2"; shift 2 ;;
    *) echo "ERROR: pre-dispatch-validate.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

FAIL=0
report() { # report pass|fail <name> <evidence>
  if [[ $1 == pass ]]; then echo "PASS: $2 — $3"; else echo "FAIL: $2 — $3"; FAIL=1; fi
}

# 1. fix branch exists on origin
if [[ -z $FIX_BRANCH ]]; then
  report fail "fix-branch on origin" "--fix-branch not supplied"
else
  ref="$(git -C "$REPO_DIR" ls-remote origin "refs/heads/$FIX_BRANCH" 2>&1)"
  if [[ $ref == *refs/heads/* ]]; then
    report pass "fix-branch on origin" "$ref"
  else
    report fail "fix-branch on origin" "git ls-remote found no ref for '$FIX_BRANCH' in $REPO_DIR (${ref:-empty output})"
  fi
fi

# 2. Obsidian target dir writable
if [[ -d $OBSIDIAN_DIR && -w $OBSIDIAN_DIR ]]; then
  report pass "obsidian dir writable" "$OBSIDIAN_DIR"
else
  report fail "obsidian dir writable" "$OBSIDIAN_DIR missing or not writable"
fi

# 3. Confluence reachable (unauthenticated reachability only; 2xx/3xx accepted)
code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$CONFLUENCE_URL" 2>/dev/null)"
case ${code:-000} in
  2*|3*) report pass "confluence reachable" "HTTP $code from $CONFLUENCE_URL" ;;
  *)     report fail "confluence reachable" "HTTP ${code:-error} from $CONFLUENCE_URL" ;;
esac

# 4. Plane secrets injectable via infisical (cwd-sensitive)
if ! command -v infisical >/dev/null 2>&1; then
  report fail "plane secrets via infisical" "infisical CLI not on PATH"
elif [[ ! -d $PLANE_TASKS_DIR ]]; then
  report fail "plane secrets via infisical" "plane-tasks dir missing: $PLANE_TASKS_DIR"
elif (cd "$PLANE_TASKS_DIR" && infisical run -- true >/dev/null 2>&1); then
  report pass "plane secrets via infisical" "infisical run -- true succeeded from $PLANE_TASKS_DIR"
else
  report fail "plane secrets via infisical" "infisical run -- true failed from $PLANE_TASKS_DIR (login/config?)"
fi

exit $FAIL
