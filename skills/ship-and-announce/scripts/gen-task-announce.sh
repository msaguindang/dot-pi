#!/usr/bin/env bash
# Generate the Teams announcement worker task file (worker 4). Draft only — never auto-sent.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FIX_ID="" SERVER_VERSION="" FIX_SUMMARY="" DEPLOY_DATE=""
UI_VERSION="none"
BUILD_ID="none"
ROLLBACK_PLAN="Redeploy the previous release bundle (see the fleet-gitops release record rollback.md for the exact command)."

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix-id) FIX_ID="$2"; shift 2 ;;
    --server-version) SERVER_VERSION="$2"; shift 2 ;;
    --ui-version) UI_VERSION="$2"; shift 2 ;;
    --fix-summary) FIX_SUMMARY="$2"; shift 2 ;;
    --deploy-date) DEPLOY_DATE="$2"; shift 2 ;;
    --build-id) BUILD_ID="$2"; shift 2 ;;
    --rollback-plan) ROLLBACK_PLAN="$2"; shift 2 ;;
    *) die "gen-task-announce.sh: unknown arg $1" ;;
  esac
done
[[ -n $FIX_ID && -n $SERVER_VERSION && -n $FIX_SUMMARY && -n $DEPLOY_DATE ]] ||
  die "usage: gen-task-announce.sh --fix-id <id> --server-version <ver> --fix-summary <text> --deploy-date <date> [--ui-version <ver>] [--build-id <id>] [--rollback-plan <text>]"

TASK_FILE="/tmp/ship-announce-$FIX_ID-task.md"
RESULT_FILE="/tmp/ship-announce-$FIX_ID-result.md"

render_template "$TEMPLATE_DIR/task-announce-template.md" "$TASK_FILE" \
  "FIX_ID=$FIX_ID" \
  "SERVER_VERSION=$SERVER_VERSION" \
  "UI_VERSION=$UI_VERSION" \
  "FIX_SUMMARY=$FIX_SUMMARY" \
  "DEPLOY_DATE=$DEPLOY_DATE" \
  "BUILD_ID=$BUILD_ID" \
  "ROLLBACK_PLAN=$ROLLBACK_PLAN" \
  "RESULT_FILE=$RESULT_FILE"

validate_task "$TASK_FILE"
echo "$TASK_FILE"
