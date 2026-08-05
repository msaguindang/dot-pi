#!/usr/bin/env bash
# ship-and-announce orchestrator:
# validate -> generate 4 task files -> dispatch 4 parallel workers ->
# wait -> collect -> independent verification -> summary report.
# See SKILL.md for the full flow and hard rules (Teams draft is NEVER auto-sent).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
SCRIPTS="$SKILL_DIR/scripts"

FIX_ID="" FIX_BRANCH="" SERVER_VERSION="" FIX_SUMMARY="" DEPLOY_DATE=""
UI_VERSION="none" TICKETS="none" FOLLOWUPS="none" BUILD_ID=""
CONFLUENCE_SPACE="NCTV"
CONFLUENCE_PARENT_ID="949354515"   # ASSUMED (see SKILL.md Runtime Configuration)
CONFLUENCE_PAGE_ID="none"
PLANE_PROJECT="NTV Player V1"      # ASSUMED (see SKILL.md Runtime Configuration)
REPO_DIR="/data/dev/work/ntv/player-server"
FLEET_GITOPS_DIR="/data/dev/work/ntv/fleet-gitops"
OBSIDIAN_DIR="$HOME/Dropbox/Obsidian/2. Areas/01 Work/02 Fleet & Infra"
ROLLBACK_PLAN="Redeploy the previous release bundle (see the fleet-gitops release record rollback.md for the exact command)."
PLANE_TASKS_DIR="/home/codeweaver/.pi/agent/skills/plane-tasks"
S3_BUCKET="s3://ncompasstv-prod-player-apps/secure-rc"
SKIP_VALIDATE=0 NO_WAIT=0 RESUME=0

usage() {
  cat >&2 <<'EOF'
usage: orchestrate.sh --fix-id <slug> --fix-branch <branch> --server-version <ver> \
         --fix-summary "<1-2 sentences>" --deploy-date <YYYY-MM-DD> \
         [--ui-version <ver>] [--tickets "PV1-5,PV1-12"] [--followups "<text>"] \
         [--build-id <id>] [--rollback-plan "<text>"] \
         [--confluence-space NCTV] [--confluence-parent-id <id>] [--confluence-page-id <id>] \
         [--plane-project "<name>"] [--repo-dir <dir>] [--fleet-gitops-dir <dir>] \
         [--obsidian-dir <dir>] [--skip-validate] [--no-wait] [--resume]
--resume: skip validation/generation/dispatch; go straight to wait -> collect -> verify -> summary.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix-id) FIX_ID="$2"; shift 2 ;;
    --fix-branch) FIX_BRANCH="$2"; shift 2 ;;
    --server-version) SERVER_VERSION="$2"; shift 2 ;;
    --ui-version) UI_VERSION="$2"; shift 2 ;;
    --fix-summary) FIX_SUMMARY="$2"; shift 2 ;;
    --deploy-date) DEPLOY_DATE="$2"; shift 2 ;;
    --tickets) TICKETS="$2"; shift 2 ;;
    --followups) FOLLOWUPS="$2"; shift 2 ;;
    --build-id) BUILD_ID="$2"; shift 2 ;;
    --rollback-plan) ROLLBACK_PLAN="$2"; shift 2 ;;
    --confluence-space) CONFLUENCE_SPACE="$2"; shift 2 ;;
    --confluence-parent-id) CONFLUENCE_PARENT_ID="$2"; shift 2 ;;
    --confluence-page-id) CONFLUENCE_PAGE_ID="$2"; shift 2 ;;
    --plane-project) PLANE_PROJECT="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --fleet-gitops-dir) FLEET_GITOPS_DIR="$2"; shift 2 ;;
    --obsidian-dir) OBSIDIAN_DIR="$2"; shift 2 ;;
    --skip-validate) SKIP_VALIDATE=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --resume) RESUME=1; shift ;;
    *) echo "ERROR: unknown arg $1" >&2; usage ;;
  esac
done

[[ -n $FIX_ID ]] || usage
if (( ! RESUME )); then
  [[ -n $FIX_BRANCH && -n $SERVER_VERSION && -n $FIX_SUMMARY && -n $DEPLOY_DATE ]] || usage
fi

WORKERS=(source docs plane announce)
declare -A WTIMEOUT=([source]=600 [docs]=900 [plane]=600 [announce]=300)
OVERALL=900
task_file()   { printf '/tmp/ship-%s-%s-task.md' "$1" "$FIX_ID"; }
result_file() { printf '/tmp/ship-%s-%s-result.md' "$1" "$FIX_ID"; }
SUMMARY="/tmp/ship-summary-$FIX_ID.md"

if (( ! RESUME )); then
  # --- 1. Pre-dispatch validation ---
  if (( SKIP_VALIDATE )); then
    echo "== Pre-dispatch validation SKIPPED (--skip-validate) =="
  else
    echo "== Pre-dispatch validation =="
    "$SCRIPTS/pre-dispatch-validate.sh" \
      --fix-branch "$FIX_BRANCH" --repo-dir "$REPO_DIR" \
      --obsidian-dir "$OBSIDIAN_DIR" --plane-tasks-dir "$PLANE_TASKS_DIR" ||
      die "pre-dispatch validation failed — aborting before dispatch"
  fi

  # --- 2. Generate 4 task files (each gen script also runs delegation-validator) ---
  echo "== Generating task files =="
  "$SCRIPTS/gen-task-source.sh" --fix-id "$FIX_ID" --fix-branch "$FIX_BRANCH" \
    --server-version "$SERVER_VERSION" --repo-dir "$REPO_DIR"
  "$SCRIPTS/gen-task-docs.sh" --fix-id "$FIX_ID" --server-version "$SERVER_VERSION" \
    --ui-version "$UI_VERSION" --fix-summary "$FIX_SUMMARY" --deploy-date "$DEPLOY_DATE" \
    --fleet-gitops-dir "$FLEET_GITOPS_DIR" --obsidian-dir "$OBSIDIAN_DIR" \
    --confluence-space "$CONFLUENCE_SPACE" --confluence-parent-id "$CONFLUENCE_PARENT_ID" \
    --confluence-page-id "$CONFLUENCE_PAGE_ID"
  "$SCRIPTS/gen-task-plane.sh" --fix-id "$FIX_ID" --fix-branch "$FIX_BRANCH" \
    --server-version "$SERVER_VERSION" --fix-summary "$FIX_SUMMARY" \
    --deploy-date "$DEPLOY_DATE" --tickets "$TICKETS" --followups "$FOLLOWUPS" \
    --plane-project "$PLANE_PROJECT"
  "$SCRIPTS/gen-task-announce.sh" --fix-id "$FIX_ID" --server-version "$SERVER_VERSION" \
    --ui-version "$UI_VERSION" --fix-summary "$FIX_SUMMARY" --deploy-date "$DEPLOY_DATE" \
    --build-id "${BUILD_ID:-none}" --rollback-plan "$ROLLBACK_PLAN"

  # --- 3. Dispatch 4 workers in parallel (distinct output paths) ---
  if [[ -n ${SHIP_WORKER_CMD:-} ]]; then
    echo "== Dispatching 4 workers via SHIP_WORKER_CMD =="
    for w in "${WORKERS[@]}"; do
      rm -f "$(result_file "$w")"
      # shellcheck disable=SC2086  # word-splitting of SHIP_WORKER_CMD is intentional
      timeout "${WTIMEOUT[$w]}" $SHIP_WORKER_CMD "$(task_file "$w")" "$(result_file "$w")" \
        > "/tmp/ship-$w-$FIX_ID-worker.log" 2>&1 &
      echo "worker $w: pid $! timeout ${WTIMEOUT[$w]}s -> $(result_file "$w")"
    done
  else
    echo "== Dispatch block: launch these as 4 PARALLEL subagents (fresh context each) =="
    for w in "${WORKERS[@]}"; do
      cat <<EOF
--- worker: $w (timeout ${WTIMEOUT[$w]}s) ---
Execute the self-contained task in $(task_file "$w"). Write your result to
$(result_file "$w") in the exact format the task specifies. Touch nothing
outside the task's scope fence.
EOF
    done
    if (( NO_WAIT )); then
      echo "Dispatch the workers, then re-run: orchestrate.sh --fix-id $FIX_ID --resume"
      exit 0
    fi
  fi
fi

if (( NO_WAIT )); then
  echo "--no-wait: skipping wait/collect/verify. Re-run with --fix-id $FIX_ID --resume later."
  exit 0
fi

# --- 4. Wait for result files (per-worker deadlines, overall cap) ---
echo "== Waiting for results (per-worker ${WTIMEOUT[source]}/${WTIMEOUT[docs]}/${WTIMEOUT[plane]}/${WTIMEOUT[announce]}s, overall ${OVERALL}s) =="
declare -A WSTATE
for w in "${WORKERS[@]}"; do WSTATE[$w]=pending; done
START=$(date +%s)
while :; do
  pending=0
  elapsed=$(( $(date +%s) - START ))
  for w in "${WORKERS[@]}"; do
    [[ ${WSTATE[$w]} == pending ]] || continue
    if [[ -f $(result_file "$w") ]]; then
      WSTATE[$w]=done
      echo "worker $w: result present after ${elapsed}s"
    elif (( elapsed > WTIMEOUT[$w] )); then
      WSTATE[$w]=timeout
      echo "worker $w: TIMEOUT after ${elapsed}s (recorded, not fatal to others)"
    else
      pending=1
    fi
  done
  (( pending )) || break
  if (( elapsed > OVERALL )); then
    for w in "${WORKERS[@]}"; do
      if [[ ${WSTATE[$w]} == pending ]]; then WSTATE[$w]=timeout; echo "worker $w: TIMEOUT (overall cap)"; fi
    done
    break
  fi
  sleep 10
done

# --- 5. Collect ---
echo "== Collecting results =="
COLLECTED="$("$SCRIPTS/collect-results.sh" "$FIX_ID" 2>&1 || true)"
printf '%s\n' "$COLLECTED"

# --- 6. Final verification (parent, independent of worker claims) ---
echo "== Final verification =="
VERIFY=""
note() { local m="${1//$'\n'/ ; }"; VERIFY+="- $m"$'\n'; echo "- $m"; }

if out=$(git -C "$REPO_DIR" fetch origin next 2>&1 && git -C "$REPO_DIR" log --merges --oneline -1 origin/next 2>&1); then
  note "merge commit on origin/next: ${out##*$'\n'}"
else
  note "merge commit check FAILED: $out"
fi
if out=$(git -C "$REPO_DIR" show origin/next:package.json 2>/dev/null | grep -m1 '"version"'); then
  note "package.json on origin/next: $(echo "$out" | tr -d ' ,')"
else
  note "package.json version check FAILED on origin/next"
fi
for remote in origin forgejo; do
  if out=$(git -C "$REPO_DIR" ls-remote "$remote" refs/heads/next 2>&1); then
    note "$remote next HEAD: ${out%%$'\t'*}"
  else
    note "$remote ls-remote FAILED: $out"
  fi
done

if [[ -n $BUILD_ID ]]; then
  if out=$(aws s3 ls "$S3_BUCKET/$BUILD_ID/" 2>&1); then
    note "S3 release artifacts present under $S3_BUCKET/$BUILD_ID/: $(echo "$out" | wc -l) object(s)"
  else
    note "S3 check FAILED for $S3_BUCKET/$BUILD_ID/: $out"
  fi
else
  note "S3 check skipped (no --build-id; no new release bundle)"
fi

conf_url=$(grep -m1 '^confluence_url:' "$(result_file docs)" 2>/dev/null | awk '{print $2}' || true)
if [[ -n ${conf_url:-} && $conf_url != none ]]; then
  conf_body="/tmp/ship-confluence-$FIX_ID-check.html"
  code=$(curl -sL -m 20 -o "$conf_body" -w '%{http_code}' "$conf_url" 2>/dev/null || echo error)
  if [[ -n ${SERVER_VERSION:-} ]] && grep -qi "$SERVER_VERSION" "$conf_body" 2>/dev/null; then
    note "Confluence page $conf_url -> HTTP $code, mentions $SERVER_VERSION"
  else
    note "Confluence page $conf_url -> HTTP $code (version string not found in body — may need auth; verify manually)"
  fi
  rm -f "$conf_body"
else
  note "Confluence check skipped (no confluence_url in docs result)"
fi

# ponytail: verifies project visibility + grabs raw issue lines for the listed tickets;
# full state-transition assertion needs plane-issues.sh structured output — add if it bites.
# No --tickets is NOT a reason to skip: worker 3 is required to create a primary
# ticket in that case (see task-plane-template.md step 2), so it must show up
# in tickets_created below regardless of whether $TICKETS was supplied.
if command -v infisical >/dev/null 2>&1 && [[ -d $PLANE_TASKS_DIR ]]; then
  if out=$(cd "$PLANE_TASKS_DIR" && infisical run -- scripts/plane-projects.sh 2>&1 | grep -i "$PLANE_PROJECT" | head -1); then
    note "Plane project visible: $out"
  else
    note "Plane project '$PLANE_PROJECT' NOT found via plane-projects.sh — verify ticket states manually"
  fi
else
  note "Plane state check skipped (infisical/plane-tasks unavailable)"
fi
created=$(grep -m1 '^tickets_created:' "$(result_file plane)" 2>/dev/null | cut -d' ' -f2- || true)
if [[ $TICKETS == none || -z $TICKETS ]]; then
  if [[ -n ${created:-} && $created != none ]]; then
    note "no --tickets supplied; worker 3 created primary ticket(s): $created"
  else
    note "no --tickets supplied and no tickets_created found in $(result_file plane) — worker 3 skipped required ticket creation, follow up manually"
  fi
fi

# --- 7. Summary report ---
preview=$(sed -n '/^## Teams Draft/,/^## Details/{/^## /d;p}' "$(result_file announce)" 2>/dev/null | head -c 200 || true)
tickets_updated=$(grep -m1 '^tickets_updated:' "$(result_file plane)" 2>/dev/null | cut -d' ' -f2- || true)
tickets_created=$(grep -m1 '^tickets_created:' "$(result_file plane)" 2>/dev/null | cut -d' ' -f2- || true)

{
  echo "# ship-and-announce summary: $FIX_ID"
  echo
  echo "_Generated: $(date -Is) — server ${SERVER_VERSION:-?}, ui ${UI_VERSION:-none}_"
  echo
  echo "## Worker status"
  for w in "${WORKERS[@]}"; do
    st=$(grep -m1 '^status:' "$(result_file "$w")" 2>/dev/null | cut -d' ' -f2- || true)
    echo "- $w: ${WSTATE[$w]:-unknown} (reported: ${st:-n/a}) — $(result_file "$w")"
  done
  echo
  echo "## Collected results"
  echo '```'
  printf '%s\n' "$COLLECTED"
  echo '```'
  echo
  echo "## Independent verification"
  printf '%s' "$VERIFY"
  echo
  echo "## Teams draft preview (first 200 chars)"
  echo '```'
  printf '%s\n' "${preview:-<no draft found>}"
  echo '```'
  echo
  echo "## Action items"
  echo "- Review and paste the Teams message from $(result_file announce) to the deployments channel — it was NOT auto-sent (hard rule)."
  if [[ -n ${tickets_updated:-} && $tickets_updated != none ]]; then
    echo "- Plane tickets now Done: $tickets_updated"
  fi
  if [[ -n ${tickets_created:-} && $tickets_created != none ]]; then
    echo "- Plane tickets created: $tickets_created"
  fi
  if [[ ( -z ${tickets_updated:-} || $tickets_updated == none ) && ( -z ${tickets_created:-} || $tickets_created == none ) ]]; then
    echo "- Plane tickets: check $(result_file plane) — no updates or creations parsed. This fix shipped with NO Plane ticket; that should not happen — file one now."
  fi
  echo "- Rollback plan: $ROLLBACK_PLAN"
} > "$SUMMARY"

echo "== Summary ($SUMMARY) =="
cat "$SUMMARY"
