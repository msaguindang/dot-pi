#!/usr/bin/env bash
# Generate the docs worker task file (worker 2).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FIX_ID="" SERVER_VERSION="" FIX_SUMMARY="" DEPLOY_DATE=""
UI_VERSION="none"
FLEET_GITOPS_DIR="/data/dev/work/ntv/fleet-gitops"
OBSIDIAN_DIR="$HOME/Dropbox/Obsidian/2. Areas/01 Work/02 Fleet & Infra"
CONFLUENCE_SPACE="NCTV"
CONFLUENCE_PARENT_ID="949354515"   # ASSUMED default (see SKILL.md) — orchestrator should pass explicitly
CONFLUENCE_PAGE_ID="none"

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix-id) FIX_ID="$2"; shift 2 ;;
    --server-version) SERVER_VERSION="$2"; shift 2 ;;
    --ui-version) UI_VERSION="$2"; shift 2 ;;
    --fix-summary) FIX_SUMMARY="$2"; shift 2 ;;
    --deploy-date) DEPLOY_DATE="$2"; shift 2 ;;
    --fleet-gitops-dir) FLEET_GITOPS_DIR="$2"; shift 2 ;;
    --obsidian-dir) OBSIDIAN_DIR="$2"; shift 2 ;;
    --confluence-space) CONFLUENCE_SPACE="$2"; shift 2 ;;
    --confluence-parent-id) CONFLUENCE_PARENT_ID="$2"; shift 2 ;;
    --confluence-page-id) CONFLUENCE_PAGE_ID="$2"; shift 2 ;;
    *) die "gen-task-docs.sh: unknown arg $1" ;;
  esac
done
[[ -n $FIX_ID && -n $SERVER_VERSION && -n $FIX_SUMMARY && -n $DEPLOY_DATE ]] ||
  die "usage: gen-task-docs.sh --fix-id <id> --server-version <ver> --fix-summary <text> --deploy-date <date> [--ui-version <ver>] [--fleet-gitops-dir <dir>] [--obsidian-dir <dir>] [--confluence-space <key>] [--confluence-parent-id <id>] [--confluence-page-id <id>]"

TASK_FILE="/tmp/ship-docs-$FIX_ID-task.md"
RESULT_FILE="/tmp/ship-docs-$FIX_ID-result.md"

render_template "$TEMPLATE_DIR/task-docs-template.md" "$TASK_FILE" \
  "FIX_ID=$FIX_ID" \
  "SERVER_VERSION=$SERVER_VERSION" \
  "UI_VERSION=$UI_VERSION" \
  "FIX_SUMMARY=$FIX_SUMMARY" \
  "DEPLOY_DATE=$DEPLOY_DATE" \
  "FLEET_GITOPS_DIR=$FLEET_GITOPS_DIR" \
  "OBSIDIAN_DIR=$OBSIDIAN_DIR" \
  "CONFLUENCE_SPACE=$CONFLUENCE_SPACE" \
  "CONFLUENCE_PARENT_ID=$CONFLUENCE_PARENT_ID" \
  "CONFLUENCE_PAGE_ID=$CONFLUENCE_PAGE_ID" \
  "RESULT_FILE=$RESULT_FILE"

validate_task "$TASK_FILE"
echo "$TASK_FILE"
