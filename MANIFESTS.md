# Acceptance Manifests

Checklists for the post-mutation review gate (INV-10). The `reviewer` agent must be passed the relevant manifest alongside the diff/artifact. A review without a manifest is theater — it checks nothing specific.

Reference: `~/.agents/standards/orchestration-policy.md` Post-Mutation Review Gate section.

---

## 1. Code-Style Manifest

For code changes (TypeScript, Bash, Python) submitted to any repo.

Full standard: `~/.agents/standards/code-style.md`

- [ ] Commit message follows Conventional Commits: `<type>(<scope>): <subject>` — scope is ticket ID if one exists
- [ ] Branch name follows `[type]/[ticket-ID]-[description]` format
- [ ] TypeScript: target ES2022, module NodeNext, strict mode enabled
- [ ] TypeScript: all function parameters and return types are explicit
- [ ] TypeScript: `interface` used over `type` unless unions required
- [ ] TypeScript: import order — Node built-ins → third-party → local
- [ ] TypeScript: all async/await paths wrapped in `try/catch`; no silent error swallowing
- [ ] TypeScript: `.js` extension used in all local imports (NodeNext requirement)
- [ ] TypeScript: no implicit coercion — truthy/falsy checks are explicit (`data.length > 0`, not `data.length`)
- [ ] TypeScript: guard clauses used for early returns; no deeply nested `if/else`
- [ ] Bash: shebang is `#!/usr/bin/env bash`
- [ ] Bash: `set -euo pipefail` at top of every script
- [ ] Bash: all variable expansions are quoted (`"$VAR"`)
- [ ] Bash: functions `snake_case`, constants `UPPER_SNAKE_CASE`
- [ ] Bash: 4-space indentation (no tabs)
- [ ] No hardcoded absolute user paths (`/home/user/`, `C:\Users\Name\`) — use `~` or env vars
- [ ] Files: UTF-8 encoding, LF line endings (no CRLF)
- [ ] Deployment pipelines: pre-upload cleanup task present (target dir purged before extraction)
- [ ] `build-info.json` sidecar generated for CI/CD builds; version field in `package.json` is clean SemVer (no branch/hash injection)

---

## 2. Device / RPI Deployment Manifest

For `rpi-deploy` and `rpi-imager` operations targeting Raspberry Pi hardware.

- [ ] Branch confirmed: correct branch checked out in the repo being deployed (not main/next by accident)
- [ ] Working tree clean — no uncommitted changes that would taint the artifact (`git status` clean or `--allow-dirty` explicitly approved by user)
- [ ] `rpi-deploy` preflight passed: host resolves, SSH connection succeeds, device is reachable
- [ ] Build completed without errors before upload step
- [ ] `build-info.json` sidecar present in built artifact (version, branch, buildNumber, commitHash, timestamp)
- [ ] Remote directory purged before extraction (no stale files from previous build)
- [ ] Post-deploy verification: `build-info.json` on device matches the artifact just deployed (commitHash + branch confirmed)
- [ ] Service restarted and stable: pm2 status shows `online`, no crash restarts in first 60 seconds
- [ ] API/health endpoint responds (where applicable): `curl http://<device>/health` returns expected response
- [ ] For `rpi-imager`: device identity confirmed before imaging (hostname, SSH key — not a production device)
- [ ] For `rpi-imager`: output `.img.xz` SHA256 verified against imager JSON summary
- [ ] Branch isolation respected: Pi 5 Trixie/VLC4K builds never merged into main/next Pi 3/4 Buster branches

---

## 3. Extension / TUI Manifest

For changes to `~/.pi/agent/extensions/*.ts` or TUI-rendering code.

- [ ] Extension loads without TypeScript errors (`tsc --noEmit` or bun type-check passes)
- [ ] API signatures verified against actual `.d.ts` files in the pi package (`~/.nvm/.../node_modules/@earendil-works/pi-coding-agent/`) — no assumed method signatures
- [ ] Extension load order in `settings.json` respects declared invariants (INV-12, INV-13, INV-14 in `HARNESS_INVARIANTS.md`)
- [ ] No `TrueColor` (24-bit RGB) ANSI hardcoded — use `ctx.ui.theme.*` methods for color styling (16/256-color safe)
- [ ] If using `setWidget`: factory form used (not string array form) for any colored widget content
- [ ] Factory form captures live Map by reference — `render()` always reads current state
- [ ] Spinner animations: frame advance and `requestRender()` are co-located in same interval loop
- [ ] `adjutant-editor.ts` interceptor set at TOP of `session_start` before any other handler returns
- [ ] `tui-dryrun.ts` gate honored: no TUI edits shipped without dry-run verification pass
- [ ] `harness-audit.sh` passes all invariant checks after change
- [ ] If extension was disabled (`-extensions/...`), README.md extension table updated to reflect status
- [ ] If new extension added to `settings.json`, README.md extension table row added with purpose description
