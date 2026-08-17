#!/usr/bin/env bash
# =============================================================================
# release.sh — ntv-release orchestrator (ritual steps 4–7)
# =============================================================================
# Two phases, because device update scripts must be hand-adapted between
# BUILD_ID generation and upload (they embed the BUILD_ID in their S3 URLs):
#
#   release.sh init    --server-version X.Y.Z --ui-version A.B.C [options]
#       Preflight, prod builds, fresh UUID BUILD_ID, prior-stable detection,
#       creates the fleet-gitops release directory with release.yaml,
#       rollback.md, verification.md, copies zips + script templates in.
#
#   (agent/human adapts deploy-ntv-bundle.sh, update-*.sh, rollback-bundle.sh
#    in the release dir — embed BUILD_ID, versions, per deploy-script-standard)
#
#   release.sh publish <release-dir> [--execute]
#       bash -n all scripts, gen checksums, local validation, S3 upload
#       (immutability-guarded), S3 verify, git commit + push to both remotes.
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
#   --skip-ui-build            reuse existing builds/player-ui-A.B.C.zip
#                              (server-only patch: UI zip from prior release)
#   --prior-server REF         override prior-stable server tag/version
#   --prior-ui REF             override prior-stable UI tag/version
#   --from-release RELEASE_ID  override auto-detected prior release directory
#                              (bypasses lifecycle-status auto-detection entirely;
#                              RELEASE_ID is a dir name under player-apps/releases)
#   --build-id UUID            REUSE an existing BUILD_ID. Only legal for the
#                              staged-never-fetched overwrite exception; needs
#                              --confirm-staged-overwrite AND an interactive
#                              typed confirmation. Never use this without
#                              explicit human sign-off.
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

get_build_id() {
    local yaml_file="$1"
    local build_ids num_matches build_id
    build_ids=$(awk '
      /^s3:[ \t]*(#.*)?$/ { in_s3 = 1; next }
      /^[a-zA-Z0-9_-]+:/ { in_s3 = 0 }
      in_s3 && /^[ \t]+build_id:[ \t]+/ {
        val = $0
        sub(/^[ \t]+build_id:[ \t]+/, "", val)
        sub(/[ \t]*(#.*)?$/, "", val)
        gsub(/^"|"$|^'\''|'\''$/, "", val)
        if (val != "") print val
      }
    ' "$yaml_file")
    num_matches=$(echo "$build_ids" | awk 'NF' | wc -l | tr -d ' ')
    if [[ "$num_matches" -eq 0 ]]; then
        echo "ERROR: missing s3.build_id in $yaml_file" >&2
        exit 1
    elif [[ "$num_matches" -gt 1 ]]; then
        echo "ERROR: duplicate s3.build_id in $yaml_file" >&2
        exit 1
    fi
    build_id=$(echo "$build_ids" | awk 'NF')
    if ! [[ "$build_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        echo "ERROR: malformed s3.build_id in $yaml_file: $build_id" >&2
        exit 1
    fi
    echo "$build_id"
}

# --- prior-stable detection --------------------------------------------------
# Source of truth: latest ANNOTATED v* tag (objecttype "tag"), sort -V.
# Bare vX.Y.Z tags are preferred; suffixed tags (v2.9.44-rc.0, v3.0.45-HLZHSVWV)
# are pre-release/variant and only used if no bare tag exists.
# Documented fallback: newest `chore(release): bump version to X.Y.Z` commit
# on the default branch (version bumps that never shipped may pollute this —
# always eyeball the result). Override with --prior-server / --prior-ui.
prior_stable() { # prior_stable <repo-path>  -> "ref version commit"
    local repo="$1" tag ver commit annotated
    annotated="$(git -C "$repo" for-each-ref 'refs/tags/v[0-9]*' \
            --format='%(objecttype) %(refname:short)' 2>/dev/null \
          | awk '$1=="tag"{print $2}')"
    tag="$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<< "$annotated" | sort -V | tail -1)"
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
    local BUILD_ID="" CONFIRM_OVERWRITE=false

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
            --build-id)       BUILD_ID="${2:?}"; shift 2 ;;
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

    # --- BUILD_ID: fresh UUID; reuse only via the guarded staged-overwrite path
    if [[ -n "$BUILD_ID" ]]; then
        [[ "$CONFIRM_OVERWRITE" == "true" ]] || err "--build-id reuse requires --confirm-staged-overwrite. HARD RULE: live BUILD_ID folders are immutable. Reuse is legal ONLY for a staged release no device has ever fetched — a human must verify deployment-manifest.json on all devices and explicitly approve."
        echo ""
        echo "!!! STAGED-OVERWRITE EXCEPTION REQUESTED for BUILD_ID $BUILD_ID"
        echo "!!! Preconditions the HUMAN must have verified (this script cannot):"
        echo "!!!   - release status is 'staged' in its release.yaml"
        echo "!!!   - NO device has fetched it (deployment-manifest.json on all devices)"
        echo "!!!   - explicit human approval was given"
        [[ -t 0 ]] || err "staged-overwrite confirmation must be typed interactively by a human (stdin is not a TTY). The skill never decides this alone."
        read -r -p "Type OVERWRITE-STAGED to proceed: " reply
        [[ "$reply" == "OVERWRITE-STAGED" ]] || err "confirmation not given — aborting."
    else
        BUILD_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
        # Never reuse: refuse any UUID already recorded in fleet-gitops releases.
        if grep -rq "build_id: $BUILD_ID" "$RELEASES_DIR"/*/release.yaml 2>/dev/null; then
            err "generated BUILD_ID collides with an existing release ($BUILD_ID) — rerun."
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
    read -r ps_ref ps_ver ps_commit <<< "$(prior_stable "$SERVER_REPO")"
    read -r pu_ref pu_ver pu_commit <<< "$(prior_stable "$UI_REPO")"
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

    local prior_build_id="unknown" prior_yaml="$prior_release_dir/release.yaml"
    [[ -f "$prior_yaml" ]] && prior_build_id="$(grep -E '^\s*build_id:' "$prior_yaml" | head -1 | awk '{print $2}')"

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
        "BUILD_ID=$BUILD_ID"

    render "$SKILL_DIR/templates/rollback-md-template.md" "$RELEASE_DIR/rollback.md" \
        "RELEASE_ID=$RELEASE_ID" "BUILD_ID=$BUILD_ID" \
        "SERVER_VERSION=$SERVER_VERSION" "UI_VERSION=$UI_VERSION" \
        "PRIOR_SERVER_VERSION=$ps_ver" "PRIOR_UI_VERSION=$pu_ver" \
        "PRIOR_SERVER_REF=$ps_ref @ ${ps_commit:-?}" "PRIOR_UI_REF=$pu_ref @ ${pu_commit:-?}" \
        "PRIOR_BUILD_ID=$prior_build_id"

    render "$SKILL_DIR/templates/verification-md-template.md" "$RELEASE_DIR/verification.md" \
        "RELEASE_ID=$RELEASE_ID" "SERVER_VERSION=$SERVER_VERSION" "UI_VERSION=$UI_VERSION"

    cp "$SERVER_ZIP" "$UI_ZIP" "$RELEASE_DIR/"

    # Seed device scripts from fleet-gitops templates and render them for this release.
    local T="$GITOPS/player-apps/templates"
    [[ -f "$T/deploy-ntv-bundle.sh" ]] && cp "$T/deploy-ntv-bundle.sh" "$RELEASE_DIR/deploy-ntv-bundle.sh"
    [[ -f "$T/update-server.sh"     ]] && cp "$T/update-server.sh"     "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh"
    [[ -f "$T/update-ui.sh"         ]] && cp "$T/update-ui.sh"         "$RELEASE_DIR/update-${UI_VERSION}-ui.sh"
    # rollback-bundle.sh has no template; copy from the prior release dir as a base
    # (same prior_release_dir selected above — non-retired, newest by date).
    local prior_rb="$prior_release_dir/rollback-bundle.sh"
    [[ -f "$prior_rb" ]] && cp "$prior_rb" "$RELEASE_DIR/rollback-bundle.sh"

    local sh
    for sh in "$RELEASE_DIR"/*.sh; do
        [[ -f "$sh" ]] || continue
        # Remove TEMPLATE header
        sed -i '/^# TEMPLATE/d' "$sh"
    done

    # Substitute variables
    [[ -f "$RELEASE_DIR/deploy-ntv-bundle.sh" ]] && sed -i -e "s/^readonly SERVER_VERSION=.*/readonly SERVER_VERSION=\"$SERVER_VERSION\"/" \
           -e "s/^readonly UI_VERSION=.*/readonly UI_VERSION=\"$UI_VERSION\"/" \
           -e "s/^readonly BUILD_ID=.*/readonly BUILD_ID=\"$BUILD_ID\"/" \
           "$RELEASE_DIR/deploy-ntv-bundle.sh"

    [[ -f "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh" ]] && sed -i -e "s/^readonly VERSION=.*/readonly VERSION=\"$SERVER_VERSION\"/" \
           -e "s/^readonly SERVER_VERSION=.*/readonly SERVER_VERSION=\"$SERVER_VERSION\"/" \
           -e "s/^readonly BUILD_ID=.*/readonly BUILD_ID=\"$BUILD_ID\"/" \
           -e "s|/player-server-[0-9\.]*\.zip|/player-server-${SERVER_VERSION}.zip|" \
           "$RELEASE_DIR/update-${SERVER_VERSION}-server.sh"

    [[ -f "$RELEASE_DIR/update-${UI_VERSION}-ui.sh" ]] && sed -i -e "s/^readonly VERSION=.*/readonly VERSION=\"$UI_VERSION\"/" \
           -e "s/^readonly UI_VERSION=.*/readonly UI_VERSION=\"$UI_VERSION\"/" \
           -e "s/^readonly BUILD_ID=.*/readonly BUILD_ID=\"$BUILD_ID\"/" \
           -e "s|/player-ui-[0-9\.]*\.zip|/player-ui-${UI_VERSION}.zip|" \
           "$RELEASE_DIR/update-${UI_VERSION}-ui.sh"

    [[ -f "$RELEASE_DIR/rollback-bundle.sh" ]] && sed -i -e "s/^readonly SERVER_VERSION=.*/readonly SERVER_VERSION=\"$ps_ver\"/" \
           -e "s/^readonly UI_VERSION=.*/readonly UI_VERSION=\"$pu_ver\"/" \
           -e "s/^readonly BUILD_ID=.*/readonly BUILD_ID=\"$prior_build_id\"/" \
           "$RELEASE_DIR/rollback-bundle.sh"

    info "Generating checksums..."
    bash "$SKILL_DIR/scripts/gen-checksums.sh" "$RELEASE_DIR"

    cat <<EOF

=== init complete ===
RELEASE_ID:  $RELEASE_ID
BUILD_ID:    $BUILD_ID
Release dir: $RELEASE_DIR
Fix branch:  ${FIX_BRANCH:-"(not recorded)"}
S3 target:   s3://$S3_BUCKET/secure-rc/$BUILD_ID/   (nothing uploaded yet)

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

    local BUILD_ID
    BUILD_ID="$(get_build_id "$RELEASE_DIR/release.yaml")" || err "failed to parse s3.build_id"

    # 1. bash -n every script (also re-checked by the validator)
    local sh
    for sh in "$RELEASE_DIR"/*.sh; do
        [[ -f "$sh" ]] || continue
        bash -n "$sh" || err "bash -n failed: $sh"
        # scripts must actually be adapted — a stray TEMPLATE header means they weren't
        if head -3 "$sh" | grep -q '^# TEMPLATE'; then
            err "$(basename "$sh") still carries the TEMPLATE header — adapt it before publishing."
        fi
        grep -q "$BUILD_ID" "$sh" || info "WARN: $(basename "$sh") does not reference BUILD_ID $BUILD_ID — verify its S3 URLs."
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

    # Upload set: everything checksummed + checksums.sha256
    local -a FILES=()
    while IFS= read -r f; do FILES+=("$f"); done < <(awk '{print $2}' "$RELEASE_DIR/checksums.sha256")
    FILES+=("checksums.sha256")
    local S3_DEST="s3://$S3_BUCKET/secure-rc/$BUILD_ID/"

    if [[ "$EXECUTE" == "false" ]]; then
        echo ""
        echo "=== DRY RUN — nothing uploaded, nothing pushed ==="
        echo "Would upload to $S3_DEST:"
        printf '  %s\n' "${FILES[@]}"
        echo "Would verify and push existing HEAD to fleet-gitops (origin + forgejo)."
        echo "Re-run with --execute to perform."
        return 0
    fi

    command -v aws >/dev/null 2>&1 || err "aws CLI not found."

    # 4. Immutability guard: refuse upload into a non-empty live prefix.
    if aws s3 ls "$S3_DEST" 2>/dev/null | grep -q .; then
        err "S3 prefix $S3_DEST is NOT empty. Live BUILD_ID folders are immutable — a new fix means a new UUID. (Staged-never-fetched overwrite goes through 'init --build-id --confirm-staged-overwrite' with human sign-off, then delete the stale objects manually before publish.)"
    fi

    # 5. Upload + verify round trip
    local f
    for f in "${FILES[@]}"; do
        info "Uploading $f"
        aws s3 cp "$RELEASE_DIR/$f" "$S3_DEST$f" || err "upload failed: $f"
    done
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
RELEASE_ID: $RELEASE_ID
BUILD_ID:   $BUILD_ID
S3:         $S3_DEST
Record:     $RELEASE_DIR/release.yaml
Checksums:  $RELEASE_DIR/checksums.sha256
Evidence:   /tmp/validate-$BUILD_ID.log
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
