# Pre-Merge QA Local Preparation Procedure

## Purpose

Validate fix/feature branches on a test device **before** merging into `next`, using temporary `/tmp` artifacts and LAN-served scripts. This gate prevents defects from entering the integration branch and immutable S3 artifacts.

## Hard Boundaries

- **No BUILD_ID allocation** — QA candidates use ephemeral identifiers only
- **No S3 access** — no reads, no writes during QA preparation
- **No merge** — validation occurs on the unmerged fix branch
- **No device state mutations** — preparation is host-only; device operations are manual
- **No git operations** — no commits, no pushes, no tag creation
- **Temporary artifacts only** — all QA files live under `/tmp/ntv-qa-<IDENTIFIER>/`

## Inputs Required

| Input | Source | Notes |
|-------|--------|-------|
| Fix branch worktree path | e.g., `.worktrees/fix/PV1-5-2.10.2-simple-delivery` | Must be clean |
| Branch HEAD commit | e.g., `68e433ec` | For verification and candidate ID |
| Branch build ZIP | `builds/player-server-X.Y.Z.zip` | Must exist. No fixed size floor — confirm against the most recent real published release's ZIP size instead of a hardcoded byte count, since the build shape has changed over time (e.g. `node_modules` no longer ships in the ZIP as of the PV1-25 hardening; recent ZIPs run ~160-170KB, not >1MB) |
| Reviewed release scripts | `fleet-gitops/player-apps/releases/<most-recent-by-date>/` | Use the latest *actually published* release, not a literal `*-rev2` glob — no recent release uses that suffix, so the glob silently returns a stale script |
| Host IP/port | e.g., `192.168.1.120:8765` | LAN-reachable from QA device |
| QA device address | e.g., `192.168.1.68` | For manual deployment |

## Preparation Steps

### 1. Validate Branch State

```bash
# Verify exact HEAD (prevents wrong-commit deployment)
cd /data/dev/work/ntv/player-server/.worktrees/fix/<branch-name>
EXPECTED_HEAD="68e433ec888b052a0b56e89f2c6b253af2ae9590"
ACTUAL_HEAD=$(git rev-parse HEAD)
[[ "$ACTUAL_HEAD" == "$EXPECTED_HEAD" ]] || { echo "HEAD mismatch"; exit 1; }

# Verify clean worktree (no uncommitted changes)
git status --porcelain | grep -q . && { echo "Dirty worktree"; exit 1; }

# Verify committed package, lockfile, and changelog metadata against next
~/.pi/agent/skills/ntv-release/scripts/validate-release-metadata.sh \
    "$PWD" "2.10.5-rc.1" "origin/next"
```

### 2. Validate Branch ZIP

```bash
# Verify ZIP structure, integrity, version, and build-info
ZIP_PATH="builds/player-server-2.10.2.zip"
unzip -t "$ZIP_PATH" || { echo "ZIP corrupt"; exit 1; }

# No fixed size floor -- compare against the most recent real published
# release's ZIP instead (build shape has changed over time; do not assume
# >1MB, that predates the PV1-25 node_modules-restore hardening)
LATEST_PUBLISHED=$(ls -1td /data/dev/work/ntv/fleet-gitops/player-apps/releases/*/player-server-*.zip | head -1)
REFERENCE_SIZE=$(stat -c%s "$LATEST_PUBLISHED")
THIS_SIZE=$(stat -c%s "$ZIP_PATH")
echo "this ZIP: $THIS_SIZE bytes; latest published ($LATEST_PUBLISHED): $REFERENCE_SIZE bytes"
# Sanity-check same order of magnitude rather than a hardcoded threshold:
[[ "$THIS_SIZE" -gt $((REFERENCE_SIZE / 4)) ]] || { echo "ZIP suspiciously small vs. latest published release"; exit 1; }

# Extract and check package version
unzip -q "$ZIP_PATH" -d /tmp/qa-check
PACKAGE_VERSION=$(jq -r .version /tmp/qa-check/player-server-*/package.json)
[[ "$PACKAGE_VERSION" == "2.10.2" ]] || { echo "Version mismatch"; exit 1; }

# Verify build-info commit
BUILD_INFO=$(cat /tmp/qa-check/player-server-*/build-info.txt)
echo "$BUILD_INFO" | grep -q "68e433e" || { echo "Build-info commit mismatch"; exit 1; }
rm -rf /tmp/qa-check
```

### 3. Assemble Candidate Directory

`.worktrees/next/src/public` is a gitignored runtime directory, not a
production-provenance asset set — it is typically empty in a fresh checkout,
and neither `deploy-ntv-bundle.sh` nor any `update-*-server.sh`/`update-*-ui.sh`
in the actual published releases reference it. There is nothing to rebuild
into the ZIP; the branch ZIP from step 2 is the final artifact as-is. If a
future release genuinely reintroduces a public-assets step, verify it against
the real release scripts (`grep -rn "src/public" <script>`) before trusting
any fixed file count.

```bash
CANDIDATE_ID="qa-local-68e433e"
CANDIDATE_DIR="/tmp/ntv-qa-$CANDIDATE_ID"
mkdir -p "$CANDIDATE_DIR/artifacts"

cp "$ZIP_PATH" "$CANDIDATE_DIR/artifacts/"
```

### 4. Validate Candidate ZIP

```bash
unzip -t "$CANDIDATE_DIR/artifacts/player-server-2.10.2.zip" || { echo "ZIP corrupt"; exit 1; }
```

### 5. Copy and Adapt Reviewed Release Scripts

**Source authority:** use the latest *actually published* release directory
(most recent `player-apps/releases/*` by date, verified device-deployed), not
a literal `ls *-rev2` glob — no recent release uses that suffix, so that glob
silently returns a stale, possibly months-old script. Read the candidate
script's own header comments to confirm which hardening revision it is before
trusting it as "latest reviewed."

**Placement is not uniform — deploy-ntv-bundle.sh and the component update
scripts live in different S3 prefixes in production, so they need different
local paths, or the device 404s on the second fetch:**

- `deploy-ntv-bundle.sh` → **candidate root**. Its own `S3_BASE` var points here
  (used by the self-detach re-exec, which re-fetches this exact file mid-run).
- `update-<version>-server.sh` / `update-<version>-ui.sh` → **`artifacts/`**,
  alongside the ZIP. `deploy-ntv-bundle.sh` fetches each component script from
  `S3_SERVER_BASE`/`S3_UI_BASE` — the *same* prefix as that component's ZIP,
  not its own directory. Confirm with
  `grep -n 'wget.*update-\${SERVER_VERSION}-server.sh' deploy-ntv-bundle.sh`
  before assuming otherwise — production S3 keeps a component's ZIP and update
  script together under one `secure-rc/<BUILD_ID>/` prefix.

```bash
SCRIPT_SOURCE=$(ls -1td /data/dev/work/ntv/fleet-gitops/player-apps/releases/* | head -1)

cp "$SCRIPT_SOURCE/deploy-ntv-bundle.sh" "$CANDIDATE_DIR/"
cp "$SCRIPT_SOURCE/update-2.10.2-server.sh" "$CANDIDATE_DIR/artifacts/"
cp "$SCRIPT_SOURCE/update-3.0.50-ui.sh" "$CANDIDATE_DIR/artifacts/"

# deploy-ntv-bundle.sh has THREE distinct S3 base vars, mapped to two
# different LAN locations — do not blanket sed-replace all of them the same
# way, or self-detach breaks:
sed -i "s|readonly BUNDLE_BUILD_ID=\"[^\"]*\"|readonly BUNDLE_BUILD_ID=\"$CANDIDATE_ID\"|" "$CANDIDATE_DIR/deploy-ntv-bundle.sh"
sed -i "s|readonly SERVER_BUILD_ID=\"[^\"]*\"|readonly SERVER_BUILD_ID=\"$CANDIDATE_ID\"|" "$CANDIDATE_DIR/deploy-ntv-bundle.sh"
sed -i "s|readonly S3_BASE=\"https://[^\"]*\"|readonly S3_BASE=\"http://192.168.1.120:8765\"|" "$CANDIDATE_DIR/deploy-ntv-bundle.sh"
sed -i "s|readonly S3_SERVER_BASE=\"https://[^\"]*\"|readonly S3_SERVER_BASE=\"http://192.168.1.120:8765/artifacts\"|" "$CANDIDATE_DIR/deploy-ntv-bundle.sh"
sed -i "s|readonly S3_UI_BASE=\"https://[^\"]*\"|readonly S3_UI_BASE=\"http://192.168.1.120:8765/artifacts\"|" "$CANDIDATE_DIR/deploy-ntv-bundle.sh"

# Component scripts each have exactly one S3_ARTIFACT_URL — blanket-replace is
# safe here, since there's only the one destination (artifacts/, where the
# script itself now also lives):
for script in "$CANDIDATE_DIR"/artifacts/*.sh; do
    sed -i "s/readonly BUILD_ID=\"[^\"]*\"/readonly BUILD_ID=\"$CANDIDATE_ID\"/" "$script"
    sed -i "s|https://ncompasstv-prod-player-apps.s3.amazonaws.com/secure-rc/[^/]*/|http://192.168.1.120:8765/artifacts/|g" "$script"
done

# Verify no S3 URLs remain anywhere
grep -rq "s3.amazonaws.com" "$CANDIDATE_DIR"/*.sh "$CANDIDATE_DIR"/artifacts/*.sh \
    && { echo "S3 URL still present"; exit 1; }
```

### 6. Validate Candidate Scripts

```bash
# Syntax check all scripts (root AND artifacts/ — component update scripts
# live in artifacts/, not root; see step 5)
for script in "$CANDIDATE_DIR"/*.sh "$CANDIDATE_DIR"/artifacts/*.sh; do
    bash -n "$script" || { echo "Syntax error in $script"; exit 1; }
done

# Verify bundle still contains critical features
grep -q "lxterminal\|xterm" "$CANDIDATE_DIR/deploy-ntv-bundle.sh" || \
    { echo "Bundle missing terminal fallback"; exit 1; }

grep -q "idempotent\|already installed" "$CANDIDATE_DIR/deploy-ntv-bundle.sh" || \
    { echo "Bundle missing idempotency check"; exit 1; }
```

### 7. Start HTTP Server

```bash
# Check port availability
lsof -i :8765 && { echo "Port 8765 already occupied"; exit 1; }

# Start detached Python HTTP server
cd "$CANDIDATE_DIR"
nohup python3 -m http.server --bind 192.168.1.120 8765 \
    > http.log 2>&1 &
echo $! > http.pid

# Wait for server to start
sleep 2

# Verify PID is alive
PID=$(cat http.pid)
kill -0 "$PID" || { echo "HTTP server failed to start"; exit 1; }
```

### 8. Generate Manifest and Verify Endpoints

```bash
# Calculate artifact hashes
ZIP_SHA256=$(sha256sum "$CANDIDATE_DIR/artifacts/player-server-2.10.2.zip" | awk '{print $1}')
BUNDLE_SHA256=$(sha256sum "$CANDIDATE_DIR/deploy-ntv-bundle.sh" | awk '{print $1}')
SERVER_SHA256=$(sha256sum "$CANDIDATE_DIR/artifacts/update-2.10.2-server.sh" | awk '{print $1}')
UI_SHA256=$(sha256sum "$CANDIDATE_DIR/artifacts/update-3.0.50-ui.sh" | awk '{print $1}')

# Generate manifest
cat > "$CANDIDATE_DIR/manifest.txt" <<EOF
NTV Pre-Merge QA Candidate Manifest
====================================

Candidate ID: $CANDIDATE_ID
Source Branch: fix/PV1-5-2.10.2-simple-delivery
Source Commit: 68e433ec888b052a0b56e89f2c6b253af2ae9590
Build Version: 2.10.2

Artifacts:
  player-server-2.10.2.zip
    Size: $ZIP_SIZE bytes
    SHA-256: $ZIP_SHA256

Scripts (adapted from: $SCRIPT_SOURCE):
  deploy-ntv-bundle.sh (SHA-256: $BUNDLE_SHA256)
  update-2.10.2-server.sh (SHA-256: $SERVER_SHA256)
  update-3.0.50-ui.sh (SHA-256: $UI_SHA256)

HTTP Server:
  URL: http://192.168.1.120:8765
  PID: $PID
  Log: $CANDIDATE_DIR/http.log

Device Deployment Command:
  wget -qO- http://192.168.1.120:8765/deploy-ntv-bundle.sh | bash -s -- --server-only

Cleanup Command:
  kill \$(cat $CANDIDATE_DIR/http.pid) && rm -rf $CANDIDATE_DIR
EOF

# Verify HTTP endpoints locally
curl -I http://192.168.1.120:8765/artifacts/player-server-2.10.2.zip | grep -q "200 OK" || \
    { echo "ZIP endpoint failed"; exit 1; }
curl -I http://192.168.1.120:8765/deploy-ntv-bundle.sh | grep -q "200 OK" || \
    { echo "Bundle script endpoint failed"; exit 1; }
```

## QA Device Verification Checklist

### First-Run Evidence (Deploy and Verify)

Execute the deployment command on the QA device, then collect this evidence:

#### Deployment Success Indicators

- [ ] **Build-info commit matches**: `cat /opt/ncompasstv/player-server/build-info.txt | grep 68e433e`
- [ ] **Package version matches**: `jq -r .version /opt/ncompasstv/player-server/package.json` → `2.10.2`
- [ ] **SQLite schema complete**: Compare actual SQLite tables to `createDbTableScripts` expected table inventory
- [ ] **Startup send evidence**: `journalctl -u player-server -n 100 | grep "startup send"` found
- [ ] **PM2 stable (5 min)**: `pm2 status player-server` shows `online` with restart count not increasing over 5-minute observation
- [ ] **API ping responds**: `curl -s http://localhost:3000/api/health | grep -q OK`
- [ ] **Crontab total correct**: `crontab -l | wc -l` → `5` entries (deployment restores baseline, does not add entries)
- [ ] **Deployment manifest written**: `test -f /opt/ncompasstv/player-server/deployment-manifest.json`
- [ ] **lxterminal visible**: Operator physically verifies player UI rendering on device display

#### Evidence Collection Commands

```bash
# SSH to QA device and run:
ssh pi@192.168.1.68 << 'EOF'
  echo "=== Build Info ==="
  cat /opt/ncompasstv/player-server/build-info.txt
  
  echo -e "\n=== Package Version ==="
  jq -r .version /opt/ncompasstv/player-server/package.json
  
  echo -e "\n=== SQLite Schema Tables ==="
  sqlite3 /opt/ncompasstv/player-server/db/player.db ".tables"
  
  echo -e "\n=== Expected Table Inventory (from createDbTableScripts) ==="
  # Compare actual tables against expected schema definition
  
  echo -e "\n=== Startup Send Evidence ==="
  journalctl -u player-server --since "5 minutes ago" | grep "startup send"
  
  echo -e "\n=== PM2 Status ==="
  pm2 status player-server
  
  echo -e "\n=== API Health ==="
  curl -s http://localhost:3000/api/health
  
  echo -e "\n=== Crontab Total Count ==="
  crontab -l | wc -l
  echo "(Expected: 5 entries total)"
  
  echo -e "\n=== Deployment Manifest ==="
  cat /opt/ncompasstv/player-server/deployment-manifest.json | jq .
EOF
```

### Second-Run Evidence (Idempotency Proof)

Re-run the same deployment command, then verify **no mutations** occurred:

- [ ] **Script exit code 0**: Deployment script completes successfully with already-target log message
- [ ] **No application file changes**: `find /opt/ncompasstv/player-server -type f -mmin -5 | wc -l` → `0` (or only logs/deployment-manifest)
- [ ] **No database schema changes**: Table inventory unchanged
- [ ] **PM2 restart count unchanged**: `pm2 status player-server` restart count not increased
- [ ] **Crontab unchanged**: Total entry count still `5`, content identical
- [ ] **Deployment manifest**: May be refreshed with updated metadata; hash change is acceptable

#### Evidence Collection Commands

```bash
# Before second run, capture baseline
ssh pi@192.168.1.68 << 'EOF'
  pm2 status player-server | tee /tmp/pm2-before.txt
  crontab -l > /tmp/crontab-before.txt
  crontab -l | wc -l > /tmp/crontab-count-before.txt
  sqlite3 /opt/ncompasstv/player-server/db/player.db ".tables" > /tmp/schema-tables-before.txt
EOF

# Run second deployment (execute as user pi on the device)
wget -qO- http://192.168.1.120:8765/deploy-ntv-bundle.sh | bash -s -- --server-only

# After second run, compare
ssh pi@192.168.1.68 << 'EOF'
  echo "=== PM2 Restart Count (should be unchanged) ==="
  pm2 status player-server | tee /tmp/pm2-after.txt
  diff /tmp/pm2-before.txt /tmp/pm2-after.txt
  
  echo -e "\n=== Crontab Diff (should be empty) ==="
  crontab -l > /tmp/crontab-after.txt
  diff /tmp/crontab-before.txt /tmp/crontab-after.txt
  
  echo -e "\n=== Crontab Count (should be 5) ==="
  crontab -l | wc -l > /tmp/crontab-count-after.txt
  diff /tmp/crontab-count-before.txt /tmp/crontab-count-after.txt
  
  echo -e "\n=== Schema Tables (should be unchanged) ==="
  sqlite3 /opt/ncompasstv/player-server/db/player.db ".tables" > /tmp/schema-tables-after.txt
  diff /tmp/schema-tables-before.txt /tmp/schema-tables-after.txt
  
  echo -e "\n=== Deployment Manifest (may be refreshed with updated metadata) ==="
  cat /opt/ncompasstv/player-server/deployment-manifest.json | jq .
  
  echo -e "\n=== Recent File Changes (should be 0 or only logs) ==="
  find /opt/ncompasstv/player-server -type f -mmin -5 -ls
EOF
```

## Review Gate

After collecting both first-run and second-run evidence, dispatch the reviewer:

```bash
# Reviewer must receive ALL contracts and artifacts:
pi dispatch reviewer \
  --contract ~/.agents/standards/code-style.md \
  --contract /data/dev/work/ntv/player-scripts/PRODUCTION_READY_MANIFEST.md \
  --artifact <branch-diff> \
  --artifact $CANDIDATE_DIR/manifest.txt \
  --artifact <first-run-evidence.txt> \
  --artifact <second-run-evidence.txt>
```

**Reviewer acceptance criteria:**
- Branch diff has reasonable scope (no unrelated changes)
- Candidate manifest complete (all hashes, source commit, script source)
- First-run evidence shows all 9 deployment indicators PASS
- Second-run evidence shows all 6 idempotency checks PASS
- No violations of code-style.md or PRODUCTION_READY_MANIFEST.md

**Required verdict:** `Verdict: PASS` before merge is authorized.

## Cleanup Procedure

After successful QA and merge, clean up temporary artifacts:

```bash
# Stop HTTP server
kill $(cat /tmp/ntv-qa-<IDENTIFIER>/http.pid)

# Remove candidate directory
rm -rf /tmp/ntv-qa-<IDENTIFIER>

# Verify cleanup
lsof -i :8765  # Should show no process
ls /tmp/ntv-qa-* # Should show no directories
```

## Important Notes

### Script Source Authority

- **Use the latest actually published release**: `ls -1td fleet-gitops/player-apps/releases/*/ | head -1`.
  A literal `*-rev2` glob is stale — no recent release uses that suffix, so it
  silently returns a months-old script instead of erroring.
- Never use generic templates — templates lack the battle-tested installer logic
- Component update scripts (`update-*-server.sh`/`update-*-ui.sh`) go in
  `artifacts/` alongside their ZIP, not candidate root — see step 5's S3-base
  mapping. `deploy-ntv-bundle.sh` alone goes at candidate root.

### No S3 Access During QA

- All required assets are local:
  - Branch build: `builds/player-server-X.Y.Z.zip`
  - Scripts: latest published release dir under `fleet-gitops/player-apps/releases/`
- Downloading from S3 during QA preparation violates the isolation contract

### QA Device Baseline

- Current device state: **5 system crontab entries**
- After deployment: **5 system crontab entries** (deployment restores baseline; no new entries added)
- Schema baseline: complete SQLite schema matching `createDbTableScripts` table inventory

### Version Bump Timing

Follow the canonical release-metadata rule in `../SKILL.md`, then run
`../scripts/validate-release-metadata.sh` with the fix-branch repository, exact candidate
version, and the appropriate `next` base ref before preparing QA artifacts. This ensures
QA validates the exact committed metadata and candidate state that will be merged.

### Merge Timing

- QA should happen on current `next` base
- If `next` advances between QA-pass and merge, canonical rebuild comparison will catch drift
- Drift requires QA repeat

## Risks

1. **Merge conflicts post-QA**: If `next` advances, canonical rebuild may differ → requires QA repeat
2. **HTTP server process leak**: If preparation fails mid-run, server may remain → cleanup includes PID check
3. **Port conflicts**: Multiple parallel QA sessions need distinct ports (8765, 8766, 8767...)
4. **Script adaptation fragility**: Template structure changes in fleet-gitops break adaptation → fail fast on unexpected patterns
5. **Device state pollution**: Failed deployments may leave partial state → rollback via bundle rollback script
