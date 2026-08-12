#!/bin/bash
set -euo pipefail

# ============================================================
# RPI Doctor: probe — read-only composite diagnostic bundle
# ============================================================
# Usage: ./probe.sh <device_or_ip> [--format text|json|csv]
# Runs the 9-command read-only bundle over a single SSH session,
# writes a labeled report to /tmp/probe-<host>-<timestamp>.<ext>,
# and prints a short summary to stdout.
#
# READ-ONLY GUARANTEE: every remote command only reads state
# (pm2 list/logs --nostream, ls, tail, cat, grep, crontab -l,
# timedatectl/date). No writes, no restarts, no config changes.
# Idempotent: repeated runs differ only by timestamps.
#
# SSH invocation/auth mirrors diagnose.sh: inventory resolution,
# password auth default (sshpass, RPI_PASS), key-first fallback.
# ============================================================

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${RPI_INVENTORY:-$script_dir/../device-inventory.json}"

# Device paths — marked ASSUMED in the handoff spec.
# TODO: confirm these against a live device; override via env if they differ.
DEPLOY_LOG_DIR="${RPI_DEPLOY_LOG_DIR:-/tmp/ntv-deploy-logs}"
MANIFEST="${RPI_MANIFEST:-/tmp/ntv-deploy-logs/deployment-manifest.json}"
SERVER_PKG="${RPI_SERVER_PKG:-/home/pi/n-compasstv/player-server/package.json}"
UI_PKG="${RPI_UI_PKG:-/var/www/html/ui/package.json}"

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# --- Args ---------------------------------------------------
TARGET="${1:-}"
[[ -n "$TARGET" ]] || log_error "Usage: probe.sh <device_or_ip> [--format text|json|csv]"
shift
FORMAT="text"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format) FORMAT="${2:-}"; shift 2 ;;
        --format=*) FORMAT="${1#*=}"; shift ;;
        *) log_error "Unknown argument: $1" ;;
    esac
done
case "$FORMAT" in text|json|csv) ;; *) log_error "Invalid format '$FORMAT' (use text|json|csv)";; esac

# --- Resolve target (same pattern as diagnose.sh) -----------
HOST="$TARGET"
USER="${RPI_USER:-pi}"
AUTH="password" # Lab fleet default is password auth (pi/raspberry); key auth is the exception

if [[ -f "$INVENTORY_FILE" ]]; then
    DEVICE_JSON=$(grep -A 5 "\"name\": \"$TARGET\"" "$INVENTORY_FILE" || true)
    if [[ -n "$DEVICE_JSON" ]]; then
        HOST=$(echo "$DEVICE_JSON" | grep '"host"' | cut -d '"' -f 4)
        USER=$(echo "$DEVICE_JSON" | grep '"user"' | cut -d '"' -f 4)
        AUTH=$(echo "$DEVICE_JSON" | grep '"auth"' | cut -d '"' -f 4)
        if [[ -z "$HOST" || -z "$USER" || -z "$AUTH" ]]; then
            log_error "Found '$TARGET' in inventory but failed to extract host/user/auth (malformed entry)."
        fi
        log_info "Found '$TARGET' in local inventory. Resolved to: $USER@$HOST ($AUTH auth)"
    fi
fi

# --- Build the read-only remote bundle (9 commands) ----------
# Each section is delimited by ===SEC:n=== / ===RC:n=== markers so
# one SSH round-trip carries the whole bundle.
REMOTE_SCRIPT=$(cat <<EOF
echo '===SEC:1==='; pm2 list 2>&1; echo "===RC:\$?==="
echo '===SEC:2==='; ls -lt '$DEPLOY_LOG_DIR' 2>&1; echo "===RC:\$?==="
echo '===SEC:3==='; latest=\$(ls -t '$DEPLOY_LOG_DIR' 2>/dev/null | head -1); if [ -n "\$latest" ]; then tail -50 "$DEPLOY_LOG_DIR/\$latest" 2>&1; else echo 'N/A: no deploy logs found'; false; fi; echo "===RC:\$?==="
echo '===SEC:4==='; cat '$MANIFEST' 2>&1; echo "===RC:\$?==="
echo '===SEC:5==='; grep '"version"' '$SERVER_PKG' 2>&1; echo "===RC:\$?==="
echo '===SEC:6==='; grep '"version"' '$UI_PKG' 2>&1; echo "===RC:\$?==="
echo '===SEC:7==='; pm2 logs --nostream --lines 30 2>&1; echo "===RC:\$?==="
echo '===SEC:8==='; crontab -l 2>&1; echo "===RC:\$?==="
echo '===SEC:9==='; timedatectl 2>&1 || date -u 2>&1; echo "===RC:\$?==="
EOF
)

# --- Execute over SSH (same timeouts/auth as diagnose.sh) ----
log_info "Probing $USER@$HOST..."
set +e
if [[ "$AUTH" == "password" ]]; then
    RAW=$(sshpass -p "${RPI_PASS:-raspberry}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$HOST" "$REMOTE_SCRIPT" 2>/dev/null)
    SSH_RC=$?
else
    RAW=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$USER@$HOST" "$REMOTE_SCRIPT" 2>/dev/null)
    SSH_RC=$?
    if [[ $SSH_RC -ne 0 && -z "$RAW" ]]; then
        log_info "Key-based SSH failed, trying password fallback..."
        RAW=$(sshpass -p "${RPI_PASS:-raspberry}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$HOST" "$REMOTE_SCRIPT" 2>/dev/null)
        SSH_RC=$?
    fi
fi
set -e

if [[ $SSH_RC -eq 255 || -z "$RAW" ]]; then
    echo "SSH connection failed to $HOST:22" >&2
    exit 1
fi

# Strip ANSI color codes (pm2 output is colorized)
RAW=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$RAW")

# --- Parse sections ------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for i in 1 2 3 4 5 6 7 8 9; do : > "$TMP/sec$i.out"; echo 1 > "$TMP/sec$i.rc"; done
awk -v dir="$TMP" '
    /^===SEC:[0-9]+===$/ { n=$0; gsub(/[^0-9]/,"",n); next }
    /^===RC:[0-9]+===$/  { rc=$0; gsub(/[^0-9]/,"",rc); print rc > (dir "/sec" n ".rc"); next }
    n != "" { print >> (dir "/sec" n ".out") }
' <<<"$RAW"

sec() { cat "$TMP/sec$1.out"; }
rc()  { cat "$TMP/sec$1.rc"; }

# --- Analysis -------------------------------------------------
PROBED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP=$(date -u +%Y%m%d-%H%M%S)
ERR_RE='ERROR|FAILED|CRITICAL|exception|panic'

server_ver=$(sec 5 | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)
[[ "$(rc 5)" -eq 0 && -n "$server_ver" ]] || server_ver="unknown"
ui_ver=$(sec 6 | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)
[[ "$(rc 6)" -eq 0 && -n "$ui_ver" ]] || ui_ver="not installed"

latest_log=$(sec 2 | awk 'NR==2 {print $NF}')
[[ -n "$latest_log" ]] || latest_log="none"

offline=$(sec 1 | grep -cE 'stopped|errored' || true)
err_deploy=$(sec 3 | grep -ciE "$ERR_RE" || true)
# player-chromium's GPU/DBus/extension-manifest errors are known-benign,
# always-present headless-Chromium noise that does not affect playback —
# exclude its log lines from the error tally/health verdict. Still shown
# in the raw section 6 log tail for reference, just not counted here.
err_pm2=$(sec 7 | grep -v '|player-c' | grep -ciE "$ERR_RE" || true)
errors=$((err_deploy + err_pm2))
cron_count=$(sec 8 | grep -cE '^[^#[:space:]].*[^[:space:]]' || true)
[[ "$(rc 8)" -eq 0 ]] || cron_count=0
latest_err=$( { sec 3; sec 7 | grep -v '|player-c'; } | grep -iE "$ERR_RE" | tail -1 || true)

if (( errors >= 3 || offline >= 2 )); then
    HEALTH="CRITICAL"; RECO="investigate process restart / check logs immediately"
elif (( errors >= 1 || offline >= 1 )); then
    HEALTH="WARNING"; RECO="check logs ($errors error(s), $offline offline process(es) detected)"
else
    HEALTH="GOOD"; RECO="deployment verified — device healthy"
fi

pm2_ok="OK"; (( offline > 0 )) && pm2_ok="$offline process(es) not online"
# Trim each line and join with "; " — no trailing separator (tr can't do multi-char)
time_sync=$(sec 9 | grep -iE 'synchronized|NTP service' | head -2 \
    | awk '{gsub(/^[ \t]+|[ \t]+$/,"")} NR>1{out=out"; "} {out=out $0} END{print out}' || true)
[[ -n "$time_sync" ]] || time_sync="$(sec 9 | head -1)"

REPORT="/tmp/probe-$HOST-$STAMP.$FORMAT"
[[ "$FORMAT" == "text" ]] && REPORT="/tmp/probe-$HOST-$STAMP.txt"

# --- Formatters -----------------------------------------------
section_body() { # $1=secnum — output with N/A note on failure
    local r; r=$(rc "$1")
    sec "$1"
    [[ "$r" -ne 0 ]] && echo "(command exited $r — section N/A)"
}

format_text() {
    cat <<TXT
=== RPi Probe Report ===
Device: $HOST
Probed: $PROBED_AT
SSH User: $USER
Exit Code: 0

--- 1. Process State (pm2 list) ---
$(section_body 1)
Status Summary: $pm2_ok

--- 2. Deploy Logs (ls -lt $DEPLOY_LOG_DIR) ---
Latest log: $latest_log
$(section_body 2)

--- 3. Deploy Log Tail (newest 50 lines) ---
$(section_body 3)
Errors detected: ${err_deploy:-0}

--- 4. Deployment Manifest ---
$(section_body 4)

--- 5. Installed Versions ---
Server: $server_ver (from $SERVER_PKG)
UI: $ui_ver (from $UI_PKG)

--- 6. PM2 Application Logs (last 30 lines) ---
$(section_body 7)
Errors detected: ${err_pm2:-0}

--- 7. Crontab State ---
$(section_body 8)
Status: $cron_count entries

--- 8. System Time ---
$(section_body 9)
Time Sync: $time_sync

=== Summary ===
Health: $HEALTH
Key Findings:
- Process state: $pm2_ok
- Latest deploy log: $latest_log (server $server_ver, UI $ui_ver)
- Errors in logs: $errors
- Cron jobs: $cron_count entries
- Time sync: $time_sync

Recommendation: $RECO
TXT
}

# ponytail: escapes \\ " tab CR + newlines only; raw control chars beyond
# these would break JSON — upgrade to python3 json.dumps if that ever bites.
jesc() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' | awk 'NR>1{printf("\\n")} {printf("%s",$0)}'; }

json_section() { # $1=secnum $2=command
    printf '{"command": "%s", "exit_code": %s, "output": "%s"}' \
        "$(jesc <<<"$2")" "$(rc "$1")" "$(sec "$1" | jesc)"
}

format_json() {
    cat <<JSON
{
  "device": "$HOST",
  "probed_at": "$PROBED_AT",
  "ssh_user": "$USER",
  "exit_code": 0,
  "sections": {
    "process_state": $(json_section 1 "pm2 list"),
    "deploy_logs": $(json_section 2 "ls -lt $DEPLOY_LOG_DIR"),
    "deploy_log_tail": $(json_section 3 "tail -50 <newest deploy log>"),
    "deployment_manifest": $(json_section 4 "cat $MANIFEST"),
    "versions": {"server": "$(jesc <<<"$server_ver")", "ui": "$(jesc <<<"$ui_ver")"},
    "application_logs": $(json_section 7 "pm2 logs --nostream --lines 30"),
    "crontab": $(json_section 8 "crontab -l"),
    "system_time": $(json_section 9 "timedatectl || date -u")
  },
  "summary": {
    "health": "$HEALTH",
    "errors_detected": $errors,
    "offline_processes": $offline,
    "key_findings": [
      "Process state: $(jesc <<<"$pm2_ok")",
      "Latest deploy log: $(jesc <<<"$latest_log") (server $server_ver, UI $(jesc <<<"$ui_ver"))",
      "Errors in logs: $errors",
      "Cron jobs: $cron_count entries",
      "Time sync: $(jesc <<<"$time_sync")"
    ],
    "recommendation": "$(jesc <<<"$RECO")"
  }
}
JSON
}

cesc() { sed 's/"/""/g' | tr '\n' ' ' | sed 's/ *$//'; }

format_csv() {
    cat <<CSV
key,value
device,"$HOST"
probed_at,"$PROBED_AT"
health,"$HEALTH"
server_version,"$server_ver"
ui_version,"$(cesc <<<"$ui_ver")"
latest_deploy_log,"$latest_log"
errors_detected,$errors
offline_processes,$offline
cron_entries,$cron_count
time_sync,"$(cesc <<<"$time_sync")"
recommendation,"$(cesc <<<"$RECO")"
CSV
}

case "$FORMAT" in
    text) format_text > "$REPORT" ;;
    json) format_json > "$REPORT"
          if command -v jq >/dev/null 2>&1; then # jq optional: pretty-print only
              jq . "$REPORT" > "$REPORT.pretty" 2>/dev/null && mv "$REPORT.pretty" "$REPORT" || rm -f "$REPORT.pretty"
          fi ;;
    csv)  format_csv > "$REPORT" ;;
esac

# --- stdout summary -------------------------------------------
echo "Device: $HOST | Health: $HEALTH"
echo "Server: $server_ver | UI: $ui_ver"
echo "Errors in logs: $errors | Offline processes: $offline | Latest: ${latest_err:-OK}"
echo "Report: $REPORT"
exit 0
