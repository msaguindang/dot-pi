---
name: rpi-deploy
description: Deploy player-server and/or player-ui to a Raspberry Pi test device by orchestrating each repo's native `npm run build:upload:<env>` pipeline, with branch/worktree preflight validation and mandatory post-deploy verification (build-info commit check, pm2 stability, API ping). Use when asked to deploy, push, or test a branch on Pi hardware.
---

# Raspberry Pi Deployer

A thin, agentic wrapper around the repos' OWN deploy pipelines. The script never
scp/rsyncs files itself — `player-server` and `player-ui` each have a gulp-based
`build:upload:<env>` pipeline that owns the remote target paths:

- **player-server** → tarball of `bundle/` extracted to `remotePath` from its `sshConfig.js`
  (currently `/home/pi/n-compasstv/player-server/`), then `pm2 restart player-server`.
  The `next` gulpfile's `writeBuildInfo` task writes a `build-info.json` sidecar into the
  bundle (version, branch, buildNumber, commitHash, dirty, env, timestamp), which lands at
  `<remotePath>/build-info.json` after extract.
- **player-ui** → tarball of `dist/player-ui/browser` extracted to `/var/www/html/ui`
  (nginx serves it). The repo's gulp `upload` task wipes the remote dir first and writes
  `build-info.json` (version, branch, buildNumber, commitHash, dirty, timestamp) via its
  `writeBuildInfo` task.

What this skill adds on top: deterministic branch→directory resolution, hard preflight
checks (right branch, clean tree, resolvable host — no fallbacks), a confirmation gate,
and post-deploy verification that the device is actually running what you built.

## Usage

```bash
~/.pi/agent/skills/rpi-deploy/scripts/deploy_to_pi.sh <branch> <env> <ui|server|both> [--yes] [--allow-dirty] [--smoke-test]
```

- `<env>`: `dev`, `stg`/`staging`, `prod`/`production`, `local`, `sandbox` — these map
  1:1 to the repos' `npm run build:upload:<env>` scripts. `jenkins` is not supported
  (interactive prompt in the repos).
- Scope is strict: `ui` never touches the server, `server` never touches the UI.
- `both` deploys UI first, then server (the server pipeline stops/restarts pm2 anyway).
- `--smoke-test`: after a successful deploy + build-info verification, run the
  `pi-smoke-test` Phase 1 suite (restarts the player and asserts the boot→playback
  chain: no re-init loop, no API 404/5xx, assets on disk and served, content
  rotating). Build-info proves the right bytes landed; the smoke test proves the
  player actually runs. A smoke-test failure makes the whole deploy exit non-zero.
  Tool location defaults to `$NTV_DIR/pi-smoke-test` (override with `PI_SMOKE_TEST_DIR`).
  Best paired with `both` or `server` scope, since it restarts the server process.

### Examples

```bash
# Preflight only — prints the plan, deploys nothing
deploy_to_pi.sh next dev both

# After user confirmation
deploy_to_pi.sh next dev both --yes

# UI-only deploy of a release branch (lives in .worktrees/release-v2.9.45)
deploy_to_pi.sh release/v2.9.45 dev ui --yes
```

## Mandatory workflow (the agent MUST follow this)

1. **Plan**: run the script WITHOUT `--yes`. It resolves directories, asserts the branch
   and a clean tree, and resolves the target host from each repo's `sshConfig.js` for
   the chosen env (e.g. `next` → `dev` → `<device-ip>` for player-server). It fails hard
   if anything is off — there are no hardcoded host fallbacks.
2. **Confirm**: show the printed plan (dirs, branch @ commit, version, **resolved host
   per repo**) to the user and get explicit confirmation. NEVER pass `--yes` without it.
   Note: hosts can differ between the two repos — `sshConfig.js` is per-checkout
   (untracked in player-ui, tracked in player-server), so always read the hosts from
   the plan output, never assume.
3. **Deploy**: re-run with `--yes`. The script runs `npm run build:upload:<env>` inside
   each repo checkout. HALT on any build failure — do not retry blindly.
4. **Verify** (the script automates this; review its output, do not skip):
   - **UI**: `build-info.json` is fetched from the device (`<remotePath>/build-info.json`,
     also via nginx at `http://<host>/ui/build-info.json`) and its `commitHash` compared
     against local `git rev-parse --short HEAD`. Mismatch = failed deploy. Both reads are
     parsed defensively (nginx returns 200 + index.html for a missing file — HTML fed to
     jq must count as a failure, not crash the script), and an empty/short remote commit
     never passes the prefix compare.
   - **Server**: sidecar-based, same as UI — `<remotePath>/build-info.json` is read over
     ssh and its `commitHash`/`branch`/`dirty` checked against the local server checkout.
     The remote `package.json` version compare is kept as a secondary check only. If
     `build-info.json` is missing on the device, the bundle predates sidecar versioning
     and verification FAILS — the first server redeploy after this change is required
     before server sidecar verification can pass.
   - **Dirty builds**: if build-info reports `dirty: true`, the build was made from a
     working tree with uncommitted changes (`--allow-dirty`). A commit-hash match is then
     NOT proof of content. This is flagged loudly but not counted as a failure; instead
     the final verdict is downgraded from "complete and verified" to "complete but NOT
     fully verifiable due to dirty build(s)".
   - **pm2 stability**: status + restart counter sampled twice, 20s apart. A climbing
     counter means a crash loop — fetch logs immediately:
     `sshpass -p raspberry ssh pi@<host> 'pm2 logs player-server --lines 100 --nostream'`
   - **API**: `GET http://<host>:3215/api/checkup/ping`. No HTTP response = server down.
     A non-2xx with a response can just mean the device has no internet (the endpoint
     proxies an upstream ping) — investigate rather than auto-fail.
5. If verification reports failures, tell the user plainly — do not declare success.
   If the verdict was downgraded due to dirty build(s), say so — never report a dirty
   deploy as fully verified.

### Completion Report Format

The final report to the user MUST state plainly: whether the deploy is done and
running (not just uploaded), and the exact way to independently check it — e.g. the
build-info URL(s) and the `GET http://<host>:3215/api/checkup/ping` check. Never leave
the user to ask "how do I verify this" after the fact.

## Preflight rules (enforced by the script)

- Directory resolution (single rule, both repos): use the repo root
  (`$NTV_DIR/player-server`, `$NTV_DIR/player-ui`) if it is checked out on `<branch>`,
  otherwise `.worktrees/<branch with / replaced by ->`. The resolved dir must actually
  be on `<branch>` — wrong branch is a hard failure. `NTV_DIR` defaults to
  `/data/dev/work/ntv`.
- Dirty working tree is a hard failure; `--allow-dirty` overrides with a loud warning
  (only use it when the user explicitly wants uncommitted changes deployed).
- `sshConfig.js` must exist in each resolved checkout (per-checkout config; untracked
  in player-ui — keep it out of commits there). If missing, copy it from another
  worktree of the same repo and review host/env entries.
- player-server additionally needs a `.env` in its checkout (it gets bundled; the
  pipeline rewrites `NODE_ENV` to match the chosen env).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| UI on screen still old after deploy | Check `http://<host>/ui/build-info.json` (or `ssh ... cat /var/www/html/ui/build-info.json`). If build-info is new, Chromium is showing a cached app — `pm2 restart player-chromium` on the device. If build-info is old, the upload targeted another host: inspect `sshConfig.js` in the UI checkout. |
| Stray/old files on the server remotePath | The `next` gulpfile's `extractAndDeploy` now wipes `src/` before extract (preserving `src/db`, `src/public/assets`, `src/public/screenshots`, `src/bin`). Older branches do NOT wipe — leftovers linger there; clean manually. |
| Server verify fails: build-info.json missing on device | The deployed bundle predates sidecar versioning (built before the gulpfile gained `writeBuildInfo`). Redeploy once with the updated gulpfile; subsequent deploys verify normally. |
| "sshConfig.js not found" | It's per-checkout and gitignored. Copy from a sibling worktree, verify the env→host mapping before re-running. |
| Build fails with TS errors only on deploy | `build:upload:base` runs full `tsc` — run `npm run typecheck` in the checkout to iterate. |
| pm2 restart counter climbing | Crash loop. Get logs (`pm2 logs player-server --lines 100 --nostream`), check the bundled `.env`, remember the Pi runs Node 12 — modern syntax (e.g. `Promise.any`) crashes at runtime even though it compiles. |
| Wrong device got deployed | Env→host mapping lives in each checkout's `sshConfig.js`; unknown `NODE_ENV` values silently fall back to `dev` inside that file. The script whitelists env names to prevent this, but verify the plan output every time. |

## Bundled resources

- `scripts/deploy_to_pi.sh` — preflight, native-pipeline invocation, verification.
