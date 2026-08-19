#!/usr/bin/env bash
# =============================================================================
# release.sh — ntv-release orchestrator (ritual steps 4–7)
# =============================================================================
# Two phases, because device update scripts must be hand-adapted between
# build-id generation and upload (they embed their build id in their S3 URLs):
#
#   release.sh init    --server-version X.Y.Z --ui-version A.B.C [options]
#       Preflight, prod builds, prior-stable detection, creates the
#       fleet-gitops release directory with release.yaml, rollback.md,
#       verification.md, copies zips + script templates in.
#
#       Mints THREE independent build ids (not one shared BUILD_ID), so a
#       release that only changes one component doesn't force the unchanged
#       component's devices to redundantly re-download it:
#         - BUNDLE_BUILD_ID  — always fresh. Identifies where deploy-ntv-bundle.sh
#                              and rollback-bundle.sh live (the orchestrator is
#                              re-adapted every release regardless of scope).
#         - SERVER_BUILD_ID  — fresh unless --skip-server-build, in which case
#                              it's the PRIOR release's server_build_id (the
#                              prior artifact is still live at that prefix —
#                              nothing new to upload).
#         - UI_BUILD_ID      — same pattern, mirrored for player-ui.
#
#   (agent/human adapts deploy-ntv-bundle.sh, update-*.sh, rollback-bundle.sh
#    in the release dir — embed the build ids, versions, per deploy-script-standard)
#
#   release.sh publish <release-dir> [--execute]
#       bash -n all scripts, gen checksums, local validation, S3 upload
#       (immutability-guarded per fresh prefix; reused prefixes are verified
#       present, not re-uploaded), S3 verify, git commit + push to both remotes.
#       DRY-RUN unless --execute.
#
# init options:
#   --server-version X.Y.Z     required
#   --ui-version A.B.C         required (coupling rule: always both versions)
#   --fix-branch NAME          recorded in the release summary (informational)
#   --server-repo PATH         default /data/dev/work/ntv/player-server
#   --ui-repo PATH             default /data/dev/work/ntv/player-ui
#   --gitops PATH              default /data/dev/work/ntv/fleet-gitops (or $NTV_GITOPS)
#   --skip-server-build        reuse existing builds/player-server-X.Y.Z.zip
#                              AND reuse the prior release's SERVER_BUILD_ID
#                              (nothing server-side is uploaded this release)
#   --skip-ui-build            reuse existing builds/player-ui-A.B.C.zip
#                              AND reuse the prior release's UI_BUILD_ID
#                              (server-only patch: UI zip from prior release)
#   --prior-server REF         override prior-stable server tag/version
#   --prior-ui REF             override prior-stable UI tag/version
#   --from-release RELEASE_ID  override auto-detected prior release directory
#                              (bypasses lifecycle-status auto-detection entirely;
#                              RELEASE_ID is a dir name under player-apps/releases)
#   --build-id UUID            REUSE an existing BUNDLE_BUILD_ID (bundle prefix
#                              only — SERVER_BUILD_ID/UI_BUILD_ID are unaffected).
#                              Only legal for the staged-never-fetched overwrite
#                              exception; needs --confirm-staged-overwrite AND
#                              an interactive typed confirmation. Never use this
#                              without explicit human sign-off.
#   --confirm-staged-overwrite required companion to --build-id
# =============================================================================
set -euo pipefail

GITOPS="${NTV_GITOPS:-/data/dev/work/ntv/fleet-gitops}"
SERVER_REPO="/data/dev/work/ntv/player-server"
UI_REPO="/data/dev/work/ntv/player-ui"
S3_BUCKET="ncompasstv-prod-player-apps"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[ntv-release] $*"; }

validate_release_artifacts() { # <server-zip> <ui-zip> <ui-version> <server-version>
    local server_zip="$1" ui_zip="$2" ui_version="$3" server_version="$4"
    local expected_ui_index="player-ui-${ui_version}/index.html"
    local server_prefix="player-server-${server_version}"
    # Required members, not a raw byte-size heuristic — src/public/** is
    # gitignored runtime data (downloaded assets, screenshots) that a clean
    # checkout never has at build time, so total zip size varies legitimately
    # release to release and is not a signal of a broken build.
    local required_server_members=(
        "${server_prefix}/package.json"
        "${server_prefix}/.env"
        "${server_prefix}/build-info.json"
        "${server_prefix}/src/app.js"
        "${server_prefix}/src/cli/flush-play-logs.js"
        "${server_prefix}/src/bin/chromium-browser-kiosk-mode.sh"
    )

    [[ -f "$server_zip" ]] || err "expected build artifact missing: $server_zip"
    [[ -f "$ui_zip" ]] || err "expected build artifact missing: $ui_zip"
    unzip -tqq "$server_zip" >/dev/null 2>&1 \
        || err "server artifact is not a valid zip: $server_zip"
    local member server_members
    server_members="$(unzip -Z1 "$server_zip")"
    for member in "${required_server_members[@]}"; do
        grep -Fx "$member" <<< "$server_members" >/dev/null \
            || err "server artifact missing expected member $member: $server_zip"
    done
    unzip -tqq "$ui_zip" >/dev/null 2>&1 \
        || err "UI artifact is not a valid zip: $ui_zip"
    unzip -Z1 "$ui_zip" | grep -Fx "$expected_ui_index" >/dev/null \
        || err "UI artifact missing expected member $expected_ui_index: $ui_zip"
}

# --- template rendering: replace {{KEY}} tokens via env pairs ---------------
render() { # render <template> <out> KEY=VALUE...
    local tpl="$1" out="$2"; shift 2
    local content; content="$(cat "$tpl")"
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"; val="${kv#*=}"
        content="${content//\{\{${key}\}\}/${val}}"
    done
    printf '%s\n' "$content" > "$out"
    if grep -q '{{[A-Z_]*}}' "$out"; then
        echo "WARN: unsubstituted placeholders remain in $out:" >&2
        grep -o '{{[A-Z_]*}}' "$out" | sort -u >&2
    fi
}

# Best-effort scalar lookup under the top-level s3: block. Prints nothing
# (not an error) on missing/duplicate/empty — callers that need strictness
# check the count themselves (get_s3_id/get_s3_bool); callers reading a PRIOR
# release (which may still be in the old single-build_id schema) chain
# fallbacks instead (prior_component_build_id).
s3_field_matches() { # s3_field_matches <yaml-file> <field-name> -> 0+ lines
    local yaml_file="$1" field="$2"
    awk -v field="$field" '
      /^s3:[ \t]*(#.*)?$/ { in_s3 = 1; next }
      /^[a-zA-Z0-9_-]+:/ { in_s3 = 0 }
      in_s3 && $0 ~ "^[ \t]+" field ":[ \t]+" {
        val = $0
        sub("^[ \t]+" field ":[ \t]+", "", val)
        sub(/[ \t]*(#.*)?$/, "", val)
        gsub(/^"|"$|^'\''|'\''$/, "", val)
        if (val != "") print val
      }
    ' "$yaml_file" 2>/dev/null
}

probe_s3_field() { # probe_s3_field <yaml-file> <field-name> -> single value or empty
    local -a vals=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && vals+=("$line")
    done < <(s3_field_matches "$1" "$2")
    [[ "${#vals[@]}" -eq 1 ]] && echo "${vals[0]}"
    return 0
}

# Strict getter for a required UUID field. Used against OUR OWN generated
# release.yaml (cmd_publish), where a missing/duplicate/malformed value must
# hard-fail rather than silently fall back.
get_s3_id() { # get_s3_id <yaml-file> <field-name> -> UUID
    local yaml_file="$1" field="$2" matches num_matches val
    matches="$(s3_field_matches "$yaml_file" "$field")"
    num_matches=$(echo "$matches" | awk 'NF' | wc -l | tr -d ' ')
    if [[ "$num_matches" -eq 0 ]]; then
        echo "ERROR: missing s3.$field in $yaml_file" >&2
        exit 1
    elif [[ "$num_matches" -gt 1 ]]; then
        echo "ERROR: duplicate s3.$field in $yaml_file" >&2
        exit 1
    fi
    val=$(echo "$matches" | awk 'NF')
    if ! [[ "$val" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        echo "ERROR: malformed s3.$field in $yaml_file: $val" >&2
        exit 1
    fi
    echo "$val"
}

# Strict getter for a required boolean field (server_artifact_fresh / ui_artifact_fresh).
get_s3_bool() { # get_s3_bool <yaml-file> <field-name> -> true|false
    local yaml_file="$1" field="$2" val
    val="$(probe_s3_field "$yaml_file" "$field")"
    if [[ "$val" != "true" && "$val" != "false" ]]; then
        echo "ERROR: missing/duplicate/non-boolean s3.$field in $yaml_file: '$val'" >&2
        exit 1
    fi
    echo "$val"
}

# Reads a component build id from a PRIOR release's release.yaml for the
# --skip-*-build reuse path. Tries the new per-component field first, then
# falls back to the legacy shared s3.build_id (releases cut before this
# 3-id split used one BUILD_ID for everything, so it's a valid reuse source
# for either component). Empty output means neither was found.
provenance_field() { # provenance_field <yaml-file> <component> <field> -> value or empty
    # Matches the observed release.yaml indentation exactly (2 spaces for the
    # component key under provenance:, 4 spaces for its fields) — not a general
    # YAML parser, just enough for this file's one consistent shape.
    local yaml_file="$1" component="$2" field="$3"
    awk -v component="$component" -v field="$field" '
        $0 ~ "^  " component ":[ \t]*(#.*)?$" { in_comp = 1; next }
        in_comp && /^  [a-zA-Z0-9_-]+:/ { in_comp = 0 }
        in_comp && $0 ~ "^    " field ":[ \t]+" {
            val = $0
            sub("^    " field ":[ \t]+", "", val)
            sub(/[ \t]*(#.*)?$/, "", val)
            gsub(/^"|"$/, "", val)
            if (val != "") { print val; exit }
        }
    ' "$yaml_file" 2>/dev/null
}

prior_component_build_id() { # prior_component_build_id <yaml-file> <field-name> -> value or empty
    local yaml_file="$1" field="$2" val
    val="$(probe_s3_field "$yaml_file" "$field")"
    [[ -n "$val" ]] && { echo "$val"; return 0; }
    probe_s3_field "$yaml_file" "build_id"
}

# --- prior-stable detection --------------------------------------------------
# Source of truth: latest ANNOTATED v* tag (objecttype "tag"), sort -V.
# Bare vX.Y.Z tags are preferred; suffixed tags (v2.9.44-rc.0, v3.0.45-HLZHSVWV)
# are pre-release/variant and only used if no bare tag exists.
# Documented fallback: newest `chore(release): bump version to X.Y.Z` commit
# on the default branch (version bumps that never shipped may pollute this —
# always eyeball the result). Override with --prior-server / --prior-ui.
prior_stable() { # prior_stable <repo-path> [exclude-version] [releases-dir]  -> "ref version commit"
    local repo="$1" exclude_version="${2:-}" releases_dir="${3:-}" tag ver commit annotated candidates line
    annotated="$(git -C "$repo" for-each-ref 'refs/tags/v[0-9]*' \
            --format='%(objecttype) %(refname:short)' 2>/dev/null \
          | awk '$1=="tag"{print $2}')"
    candidates="$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<< "$annotated")"
    if [[ -n "$exclude_version" ]]; then
        # A same-version tag must only be excluded if it's premature — i.e. no
        # fleet-gitops release has actually shipped under that version yet
        # (main tagged at merge time, before that version's own S3 publish).
        # If a release record already exists for it, the tag is legitimate
        # and must NOT be excluded — re-requesting the same, already-shipped
        # version because a component is genuinely unchanged is a normal,
        # common case (e.g. player-ui staying at v3.1.21 across several
        # server-only releases) and must not be broken by this check.
        local already_shipped=false
        if [[ -n "$releases_dir" ]] && grep -rq "version: \"$exclude_version\"" "$releases_dir"/*/release.yaml 2>/dev/null; then
            already_shipped=true
        fi
        if [[ "$already_shipped" == "false" ]]; then
            local filtered=""
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                local v="${line#v}"
                if [[ "$v" != "$exclude_version" ]] && \
                   [[ "$(printf '%s\n%s\n' "$v" "$exclude_version" | sort -V | head -1)" == "$v" ]]; then
                    filtered+="$line"$'\n'
                fi
            done <<< "$candidates"
            candidates="$filtered"
        fi
    fi
    tag="$(sort -V <<< "$candidates" | tail -1)"
    [[ -n "$tag" ]] || tag="$(sort -V <<< "$annotated" | tail -1)"
    if [[ -n "$tag" ]]; then
        ver="${tag#v}"; ver="${ver%%-*}"
        commit="$(git -C "$repo" rev-list -n1 "$tag" | cut -c1-7)"
        echo "$tag $ver $commit"
        return 0
    fi
    # Fallback: chore(release) commit scan
    local line
    line="$(git -C "$repo" log --grep='chore(release)' --oneline -1 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
        commit="${line%% *}"
        ver="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$line" | head -1)"
        echo "chore-release-scan $ver $commit"
        return 0
    fi
    echo "UNKNOWN UNKNOWN UNKNOWN"
}

# --- supersession-by-reference detection ------------------------------------
# A release can be retired without its own status: field ever being flipped to
# `superseded` (data-hygiene gap — the human forgot). The reliable record is
# the REPLACING release's own `supersedes:` block:
#   supersedes:
#     release_id: <retired-id>
#     build_id: <uuid>
# Scan every release.yaml for such a block and print each referenced
# release_id (one per line). Most releases have no supersedes: block at all
# (that's normal, not an error) — under `set -euo pipefail` with pipefail on,
# a no-match grep poisons the whole pipeline's exit status even when later
# stages succeed, which would abort the entire script mid-loop. `|| true`
# guards that, matching the existing optional-field style elsewhere in this
# file (e.g. the chore(release) scan in prior_stable()).
superseded_release_ids() { # superseded_release_ids <releases-dir>
    local releases_dir="$1" yaml
    for yaml in "$releases_dir"/*/release.yaml; do
        [[ -f "$yaml" ]] || continue
        grep -A1 '^supersedes:' "$yaml" 2>/dev/null | grep 'release_id:' | awk '{print $2}' || true
    done
}

# --- prior-release directory selection --------------------------------------
# Newest release whose status isn't a retired lifecycle state (rolled-back /
# superseded — see the lifecycle comment in release.yaml) AND that isn't named
# in any sibling's `supersedes:` block (catches the case above where status:
# was never flipped — that's the primary fix, additive to the status check,
# since a rolled-back release with no recorded replacement has no supersedes:
# block at all). Ranked by created_at (preferred) or date field, NOT by
# directory/file path sort — path sort has no concept of release status and
# can pick a retired release if its dir name happens to sort last. On a tie
# (identical date/created_at string — day-granularity dates can collide
# across same-day releases), the release.yaml with the LATER mtime wins, since
# that reflects actual creation recency. Override with --from-release.
latest_active_release_dir() { # latest_active_release_dir <releases-dir> -> dir path (empty if none)
    local releases_dir="$1" yaml status ts this_id yaml_mtime
    local best_ts="" best_dir="" best_mtime=0
    local excluded; excluded="$(superseded_release_ids "$releases_dir")"
    for yaml in "$releases_dir"/*/release.yaml; do
        [[ -f "$yaml" ]] || continue
        status="$(grep -E '^status:' "$yaml" | head -1 | awk '{print $2}')"
        [[ "$status" == "rolled-back" || "$status" == "superseded" ]] && continue
        this_id="$(basename "$(dirname "$yaml")")"
        if grep -Fxq "$this_id" <<< "$excluded"; then
            continue
        fi
        # created_at is optional (older releases predate it) — `|| true` keeps
        # a no-match from poisoning the pipeline's exit status under pipefail
        # and aborting the whole script mid-loop (same reasoning as above).
        ts="$(grep -E '^created_at:' "$yaml" | head -1 | awk '{print $2}' | tr -d '"' || true)"
        [[ -n "$ts" ]] || ts="$(grep -E '^date:' "$yaml" | head -1 | awk '{print $2}' | tr -d '"' || true)"
        [[ -n "$ts" ]] || continue
        yaml_mtime="$(stat -c %Y "$yaml")"
        if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
            best_ts="$ts"; best_mtime="$yaml_mtime"; best_dir="$(dirname "$yaml")"
        elif [[ "$ts" == "$best_ts" && "$yaml_mtime" -gt "$best_mtime" ]]; then
            best_mtime="$yaml_mtime"; best_dir="$(dirname "$yaml")"
        fi
    done
    echo "$best_dir"
}

# =============================================================================
# INIT
# =============================================================================
cmd_init() {
    local SERVER_VERSION="" UI_VERSION="" FIX_BRANCH=""
    local SKIP_SERVER_BUILD=false SKIP_UI_BUILD=false
    local PRIOR_SERVER_OVERRIDE="" PRIOR_UI_OVERRIDE=""
    local FROM_RELEASE=""
    local BUNDLE_BUILD_ID="" CONFIRM_OVERWRITE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-version) SERVER_VERSION="${2:?}"; shift 2 ;;
            --ui-version)     UI_VERSION="${2:?}"; shift 2 ;;
            --fix-branch)     FIX_BRANCH="${2:?}"; shift 2 ;;
            --server-repo)    SERVER_REPO="${2:?}"; shift 2 ;;
            --ui-repo)        UI_REPO="${2:?}"; shift 2 ;;
            --gitops)         GITOPS="${2:?}"; shift 2 ;;
            --skip-server-build) SKIP_SERVER_BUILD=true; shift ;;
            --skip-ui-build)  SKIP_UI_BUILD=true; shift ;;
            --prior-server)   PRIOR_SERVER_OVERRIDE="${2:?}"; shift 2 ;;
            --prior-ui)       PRIOR_UI_OVERRIDE="${2:?}"; shift 2 ;;
            --from-release)   FROM_RELEASE="${2:?}"; shift 2 ;;
            --build-id)       BUNDLE_BUILD_ID="${2:?}"; shift 2 ;;
            --confirm-staged-overwrite) CONFIRM_OVERWRITE=true; shift ;;
            *) err "init: unknown option $1" ;;
        esac
    done

    [[ -n "$SERVER_VERSION" ]] || err "--server-version is required"
    [[ -n "$UI_VERSION"     ]] || err "--ui-version is required (coupling rule: releases always name both versions)"
    [[ "$SERVER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "bad server version: $SERVER_VERSION"
    [[ "$UI_VERSION"     =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "bad ui version: $UI_VERSION"
    [[ -d "$GITOPS/player-apps/releases" ]] || err "fleet-gitops releases dir not found: $GITOPS/player-apps/releases"
    [[ -d "$SERVER_REPO" ]] || err "server repo not found: $SERVER_REPO"
    [[ -d "$UI_REPO"     ]] || err "ui repo not found: $UI_REPO"

    local RELEASES_DIR="$GITOPS/player-apps/releases"

    # --- BUNDLE_BUILD_ID: fresh UUID; reuse only via the guarded staged-overwrite
    # path. Always fresh otherwise — the bundle orchestrator is re-adapted every
    # release regardless of which component(s) actually changed.
    if [[ -n "$BUNDLE_BUILD_ID" ]]; then
        [[ "$CONFIRM_OVERWRITE" == "true" ]] || err "--build-id reuse requires --confirm-staged-overwrite. HARD RULE: live build-id folders are immutable. Reuse is legal ONLY for a staged release no device has ever fetched — a human must verify deployment-manifest.json on all devices and explicitly approve."
        echo ""
        echo "!!! STAGED-OVERWRITE EXCEPTION REQUESTED for BUNDLE_BUILD_ID $BUNDLE_BUILD_ID"
        echo "!!! Preconditions the HUMAN must have verified (this script cannot):"
        echo "!!!   - release status is 'staged' in its release.yaml"
        echo "!!!   - NO device has fetched it (deployment-manifest.json on all devices)"
        echo "!!!   - explicit human approval was given"
        [[ -t 0 ]] || err "staged-overwrite confirmation must be typed interactively by a human (stdin is not a TTY). The skill never decides this alone."
        read -r -p "Type OVERWRITE-STAGED to proceed: " reply
        [[ "$reply" == "OVERWRITE-STAGED" ]] || err "confirmation not given — aborting."
    else
        BUNDLE_BUILD_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
        # Never reuse: refuse any UUID already recorded in fleet-gitops releases.
        # The substring match "build_id: $ID" also catches collisions against
        # bundle_build_id/server_build_id/ui_build_id (each ends in "build_id: ")
        # and the legacy single build_id field, so one check covers every schema.
        if grep -rq "build_id: $BUNDLE_BUILD_ID" "$RELEASES_DIR"/*/release.yaml 2>/dev/null; then
            err "generated BUNDLE_BUILD_ID collides with an existing release ($BUNDLE_BUILD_ID) — rerun."
        fi
    fi

    # --- repo preflight: committed package, lockfile, and changelog metadata --
    local repo which ver
    for which in server ui; do
        if [[ "$which" == "server" ]]; then repo="$SERVER_REPO"; ver="$SERVER_VERSION"; else repo="$UI_REPO"; ver="$UI_VERSION"; fi
        bash "$SKILL_DIR/scripts/validate-release-metadata.sh" "$repo" "$ver"
        [[ -z "$(git -C "$repo" status --porcelain)" ]] || err "$repo has uncommitted changes — commit or stash first."
    done

    # --- production builds ----------------------------------------------------
    local SERVER_ZIP="$SERVER_REPO/builds/player-server-$SERVER_VERSION.zip"
    local UI_ZIP="$UI_REPO/builds/player-ui-$UI_VERSION.zip"

    if [[ "$SKIP_SERVER_BUILD" == "false" ]]; then
        info "Building player-server $SERVER_VERSION (NODE_ENV=prod npm run build:prod)..."
        (cd "$SERVER_REPO" && NODE_ENV=prod npm run build:prod)
    fi
    if [[ "$SKIP_UI_BUILD" == "false" ]]; then
        info "Building player-ui $UI_VERSION (NODE_ENV=prod npm run build:prod)..."
        (cd "$UI_REPO" && NODE_ENV=prod npm run build:prod)
    else
        info "Skipping UI build — coupling rule: reusing existing zip $UI_ZIP"
    fi

    # Component-specific artifact sanity checks.
    validate_release_artifacts "$SERVER_ZIP" "$UI_ZIP" "$UI_VERSION" "$SERVER_VERSION"

    # --- prior-stable detection ------------------------------------------------
    local ps_ref ps_ver ps_commit pu_ref pu_ver pu_commit
    read -r ps_ref ps_ver ps_commit <<< "$(prior_stable "$SERVER_REPO" "$SERVER_VERSION" "$RELEASES_DIR")"
    read -r pu_ref pu_ver pu_commit <<< "$(prior_stable "$UI_REPO" "$UI_VERSION" "$RELEASES_DIR")"
    [[ -n "$PRIOR_SERVER_OVERRIDE" ]] && { ps_ref="$PRIOR_SERVER_OVERRIDE"; ps_ver="${PRIOR_SERVER_OVERRIDE#v}"; ps_ver="${ps_ver%%-*}"; }
    [[ -n "$PRIOR_UI_OVERRIDE"     ]] && { pu_ref="$PRIOR_UI_OVERRIDE"; pu_ver="${PRIOR_UI_OVERRIDE#v}"; pu_ver="${pu_ver%%-*}"; }
    info "Prior stable server: $ps_ver ($ps_ref @ ${ps_commit:-?})"
    info "Prior stable UI:     $pu_ver ($pu_ref @ ${pu_commit:-?})"

    # prior release dir: --from-release override, else newest non-retired release
    # (status not rolled-back/superseded), ranked by created_at/date — not path sort.
    local prior_release_dir
    if [[ -n "$FROM_RELEASE" ]]; then
        prior_release_dir="$RELEASES_DIR/$FROM_RELEASE"
        [[ -d "$prior_release_dir" ]] || err "--from-release: no such release dir: $prior_release_dir"
    else
        prior_release_dir="$(latest_active_release_dir "$RELEASES_DIR")"
        [[ -n "$prior_release_dir" ]] || err "no valid prior release found (all releases are rolled-back/superseded, or none exist) — use --from-release to specify one explicitly"
    fi

    local prior_yaml="$prior_release_dir/release.yaml"
    local prior_build_id="unknown"
    [[ -f "$prior_yaml" ]] && prior_build_id="$(prior_component_build_id "$prior_yaml" bundle_build_id)"
    [[ -n "$prior_build_id" ]] || prior_build_id="unknown"

    # The fleet-gitops release record is ground truth for what actually shipped
    # — prefer it over the git-tag-based prior_stable() result above whenever
    # one exists, since a real release can ship without ever being tagged
    # (true for everything before main started getting tagged on every
    # release). Without this, a stale tag can make prior_stable() point at an
    # older version than what's actually live, producing wrong rollback
    # targets and freshness decisions. An explicit --prior-server/--prior-ui
    # override still wins over both.
    if [[ -f "$prior_yaml" ]]; then
        if [[ -z "$PRIOR_SERVER_OVERRIDE" ]]; then
            local folder_ps_ver folder_ps_commit
            folder_ps_ver="$(provenance_field "$prior_yaml" "player-server" "version")"
            if [[ -n "$folder_ps_ver" && "$folder_ps_ver" != "$ps_ver" ]]; then
                folder_ps_commit="$(provenance_field "$prior_yaml" "player-server" "commit")"
                info "Correcting prior stable server from tag-based '$ps_ver' ($ps_ref) to fleet-gitops record '$folder_ps_ver' (${prior_release_dir##*/}) — the tag is stale or missing for the actual last-shipped version."
                ps_ver="$folder_ps_ver"; ps_commit="$folder_ps_commit"; ps_ref="release:${prior_release_dir##*/}"
            fi
        fi
        if [[ -z "$PRIOR_UI_OVERRIDE" ]]; then
            local folder_pu_ver folder_pu_commit
            folder_pu_ver="$(provenance_field "$prior_yaml" "player-ui" "version")"
            if [[ -n "$folder_pu_ver" && "$folder_pu_ver" != "$pu_ver" ]]; then
                folder_pu_commit="$(provenance_field "$prior_yaml" "player-ui" "commit")"
                info "Correcting prior stable UI from tag-based '$pu_ver' ($pu_ref) to fleet-gitops record '$folder_pu_ver' (${prior_release_dir##*/}) — the tag is stale or missing for the actual last-shipped version."
                pu_ver="$folder_pu_ver"; pu_commit="$folder_pu_commit"; pu_ref="release:${prior_release_dir##*/}"
            fi
        fi
    fi

    # --- SERVER_BUILD_ID / UI_BUILD_ID: freshness is decided by VERSION vs the
    # prior stable release, not by --skip-*-build. That flag only means "don't
    # re-run npm run build:prod, the zip's already on disk" (e.g. it was just
    # built once for QA) — it says nothing about whether this version differs
    # from the prior release. Conflating the two pointed a changed component
    # at a stale S3 prefix that never got its new artifact uploaded.
    local SERVER_BUILD_ID="" UI_BUILD_ID=""
    local SERVER_ARTIFACT_FRESH UI_ARTIFACT_FRESH

    if [[ "$SERVER_VERSION" == "$ps_ver" ]]; then
        [[ -f "$prior_yaml" ]] && SERVER_BUILD_ID="$(prior_component_build_id "$prior_yaml" server_build_id)"
        [[ -n "$SERVER_BUILD_ID" ]] || err "server version $SERVER_VERSION matches prior stable but prior release $prior_release_dir has no server_build_id (or legacy build_id) to reuse — use --from-release to pick a release that shipped a server artifact."
        SERVER_ARTIFACT_FRESH=false
        info "Reusing prior SERVER_BUILD_ID (server version unchanged: $SERVER_VERSION): $SERVER_BUILD_ID"
    else
        SERVER_BUILD_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
        if grep -rq "build_id: $SERVER_BUILD_ID" "$RELEASES_DIR"/*/release.yaml 2>/dev/null; then
            err "generated SERVER_BUILD_ID collides with an existing release ($SERVER_BUILD_ID) — rerun."
        fi
        SERVER_ARTIFACT_FRESH=true
    fi

    if [[ "$UI_VERSION" == "$pu_ver" ]]; then
        [[ -f "$prior_yaml" ]] && UI_BUILD_ID="$(prior_component_build_id "$prior_yaml" ui_build_id)"
        [[ -n "$UI_BUILD_ID" ]] || err "ui version $UI_VERSION matches prior stable but prior release $prior_release_dir has no ui_build_id (or legacy build_id) to reuse — use --from-release to pick a release that shipped a UI artifact."
        UI_ARTIFACT_FRESH=false
        info "Reusing prior UI_BUILD_ID (UI version unchanged: $UI_VERSION): $UI_BUILD_ID"
    else
        UI_BUILD_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
        if grep -rq "build_id: $UI_BUILD_ID" "$RELEASES_DIR"/*/release.yaml 2>/dev/null; then
            err "generated UI_BUILD_ID collides with an existing release ($UI_BUILD_ID) — rerun."
        fi
        UI_ARTIFACT_FRESH=true
    fi

    # --- create release directory ----------------------------------------------
    local DATE RELEASE_ID RELEASE_DIR
    DATE="$(date +%F)"
    RELEASE_ID="${DATE}_${SERVER_VERSION}-server_${UI_VERSION}-ui"
    RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"
    [[ ! -e "$RELEASE_DIR" ]] || err "release dir already exists (immutable — never edit a published release): $RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"

    local server_commit ui_commit server_branch ui_branch created_at
    server_commit="$(git -C "$SERVER_REPO" rev-parse --short HEAD)"
    ui_commit="$(git -C "$UI_REPO" rev-parse --short HEAD)"
    server_branch="$(git -C "$SERVER_REPO" rev-parse --abbrev-ref HEAD)"
    ui_branch="$(git -C "$UI_REPO" rev-parse --abbrev-ref HEAD)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    render "$SKILL_DIR/templates/release-yaml-template.yaml" "$RELEASE_DIR/release.yaml" \
        "RELEASE_ID=$RELEASE_ID" "DATE=$DATE" "CREATED_AT=$created_at" "CREATED_BY=pi-agent" \
        "SERVER_VERSION=$SERVER_VERSION" "UI_VERSION=$UI_VERSION" \
        "SERVER_BRANCH=$server_branch" "UI_BRANCH=$ui_branch" \
        "SERVER_COMMIT=$server_commit" "UI_COMMIT=$ui_commit" \
        "BUNDLE_BUILD_ID=$BUNDLE_BUILD_ID" "SERVER_BUILD_ID=$SERVER_BUILD_ID" "UI_BUILD_ID=$UI_BUILD_ID" \
        "SERVER_ARTIFACT_FRESH=$SERVER_ARTIFACT_FRESH" "UI_ARTIFACT_FRESH=$UI_ARTIFACT_FRESH"

    render "$SKILL_DIR/templates/rollback-md-template.md" "$RELEASE_DIR/rollback.md" \
        "RELEASE_ID=$RELEASE_ID" "BUNDLE_BUILD_ID=$BUNDLE_BUILD_ID" \
        "SERVER_VERSION=$SERVER_VERSION" "UI_VERSION=$UI_VERSION" \
        "PRIOR_SERVER_VERSION=$ps_ver" "PRIOR_UI_VERSION=$pu_ver" \
        "PRIOR_SERVER_REF=$ps_ref @ ${ps_commit:-?}" "PRIOR_UI_REF=$pu_ref @ ${pu_commit:-?}" \
        "PRIOR_BUILD_ID=$prior_build_id"

    render "$SKILL_DIR/templates/verification-md-template.md" "$RELEASE_DIR/verification.md" \
        "RELEASE_ID=$RELEASE_ID" "SERVER_VERSION=$SERVER_VERSION" "UI_VERSION=$UI_VERSION"

    cp "$SERVER_ZIP" "$UI_ZIP" "$RELEASE_DIR/"

    # Seed device scripts from fleet-gitops templates and render them for this release.
    # deploy-ntv-bundle.sh is always re-rendered (BUNDLE_BUILD_ID is always fresh).
    # update-*-server.sh / update-*-ui.sh: a component marked NOT fresh means its
    # artifact stays at the prior release's S3 prefix unchanged — its script must
    # therefore be byte-identical to what's already live there, so copy the prior
    # release's actual rendered file forward instead of re-deriving from today's
    # template. Re-rendering from the current template here was a real bug: a
    # template fix landed between releases produced a script that differed from
    # the untouched S3 object it was supposed to match, and publish's post-upload
    # checksum verification (correctly) refused to treat them as equivalent.
    local T="$GITOPS/player-apps/templates"
    [[ -f "$T/deploy-ntv-bundle.sh" ]] && cp "$T/deploy-ntv-bundle.sh" "$RELEASE_DIR/deploy-ntv-bundle.sh"

    if [[ "$SERVER_ARTIFACT_FRESH" == "true" ]]; then
        [[ -f "$T/update-server.sh" ]] && cp "$T/update-server.sh" "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh"
    else
        local prior_server_sh="$prior_release_dir/update-${SERVER_VERSION}-server.sh"
        [[ -f "$prior_server_sh" ]] || err "server marked unchanged but prior release $prior_release_dir has no update-${SERVER_VERSION}-server.sh to reuse."
        cp "$prior_server_sh" "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh"
    fi

    if [[ "$UI_ARTIFACT_FRESH" == "true" ]]; then
        [[ -f "$T/update-ui.sh" ]] && cp "$T/update-ui.sh" "$RELEASE_DIR/update-${UI_VERSION}-ui.sh"
    else
        local prior_ui_sh="$prior_release_dir/update-${UI_VERSION}-ui.sh"
        [[ -f "$prior_ui_sh" ]] || err "UI marked unchanged but prior release $prior_release_dir has no update-${UI_VERSION}-ui.sh to reuse."
        cp "$prior_ui_sh" "$RELEASE_DIR/update-${UI_VERSION}-ui.sh"
    fi

    [[ -f "$T/rollback-bundle.sh" ]] && cp "$T/rollback-bundle.sh" "$RELEASE_DIR/rollback-bundle.sh"

    local sh
    for sh in "$RELEASE_DIR"/*.sh; do
        [[ -f "$sh" ]] || continue
        # Remove TEMPLATE header
        sed -i '/^# TEMPLATE/d' "$sh"
    done

    # Substitute variables. deploy-ntv-bundle.sh carries all three build ids
    # (it builds S3 URLs for itself AND both component scripts); the two
    # component scripts each keep a single BUILD_ID const, fed their own
    # respective id (SERVER_BUILD_ID / UI_BUILD_ID) — no split needed within
    # a single-component script, only across the three files as a whole.
    [[ -f "$RELEASE_DIR/deploy-ntv-bundle.sh" ]] && sed -i -e "s/^readonly SERVER_VERSION=.*/readonly SERVER_VERSION=\"$SERVER_VERSION\"/" \
           -e "s/^readonly UI_VERSION=.*/readonly UI_VERSION=\"$UI_VERSION\"/" \
           -e "s/^readonly BUNDLE_BUILD_ID=.*/readonly BUNDLE_BUILD_ID=\"$BUNDLE_BUILD_ID\"/" \
           -e "s/^readonly SERVER_BUILD_ID=.*/readonly SERVER_BUILD_ID=\"$SERVER_BUILD_ID\"/" \
           -e "s/^readonly UI_BUILD_ID=.*/readonly UI_BUILD_ID=\"$UI_BUILD_ID\"/" \
           "$RELEASE_DIR/deploy-ntv-bundle.sh"

    if [[ "$SERVER_ARTIFACT_FRESH" == "true" && -f "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh" ]]; then
        sed -i -e "s/^readonly VERSION=.*/readonly VERSION=\"$SERVER_VERSION\"/" \
               -e "s/^readonly SERVER_VERSION=.*/readonly SERVER_VERSION=\"$SERVER_VERSION\"/" \
               -e "s/^readonly BUILD_ID=.*/readonly BUILD_ID=\"$SERVER_BUILD_ID\"/" \
               -e "s|/player-server-[0-9\.]*\.zip|/player-server-${SERVER_VERSION}.zip|" \
               "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh"
    fi

    # rollback-bundle.sh's actual variable names (SERVER_ROLLBACK_VERSION/
    # SERVER_FROM_VERSION/UI_ROLLBACK_VERSION/UI_FROM_VERSION/ROLLBACK_BUILD_ID/
    # *_ROLLBACK_ZIP_URL) differ from every other script's (VERSION/BUILD_ID) —
    # a prior version of this sed targeted the wrong names entirely and never
    # matched anything, silently carrying forward whatever an ancestor release
    # had. ROLLBACK_BUILD_ID is THIS release's own BUNDLE_BUILD_ID (used only
    # for rollback-bundle.sh's self-download on detach) — each component's
    # rollback zip uses its own prior build id, independent of that.
    if [[ -f "$RELEASE_DIR/rollback-bundle.sh" ]]; then
        local prior_server_build_id prior_ui_build_id
        prior_server_build_id="$(prior_component_build_id "$prior_yaml" server_build_id)"
        prior_ui_build_id="$(prior_component_build_id "$prior_yaml" ui_build_id)"
        [[ -n "$prior_server_build_id" ]] || err "rollback-bundle.sh: prior release $prior_release_dir has no server_build_id to build a rollback URL from."
        [[ -n "$prior_ui_build_id" ]] || err "rollback-bundle.sh: prior release $prior_release_dir has no ui_build_id to build a rollback URL from."
        sed -i -e "s/^readonly SERVER_ROLLBACK_VERSION=.*/readonly SERVER_ROLLBACK_VERSION=\"$ps_ver\"/" \
               -e "s/^readonly SERVER_FROM_VERSION=.*/readonly SERVER_FROM_VERSION=\"$SERVER_VERSION\"/" \
               -e "s/^readonly UI_ROLLBACK_VERSION=.*/readonly UI_ROLLBACK_VERSION=\"$pu_ver\"/" \
               -e "s/^readonly UI_FROM_VERSION=.*/readonly UI_FROM_VERSION=\"$UI_VERSION\"/" \
               -e "s/^readonly ROLLBACK_BUILD_ID=.*/readonly ROLLBACK_BUILD_ID=\"$BUNDLE_BUILD_ID\"/" \
               -e "s|^readonly SERVER_ROLLBACK_ZIP_URL=.*|readonly SERVER_ROLLBACK_ZIP_URL=\"https://ncompasstv-prod-player-apps.s3.amazonaws.com/secure-rc/${prior_server_build_id}/player-server-${ps_ver}.zip\"|" \
               -e "s|^readonly UI_ROLLBACK_ZIP_URL=.*|readonly UI_ROLLBACK_ZIP_URL=\"https://ncompasstv-prod-player-apps.s3.amazonaws.com/secure-rc/${prior_ui_build_id}/player-ui-${pu_ver}.zip\"|" \
               "$RELEASE_DIR/rollback-bundle.sh"
    fi

    if [[ "$UI_ARTIFACT_FRESH" == "true" && -f "$RELEASE_DIR/update-${UI_VERSION}-ui.sh" ]]; then
        sed -i -e "s/^readonly VERSION=.*/readonly VERSION=\"$UI_VERSION\"/" \
               -e "s/^readonly UI_VERSION=.*/readonly UI_VERSION=\"$UI_VERSION\"/" \
               -e "s/^readonly BUILD_ID=.*/readonly BUILD_ID=\"$UI_BUILD_ID\"/" \
               -e "s|/player-ui-[0-9\.]*\.zip|/player-ui-${UI_VERSION}.zip|" \
               "$RELEASE_DIR/update-${UI_VERSION}-ui.sh"
    fi

    info "Generating checksums..."
    bash "$SKILL_DIR/scripts/gen-checksums.sh" "$RELEASE_DIR"

    cat <<EOF

=== init complete ===
RELEASE_ID:       $RELEASE_ID
BUNDLE_BUILD_ID:  $BUNDLE_BUILD_ID   (always fresh)
SERVER_BUILD_ID:  $SERVER_BUILD_ID   (fresh=$SERVER_ARTIFACT_FRESH)
UI_BUILD_ID:      $UI_BUILD_ID   (fresh=$UI_ARTIFACT_FRESH)
Release dir:      $RELEASE_DIR
Fix branch:       ${FIX_BRANCH:-"(not recorded)"}
S3 targets (nothing uploaded yet):
  bundle: s3://$S3_BUCKET/secure-rc/$BUNDLE_BUILD_ID/
  server: s3://$S3_BUCKET/secure-rc/$SERVER_BUILD_ID/$( [[ "$SERVER_ARTIFACT_FRESH" == "false" ]] && echo "  (reused — already live, will not be re-uploaded)" )
  ui:     s3://$S3_BUCKET/secure-rc/$UI_BUILD_ID/$( [[ "$UI_ARTIFACT_FRESH" == "false" ]] && echo "  (reused — already live, will not be re-uploaded)" )

NEXT (before publish) — review generated scripts:
  1. deploy-ntv-bundle.sh
  2. update-${SERVER_VERSION}-server.sh
  3. update-${UI_VERSION}-ui.sh
  4. rollback-bundle.sh

Validate, review, and commit the non-ZIP release record (including checksums.sha256).

Then:  release.sh publish "$RELEASE_DIR"            (dry-run)
       release.sh publish "$RELEASE_DIR" --execute  (validate, upload, verify, and push)
EOF
}

# =============================================================================
# PUBLISH HELPERS — per-prefix immutability guard / reuse-presence check / upload
# =============================================================================

# Refuses to upload into a non-empty live prefix. Used for every prefix that's
# fresh this release (bundle always; server/ui when their id was freshly minted).
guard_prefix_empty() { # guard_prefix_empty <s3-dest-with-trailing-slash>
    local dest="$1"
    if aws s3 ls "$dest" 2>/dev/null | grep -q .; then
        err "S3 prefix $dest is NOT empty. Live build-id folders are immutable — a new fix means a new UUID. (Staged-never-fetched overwrite goes through 'init --build-id --confirm-staged-overwrite' with human sign-off, then delete the stale objects manually before publish.)"
    fi
}

# For a REUSED component (its id was carried forward from the prior release,
# nothing new to upload), verify the expected files are actually already live
# at that prefix — a reuse claim pointing at a dangling prefix would leave
# devices 404ing on that component.
verify_prefix_has() { # verify_prefix_has <s3-dest-with-trailing-slash> <file>...
    local dest="$1"; shift
    local listing; listing="$(aws s3 ls "$dest" 2>/dev/null || true)"
    local file
    for file in "$@"; do
        grep -q " ${file}\$" <<< "$listing" \
            || err "Reused prefix $dest is missing $file — this component was marked unchanged (*_artifact_fresh: false) but its prior artifact isn't actually there. Re-run init without --skip-*-build, or point --from-release at a release that actually shipped it."
    done
}

upload_group() { # upload_group <s3-dest-with-trailing-slash> <file>...
    local dest="$1" release_dir="$2"; shift 2
    local file
    for file in "$@"; do
        info "Uploading $file -> $dest"
        aws s3 cp "$release_dir/$file" "$dest$file" || err "upload failed: $file"
    done
}

# =============================================================================
# PUBLISH
# =============================================================================
cmd_publish() {
    local RELEASE_DIR="" EXECUTE=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --execute) EXECUTE=true; shift ;;
            --gitops)  GITOPS="${2:?}"; shift 2 ;;
            *) RELEASE_DIR="$1"; shift ;;
        esac
    done
    [[ -n "$RELEASE_DIR" && -d "$RELEASE_DIR" ]] || err "publish: release dir required and must exist"
    RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
    local RELEASE_ID; RELEASE_ID="$(basename "$RELEASE_DIR")"

    local RYAML="$RELEASE_DIR/release.yaml"
    local BUNDLE_BUILD_ID SERVER_BUILD_ID UI_BUILD_ID SERVER_FRESH UI_FRESH
    BUNDLE_BUILD_ID="$(get_s3_id "$RYAML" bundle_build_id)" || err "failed to parse s3.bundle_build_id"
    SERVER_BUILD_ID="$(get_s3_id "$RYAML" server_build_id)" || err "failed to parse s3.server_build_id"
    UI_BUILD_ID="$(get_s3_id "$RYAML" ui_build_id)" || err "failed to parse s3.ui_build_id"
    SERVER_FRESH="$(get_s3_bool "$RYAML" server_artifact_fresh)" || err "failed to parse s3.server_artifact_fresh"
    UI_FRESH="$(get_s3_bool "$RYAML" ui_artifact_fresh)" || err "failed to parse s3.ui_artifact_fresh"

    # 1. bash -n every script (also re-checked by the validator), each checked
    # against the build id its own S3 URLs should embed.
    local sh
    for sh in "$RELEASE_DIR"/*.sh; do
        [[ -f "$sh" ]] || continue
        bash -n "$sh" || err "bash -n failed: $sh"
        # scripts must actually be adapted — a stray TEMPLATE header means they weren't
        if head -3 "$sh" | grep -q '^# TEMPLATE'; then
            err "$(basename "$sh") still carries the TEMPLATE header — adapt it before publishing."
        fi
        case "$(basename "$sh")" in
            deploy-ntv-bundle.sh|rollback-bundle.sh)
                grep -q "$BUNDLE_BUILD_ID" "$sh" || info "WARN: $(basename "$sh") does not reference BUNDLE_BUILD_ID $BUNDLE_BUILD_ID — verify its S3 URLs."
                ;;
            update-*-server.sh)
                grep -q "$SERVER_BUILD_ID" "$sh" || info "WARN: $(basename "$sh") does not reference SERVER_BUILD_ID $SERVER_BUILD_ID — verify its S3 URLs."
                ;;
            update-*-ui.sh)
                grep -q "$UI_BUILD_ID" "$sh" || info "WARN: $(basename "$sh") does not reference UI_BUILD_ID $UI_BUILD_ID — verify its S3 URLs."
                ;;
        esac
    done

    # 2. verify checksums
    [[ -f "$RELEASE_DIR/checksums.sha256" ]] || err "checksums.sha256 missing — prepare phase must generate it"
    (cd "$RELEASE_DIR" && LC_ALL=C sha256sum --check --quiet checksums.sha256) || err "checksum verification failed"

    # Check git status for the release directory
    (
        cd "$GITOPS"
        local rel_path="player-apps/releases/$RELEASE_ID"
        local diff_out untracked_out tracked_zips
        diff_out="$(git diff --name-only HEAD -- "$rel_path" | grep -v '\.zip$' || true)"
        [[ -z "$diff_out" ]] || err "Modified or staged files in $rel_path: $diff_out"
        untracked_out="$(git ls-files --others --exclude-standard "$rel_path" | grep -v '\.zip$' || true)"
        [[ -z "$untracked_out" ]] || err "Unexpected untracked files in $rel_path (only .zip allowed): $untracked_out"
        tracked_zips="$(git ls-files "$rel_path" | grep '\.zip$' || true)"
        [[ -z "$tracked_zips" ]] || err "ZIPs must remain untracked: $tracked_zips"
    )

    # 3. local validation (files, checksums, yaml, bash -n)
    bash "$SKILL_DIR/scripts/validate-release.sh" "$RELEASE_DIR" --local-only --gitops "$GITOPS"

    # --- group checksummed local files by component -----------------------------
    # Local checksums.sha256 always covers every local file regardless of
    # freshness (it's the offline integrity record). Only FRESH components get
    # uploaded/checked against an empty prefix; a REUSED component's files stay
    # local-only (they're already live at the prior release's prefix) but are
    # still verified present there before publish completes.
    local -a ALL_FILES=()
    while IFS= read -r f; do ALL_FILES+=("$f"); done < <(awk '{print $2}' "$RELEASE_DIR/checksums.sha256")

    local -a BUNDLE_FILES=() SERVER_FILES=() UI_FILES=()
    local f
    for f in "${ALL_FILES[@]}"; do
        case "$f" in
            deploy-ntv-bundle.sh|rollback-bundle.sh) BUNDLE_FILES+=("$f") ;;
            update-*-server.sh|player-server-*.zip)  SERVER_FILES+=("$f") ;;
            update-*-ui.sh|player-ui-*.zip)          UI_FILES+=("$f") ;;
            *) err "unrecognized checksummed file — cannot classify by component: $f" ;;
        esac
    done
    # checksums.sha256 itself always ships alongside the (always-fresh) bundle.
    BUNDLE_FILES+=("checksums.sha256")

    local S3_BUNDLE_DEST="s3://$S3_BUCKET/secure-rc/$BUNDLE_BUILD_ID/"
    local S3_SERVER_DEST="s3://$S3_BUCKET/secure-rc/$SERVER_BUILD_ID/"
    local S3_UI_DEST="s3://$S3_BUCKET/secure-rc/$UI_BUILD_ID/"

    if [[ "$EXECUTE" == "false" ]]; then
        echo ""
        echo "=== DRY RUN — nothing uploaded, nothing pushed ==="
        echo "Bundle (always fresh) -> $S3_BUNDLE_DEST"
        printf '  %s\n' "${BUNDLE_FILES[@]}"
        if [[ "$SERVER_FRESH" == "true" ]]; then
            echo "Server (fresh this release) -> $S3_SERVER_DEST"
            printf '  %s\n' "${SERVER_FILES[@]}"
        else
            echo "Server (unchanged — REUSING prior prefix, would verify present, NOT re-uploaded) -> $S3_SERVER_DEST"
            printf '  %s\n' "${SERVER_FILES[@]}"
        fi
        if [[ "$UI_FRESH" == "true" ]]; then
            echo "UI (fresh this release) -> $S3_UI_DEST"
            printf '  %s\n' "${UI_FILES[@]}"
        else
            echo "UI (unchanged — REUSING prior prefix, would verify present, NOT re-uploaded) -> $S3_UI_DEST"
            printf '  %s\n' "${UI_FILES[@]}"
        fi
        echo "Would verify and push existing HEAD to fleet-gitops (origin + forgejo)."
        echo "Re-run with --execute to perform."
        return 0
    fi

    command -v aws >/dev/null 2>&1 || err "aws CLI not found."

    # 4. Immutability guard for fresh prefixes; presence check for reused ones.
    guard_prefix_empty "$S3_BUNDLE_DEST"
    if [[ "$SERVER_FRESH" == "true" ]]; then
        guard_prefix_empty "$S3_SERVER_DEST"
    else
        verify_prefix_has "$S3_SERVER_DEST" "${SERVER_FILES[@]}"
    fi
    if [[ "$UI_FRESH" == "true" ]]; then
        guard_prefix_empty "$S3_UI_DEST"
    else
        verify_prefix_has "$S3_UI_DEST" "${UI_FILES[@]}"
    fi

    # 5. Upload only what's fresh + verify round trip
    upload_group "$S3_BUNDLE_DEST" "$RELEASE_DIR" "${BUNDLE_FILES[@]}"
    [[ "$SERVER_FRESH" == "true" ]] && upload_group "$S3_SERVER_DEST" "$RELEASE_DIR" "${SERVER_FILES[@]}"
    [[ "$UI_FRESH"     == "true" ]] && upload_group "$S3_UI_DEST" "$RELEASE_DIR" "${UI_FILES[@]}"

    bash "$SKILL_DIR/scripts/validate-release.sh" "$RELEASE_DIR" --gitops "$GITOPS" \
        || err "post-upload validation failed."

    # 6. Push fleet-gitops to both remotes (no commit creation)
    (
        cd "$GITOPS"
        local remote
        for remote in origin forgejo; do
            if git remote get-url "$remote" >/dev/null 2>&1; then
                git push "$remote" HEAD
                git ls-remote "$remote" >/dev/null || err "git ls-remote $remote failed after push"
                info "Pushed to $remote."
            else
                info "WARN: remote '$remote' not configured in $GITOPS — skipped."
            fi
        done
    )

    cat <<EOF

=== publish complete ===
RELEASE_ID:      $RELEASE_ID
BUNDLE_BUILD_ID: $BUNDLE_BUILD_ID
SERVER_BUILD_ID: $SERVER_BUILD_ID   (fresh=$SERVER_FRESH)
UI_BUILD_ID:     $UI_BUILD_ID   (fresh=$UI_FRESH)
S3 bundle:       $S3_BUNDLE_DEST
S3 server:       $S3_SERVER_DEST$( [[ "$SERVER_FRESH" == "false" ]] && echo "  (reused, not re-uploaded)" )
S3 ui:           $S3_UI_DEST$( [[ "$UI_FRESH" == "false" ]] && echo "  (reused, not re-uploaded)" )
Record:          $RELEASE_DIR/release.yaml
Checksums:       $RELEASE_DIR/checksums.sha256
Evidence:        /tmp/validate-$BUNDLE_BUILD_ID.log
Next: ritual step 9 (review), then deploy to test device before any fleet rollout.
EOF
}

# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        init)    shift; cmd_init "$@" ;;
        publish) shift; cmd_publish "$@" ;;
        *) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,40p'; exit 1 ;;
    esac
fi
