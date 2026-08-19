---
name: ntv-release
description: Cut an immutable-artifact release of player-server and/or player-ui — version bump, prod builds, fresh UUID BUILD_ID, S3 upload to secure-rc/<BUILD_ID>/, fleet-gitops release record (release.yaml + rollback.md + verification.md), and 5-stage validation. Use when asked to "cut a release", "ntv-release", "release player-server X.Y.Z", "release player-ui A.B.C", "publish a release bundle", or to prepare/validate a fleet-gitops release record.
---

# ntv-release

Automates the NTV release ritual: fix branch → `next` → version bump → prod build →
fresh UUID BUILD_ID → S3 upload → fleet-gitops release record → validation → review.
Output: an immutable S3 folder `s3://ncompasstv-prod-player-apps/secure-rc/<BUILD_ID>/`
plus a release record in `fleet-gitops/player-apps/releases/`.

Device scripts placed in the release must follow
`/data/dev/work/ntv/fleet-gitops/docs/deploy-script-standard.md` (strict mode,
self-detach via re-download, SIGHUP trap, idempotency gate, crontab window,
`[N/M]` markers, post-mortem verification, no jq, `bash -n` before upload).

## Hard rules

- **Fresh UUID BUILD_ID per release. Never reuse.** Live BUILD_ID folders in S3 are
  immutable — a new fix means a new UUID folder. `release.sh` generates the UUID and
  refuses any UUID already recorded in `fleet-gitops/player-apps/releases/*/release.yaml`;
  `publish` refuses to upload into a non-empty S3 prefix.
- **Staged-overwrite exception needs a human.** A staged release that NO device has ever
  fetched may be replaced in place — but only via
  `init --build-id <UUID> --confirm-staged-overwrite`, which additionally demands an
  interactive typed `OVERWRITE-STAGED` on a real TTY. The skill never decides this alone:
  a human must first verify `deployment-manifest.json` on all devices and explicitly approve.
- **Coupled releases stay coupled.** Every release directory names BOTH versions
  (`<date>_<server-ver>-server_<ui-ver>-ui`) and bundles BOTH zips, even when only one
  component changed. No npm install / no OS package changes on fleet devices.
- **No fleet rollout before test-device verification** (verification.md checklist).

## S3 Layout — one flat level per build id, by design

Each `secure-rc/<BUILD_ID>/` folder holds everything for one component's one release
cut (its zip + its update script, or the bundle's own orchestrator + rollback script)
in a single flat level — not split into content-type directories like
`secure-rc/artifacts/player-server/` + `secure-rc/scripts/`. This is intentional, not
an oversight: the folder itself is the atomic, immutable unit the whole rollback/audit
system depends on ("Fresh UUID BUILD_ID per release. Never reuse." above). Any given
folder means exactly one frozen thing, forever — that's what makes a rollback command
or an incident-response S3 URL trustworthy months later.

Three independent build ids exist per release — `BUNDLE_BUILD_ID` (always fresh, the
orchestrator is re-adapted every release), `SERVER_BUILD_ID`, `UI_BUILD_ID` (each fresh
only if that component actually changed, otherwise reused from the prior release's live
folder) — specifically so an unchanged component is never re-uploaded or relocated just
because its sibling changed. This is why a bundle's own script and its component zips
can legitimately live in *different* folders within one release: `deploy-ntv-bundle.sh`
holds separate `S3_SERVER_BASE`/`S3_UI_BASE` URLs rather than assuming co-location.

A content-type-organized layout (versioned filenames in a long-lived shared directory)
would be more human-browsable via `aws s3 ls`, but would move the versioning/immutability
guarantee onto filename discipline in a mutable directory instead of the folder itself,
and would require rewriting the URL scheme baked into every deploy/update/rollback
script plus `release.sh`'s build-id logic. Considered and declined 2026-08-19 — if
browsability is what's needed, the fix is a small tool that reads
`fleet-gitops/player-apps/releases/*/release.yaml` (already the version→build-id index)
into a table, not a change to the S3 layout itself.

## Operating Defaults

- **Risk Tier Application:** Editing release tooling locally without publishing/deploying is **R2**. Executing prepare, publish, or deploy external steps is **R3** (Irreversible/External). See `~/.agents/standards/orchestration-policy.md` for canonical generic definitions (evidence rules, fail-fast limits, output hygiene, and blast-radius defaults).
- **Session-continuation scope lock.** When resuming a release from a handoff doc, scope
  is frozen to exactly what the handoff doc specifies. No new findings, no
  re-investigation of settled root causes, no refactors — unless the user explicitly
  reopens scope.
- **S3 round-trip verify is mandatory, not optional.** After every upload, verify the
  live object matches the recorded checksum — not just that a file with that name
  exists. `release.sh publish` step 5 + `validate-release.sh` stage 6 run `aws s3 ls`
  for filename presence, and stage 6b (`scripts/validate-release.sh`, "Stage 6b: S3
  content verification") re-derives/compares content hashes against the uploaded
  bytes: `aws s3api head-object` ETag compared to the local file's MD5 for ordinary
  (non-multipart) uploads — current artifact sizes are well under the AWS CLI's 8MiB
  multipart threshold, so this is the normal path — with an automatic fallback to a
  streamed `aws s3 cp <s3://...> - | sha256sum` compared against `checksums.sha256`
  for any object whose ETag indicates a multipart upload (ETag containing `-`). A
  filename-presence PASS alone is no longer sufficient by construction: stage 6b runs
  immediately after stage 6 and fails the whole validation (non-zero exit, explicit
  `[FAIL] CONTENT MISMATCH` line) on any content mismatch.
- **Handoff doc protocol.** Re-read the relevant `agent-sessions/` handoff doc at the
  start of every phase. After every phase completes, append outcome + evidence (SHAs,
  verdicts, timestamps) to its progress log.

## Pre-Merge QA Gate (Mandatory)

**Pre-merge QA MUST pass before merge into `next`. Merge before QA is prohibited.**

**Canonical release-metadata rule:** Before pre-merge QA, every component whose version changes must have committed `package.json`, applicable lockfile version fields, and a matching `CHANGELOG.md` version section that describes only the candidate changes. Validate this committed metadata with `scripts/validate-release-metadata.sh`.

Every fix/feature branch must complete local QA validation on a test device before
merging. This gate prevents defects from entering the integration branch and ensures
that only device-validated code reaches immutable S3 artifacts.

### QA Preparation (steps 1-3)

1. **Build the fix branch** — Run production build on the unmerged fix branch.
   No BUILD_ID allocation, no S3 access, no merge.
2. **Assemble temporary QA candidate** — Under `/tmp`, combine the branch build with
   production-provenance public assets (32 files from `.worktrees/next/src/public`).
   Use latest reviewed release scripts from `fleet-gitops/player-apps/releases/*-rev2/`,
   adapt URLs only (S3 → LAN HTTP), preserve all installer logic.
3. **Start LAN HTTP server** — Serve the candidate over LAN (e.g., `192.168.1.120:8765`).
   Generate manifest with source commit, artifact SHA-256, script SHA-256, host URL,
   server PID, and cleanup command.

   See `docs/qa-local-preparation.md` for the complete preparation procedure.

### Device Verification (steps 4-7)

4. **First-run installation** — Manually deploy to QA device via the HTTP-served script.
   Server-only installation authorized.
5. **First-run verification** — Collect post-deploy evidence (9 indicators):
   - Build-info commit matches branch HEAD
   - Package version matches
   - Complete SQLite schema (tables match `createDbTableScripts` inventory)
   - Startup send evidence in logs
   - PM2 stable (5 min, restart count not increasing over observation)
   - API health endpoint responds
   - Crontab total correct (5 entries; deployment restores baseline)
   - Deployment manifest written
   - Operator-attested lxterminal visibility on display
6. **Second-run idempotency** — Re-run the same deployment script.
7. **Second-run verification** — Prove no-op behavior (6 checks):
   - Script exits 0 with already-target log message
   - No application file mutations (except logs/deployment-manifest)
   - No database schema mutations (table inventory unchanged)
   - PM2 restart count not increased
   - Crontab unchanged (5 entries total)
   - Deployment manifest may be refreshed (hash change acceptable)

### Review and Merge (steps 8-9)

8. **Review gate** — Dispatch `reviewer` agent with:
   - Branch diff
   - QA candidate manifest
   - First-run evidence (all 9 indicators)
   - Second-run evidence (all 6 idempotency checks)
   - Contracts: `code-style.md` + `PRODUCTION_READY_MANIFEST.md`
   
   Required verdict: `PASS`. Any `FAIL` or `BLOCKER` blocks merge.

9. **Merge into next** — Only after reviewer PASS, merge the fix branch:
   `git checkout next && git merge --no-ff fix/<name>`; push both remotes.
   Then clean up: stop HTTP server, remove `/tmp` candidate.

### Canonical Rebuild Comparison (step 10)

After merge, the canonical release ritual builds from the merged `next` HEAD. Before
S3 publication, compare the canonical artifact to the tested QA candidate:

- **Allowed differences**: timestamps, git commit hash (now points to merge commit)
- **Unexpected differences**: If canonical differs in structure/content beyond approved
  metadata, **BLOCK publication** and repeat QA with the canonical artifact.

This ensures the tested candidate matches what will be deployed to the fleet.

## Post-QA Release Ritual (steps 11-19)

**Note:** Steps 1-10 (Pre-Merge QA Gate and canonical rebuild comparison) must complete
before this ritual begins. The steps below assume QA has passed and the fix branch has
been merged into `next`. The target package version must be committed on the fix branch
**before** pre-merge QA begins.

11. **Fix branch work** — `fix/*` off `next` (matching branch names across repos for
    cross-repo fixes). Typecheck, lint, Conventional Commits, satisfy the canonical
    release-metadata rule above, and push to BOTH `origin` and `forgejo`. *(Completed before QA)*
12. **Merge into next** — `git checkout next && git merge --no-ff fix/<name>`; verify a
    merge commit was created; push both remotes. *(Completed at QA step 9)*
13. **Verify target version** — Confirm `package.json` version matches the already-tested
    target version from QA. No new version bump after QA — the canonical artifact must
    match the tested candidate. The script verifies clean tree and package.json version.
14. **Prod build** — `NODE_ENV=prod npm run build:prod` → `builds/player-<repo>-X.Y.Z.zip`.
    Both artifacts must exist; the server ZIP must exceed 1 MiB, and the UI ZIP must be
    readable and contain `player-ui-<version>/index.html`. *(automated by `release.sh init`)*
15. **Fresh BUILD_ID** — new UUID, collision-checked against all prior release records.
    *(automated by `release.sh init`)*
16. **S3 upload** — `checksums.sha256` over every zip + script, upload all to
    `secure-rc/<BUILD_ID>/`, verify presence via `aws s3 ls` and content via
    `head-object` ETag/MD5 (streamed-sha256 fallback for multipart uploads).
    *(automated by `release.sh publish`)*
17. **Fleet-gitops record** — release dir with release.yaml, rollback.md, verification.md;
    commit `feat(gitops): add release record for <RELEASE_ID>`; push both remotes.
    *(dir+records by `init`, commit+push by `publish`)*
18. **Validation** — 4 local stages (files present, `sha256sum --check`, YAML parse,
    `bash -n` all scripts) via the fleet-gitops validator, plus stage 6 S3 presence and
    stage 6b S3 content verification.
    *(automated by `validate-release.sh`)*
19. **Review** — human verifies: release.yaml fields populated, `aws s3 ls <BUILD_ID>/`
    complete, checksums pass, gitops commit present on both remotes.
    Verdict: APPROVED or BLOCKED.

## Completion Report Format

Any report marking a phase or the full ritual complete and awaiting user action MUST
state, when applicable:

- Whether the user needs to build or upload anything themselves — explicit yes/no.
- The exact command/one-liner the user would run to test or proceed, verbatim (not
  "the deploy command").
- Which device(s) already have the artifact deployed, and which branches/worktrees hold
  the reviewable code.

## Usage

### Phase 1 — init (build + record scaffolding, checksums, no network writes)

```bash
~/.pi/agent/skills/ntv-release/scripts/release.sh init \
  --server-version 2.10.2 --ui-version 3.0.50 \
  --fix-branch fix/download-integrity-fix \
  --skip-ui-build            # server-only patch: reuse existing UI zip
```

Preflights both repos (clean tree, package.json == requested version), runs prod builds,
generates the BUILD_ID, detects prior-stable, creates
`fleet-gitops/player-apps/releases/<YYYY-MM-DD>_<sv>-server_<uv>-ui/` with release.yaml,
rollback.md, verification.md, both zips, and device-script seeds copied from
`fleet-gitops/player-apps/templates/`. Checksums are generated here.
PREPARE is the sole writer.

### Phase 2 — review generated scripts and commit

Review the automatically rendered scripts: `deploy-ntv-bundle.sh`, `update-<sv>-server.sh`,
`update-<uv>-ui.sh`, and `rollback-bundle.sh`. They are generated from the checksum-verified
canonical fleet baseline.

Validate, review, and commit the non-ZIP release record (including checksums.sha256).
ZIPs must remain untracked.

### Phase 3 — publish (locally read-only pure transport, dry-run by default)

```bash
~/.pi/agent/skills/ntv-release/scripts/release.sh publish <release-dir>            # dry-run
~/.pi/agent/skills/ntv-release/scripts/release.sh publish <release-dir> --execute  # real
```

PUBLISH is locally read-only: it validates existing bytes and committed state, uploads only
manifest-listed bytes plus manifest, round-trip verifies, and pushes the existing commit.
Publication never rebuilds, rerenders, regenerates checksums, rewrites files, or creates commits.

`--execute`: `bash -n` gate, local validation against existing checksum manifest, S3 immutability guard, upload,
post-upload S3 validation, then push fleet-gitops existing HEAD to both `origin` and `forgejo`.

### Standalone validation

```bash
~/.pi/agent/skills/ntv-release/scripts/validate-release.sh <release-dir | BUILD_ID> [--local-only]
```

Exit 0 = PASS. Evidence log: `/tmp/validate-<BUILD_ID>.log`. Delegates stages 1–5 to the
source-of-truth validator `fleet-gitops/player-apps/tools/validate-release.sh`, adds
stage 6 (S3 presence of every checksummed file) and stage 6b (content hash of every
checksummed file against the live S3 object — ETag/MD5, or streamed sha256 for
multipart uploads). Note: historical releases fail checksum
validation after their zips are cleaned from the dir — that is expected; validate while
zips are present.

## Coupling rule (paired releases)

- Server patch with unchanged UI → re-bundle the prior stable UI zip
  (`--skip-ui-build`, `--ui-version` = prior UI version). Example: 2.10.1 shipped as
  server 2.10.1 + UI 3.0.50, where UI 3.0.50 was the unchanged zip from the 2.10.0 bundle.
- Directory name ALWAYS carries both versions, even if only one changed.
- Sole version-reuse exception: post-deploy UI bug → patch UI → NEW UI version → new
  coupled release with server version unchanged.

## Prior-stable determination

Source of truth: **annotated** git tags (`git tag -l | grep -E '^v[0-9]' | sort -V | tail -2`
to eyeball the last two). NOT package.json alone — bumps that never shipped don't count.
The script prefers bare `vX.Y.Z` annotated tags; suffixed tags (`v2.9.44-rc.0`,
`v3.0.45-HLZHSVWV`) are pre-release/variant and used only when no bare tag exists.
Fallback when no annotated tag: newest `chore(release): bump version to X.Y.Z` commit —
eyeball it, unshipped bumps pollute this. When detection is stale (tags lag actual
deployments — currently true in both repos), override with `--prior-server` /
`--prior-ui`. Rollback.md records prior-stable versions, refs, commits, and the prior
bundle's BUILD_ID.

## Bundled resources

- `scripts/release.sh` — orchestrator: `init` (ritual 4–5, 7-scaffold) + `publish` (6, 7-commit)
- `scripts/validate-release.sh` — ritual 8: stages 1–5 via fleet-gitops validator + stage 6 S3
  presence + stage 6b S3 content verification (ETag/MD5, multipart-fallback streamed sha256)
- `scripts/gen-checksums.sh` — `checksums.sha256` over `*.zip` + `*.sh` with self-check
- `templates/release-yaml-template.yaml` — matches the live fleet-gitops release.yaml shape
- `templates/rollback-md-template.md`, `templates/verification-md-template.md`

## Known limitations

- Staged-overwrite precondition ("no device ever fetched it") is a manual
  deployment-manifest.json check on devices — not automated.
- No release lock: two concurrent `init` runs could race (UUID collision is checked, but
  directory/record races are not).
- release.yaml status transitions (staged → tested → …) are manual edits by the release owner.
- No Plane ticket integration — see skill-ship-and-announce.
