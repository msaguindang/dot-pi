#!/usr/bin/env bash
# Generate the Plane tickets worker task file (worker 3).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FIX_ID="" FIX_BRANCH="" SERVER_VERSION="" FIX_SUMMARY="" DEPLOY_DATE=""
TICKET_IDS="none"
FOLLOWUPS="none"
PLANE_PROJECT="NTV Player V1"   # ASSUMED default (see SKILL.md) — worker resolves the id at runtime

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix-id) FIX_ID="$2"; shift 2 ;;
    --fix-branch) FIX_BRANCH="$2"; shift 2 ;;
    --server-version) SERVER_VERSION="$2"; shift 2 ;;
    --fix-summary) FIX_SUMMARY="$2"; shift 2 ;;
    --deploy-date) DEPLOY_DATE="$2"; shift 2 ;;
    --tickets) TICKET_IDS="$2"; shift 2 ;;
    --followups) FOLLOWUPS="$2"; shift 2 ;;
    --plane-project) PLANE_PROJECT="$2"; shift 2 ;;
    *) die "gen-task-plane.sh: unknown arg $1" ;;
  esac
done
[[ -n $FIX_ID && -n $FIX_BRANCH && -n $SERVER_VERSION && -n $FIX_SUMMARY && -n $DEPLOY_DATE ]] ||
  die "usage: gen-task-plane.sh --fix-id <id> --fix-branch <branch> --server-version <ver> --fix-summary <text> --deploy-date <date> [--tickets PV1-5,PV1-12] [--followups <text>] [--plane-project <name>]"

TASK_FILE="/tmp/ship-plane-$FIX_ID-task.md"
RESULT_FILE="/tmp/ship-plane-$FIX_ID-result.md"

render_template "$TEMPLATE_DIR/task-plane-template.md" "$TASK_FILE" \
  "FIX_ID=$FIX_ID" \
  "FIX_BRANCH=$FIX_BRANCH" \
  "SERVER_VERSION=$SERVER_VERSION" \
  "FIX_SUMMARY=$FIX_SUMMARY" \
  "DEPLOY_DATE=$DEPLOY_DATE" \
  "TICKET_IDS=$TICKET_IDS" \
  "FOLLOWUPS=$FOLLOWUPS" \
  "PLANE_PROJECT=$PLANE_PROJECT" \
  "RESULT_FILE=$RESULT_FILE"

validate_task "$TASK_FILE"
echo "$TASK_FILE"
