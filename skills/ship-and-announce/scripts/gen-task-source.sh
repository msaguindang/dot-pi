#!/usr/bin/env bash
# Generate the source-fix worker task file (worker 1).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FIX_ID="" FIX_BRANCH="" SERVER_VERSION=""
REPO_DIR="/data/dev/work/ntv/player-server"

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix-id) FIX_ID="$2"; shift 2 ;;
    --fix-branch) FIX_BRANCH="$2"; shift 2 ;;
    --server-version) SERVER_VERSION="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    *) die "gen-task-source.sh: unknown arg $1" ;;
  esac
done
[[ -n $FIX_ID && -n $FIX_BRANCH && -n $SERVER_VERSION ]] ||
  die "usage: gen-task-source.sh --fix-id <id> --fix-branch <branch> --server-version <ver> [--repo-dir <dir>]"

TASK_FILE="/tmp/ship-source-$FIX_ID-task.md"
RESULT_FILE="/tmp/ship-source-$FIX_ID-result.md"

render_template "$TEMPLATE_DIR/task-source-template.md" "$TASK_FILE" \
  "FIX_ID=$FIX_ID" \
  "FIX_BRANCH=$FIX_BRANCH" \
  "SERVER_VERSION=$SERVER_VERSION" \
  "REPO_DIR=$REPO_DIR" \
  "RESULT_FILE=$RESULT_FILE"

validate_task "$TASK_FILE"
echo "$TASK_FILE"
