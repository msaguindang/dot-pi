---
name: ship-and-announce
description: Patch-closure macro for NTV player releases. Orchestrates 4 parallel workers to merge the verified fix, write release docs (fleet-gitops + Obsidian + Confluence), update Plane tickets, and draft a Teams announcement. Use when the user says "ship and announce the fix", "close out this patch", "announce the release", "ship it and tell everyone", or when a fix has been verified on the QA/staging device and needs final distribution plus announcement before fleet rollout is declared complete.
---

# ship-and-announce

Closes out a verified fix by dispatching **4 parallel workers**, each with a
self-contained task file and a **distinct output path** (per the
`delegation-validator` skill: forked subagents receive only what is explicitly
passed; task files must be self-contained, and two workers must never share an
output artifact).

| # | Worker | Task file | Result file | Timeout |
|---|--------|-----------|-------------|---------|
| 1 | Source fix (merge + version bump + push) | `/tmp/ship-source-<fix-id>-task.md` | `/tmp/ship-source-<fix-id>-result.md` | 10 min |
| 2 | Docs (fleet-gitops + Obsidian + Confluence) | `/tmp/ship-docs-<fix-id>-task.md` | `/tmp/ship-docs-<fix-id>-result.md` | 15 min |
| 3 | Plane tickets (create-if-missing + state + comments + follow-ups) | `/tmp/ship-plane-<fix-id>-task.md` | `/tmp/ship-plane-<fix-id>-result.md` | 10 min |
| 4 | Teams announcement draft | `/tmp/ship-announce-<fix-id>-task.md` | `/tmp/ship-announce-<fix-id>-result.md` | 5 min |

## HARD RULES

1. **The Teams message is ALWAYS a draft for a human to post. It is NEVER
   auto-sent.** Worker 4 must not call any Teams/Graph API, webhook, or mail
   bridge. The draft goes into its result file; the summary report tells the
   human to review and paste it.
2. **This skill orchestrates existing skills — it never reimplements their API
   calls.** Confluence writes go through `confluence-publisher`, Plane calls go
   through `plane-tasks` scripts, comms formatting follows `internal-comms`.
3. **All Plane API calls run as `infisical run -- <script>` with cwd
   `/home/codeweaver/.pi/agent/skills/plane-tasks/`** (infisical config is
   cwd-sensitive; `~/.pi/agent/.infisical.json` is the anchor).
4. **No shared output paths.** Each worker writes only its own result file and
   its own store (see boundaries below).
5. **A shipped fix always ends with a Plane ticket in `Done`, never with none.**
   `--tickets` is optional at dispatch time, but worker 3 must treat a missing
   ticket as "create one," not "skip Plane" — see worker 3 contract below.
   This is not optional cleanup; it is the fix for a recurring gap where fixes
   shipped without ever getting a ticket.

## Knowledge-Store Boundaries

Follows `/home/codeweaver/.agents/standards/knowledge-store-boundary.md`:
one home per fact, other stores link to it.

| Store | Role | This skill writes |
|-------|------|-------------------|
| **Git** (player-server, player-ui, fleet-gitops) | Deployment truth | Merge commit, version bump, release record (`release.yaml`, `rollback.md`, `verification.md`) |
| **Plane** | Current task/deployment status | Ticket state transitions, deployment comment (with commit hash), follow-up tickets |
| **Obsidian** | Durable rationale | Why the fix was needed, root cause, decisions, lessons learned — **never live status snapshots**; link to `release.yaml` instead |
| **Confluence** | External release notes for stakeholders | Formatted release notes (what shipped, how to update, rollback plan) — derived from the others, not a source of truth |

Source of truth is always the Git commit hash. Plane is live status. Obsidian
is historical rationale. Never duplicate a fact across stores — link.

> **Caveat (verify at runtime):** the knowledge-store-boundary standard notes
> Plane may be one-way synced from Git (`fleet-gitops/docs/plane-integration.md`),
> in which case manual state edits are overwritten on the next `main` push.
> Before worker 3 transitions states, check whether the sync owns those states;
> if it does, worker 3 only adds comments and creates follow-up tickets, and
> lets the sync move the state.

## Runtime Configuration (dispatching agent must supply or look up)

These are NOT hardcoded facts — they are config the dispatching agent passes in
or resolves at dispatch time:

| Config | Assumed value | How to verify at runtime |
|--------|---------------|--------------------------|
| Plane project | "NTV Player V1" (id `de83ad37…`) — **ASSUMED** | `cd ~/.pi/agent/skills/plane-tasks && infisical run -- scripts/plane-projects.sh` |
| Confluence parent page | "Player Release Notes", parent id `949354515`, space `NCTV` — **ASSUMED** | Fetch the page via confluence-publisher's API creds, or confirm with the user. Note: confluence-publisher's own default parent is `2588673` ("Raspberry Pi Player"), so **always pass `--parent-id` explicitly**. |
| Obsidian target dir | `~/Dropbox/Obsidian/2. Areas/01 Work/02 Fleet & Infra/` | `pre-dispatch-validate.sh` checks it is writable |
| S3 release bucket | `s3://ncompasstv-prod-player-apps/secure-rc/<BUILD_ID>/` | `aws s3 ls` during final verification (only if a new release bundle was cut) |

## Orchestration Flow

```
scripts/orchestrate.sh \
  --fix-id play-log-timezone \
  --fix-branch fix/play-log-timezone-local-time \
  --server-version 2.10.1 \
  [--ui-version 3.0.50] \
  --fix-summary "Play logs now recorded in device-local time instead of UTC." \
  --deploy-date 2026-07-16 \
  [--tickets "PV1-5,PV1-12"] \
  [--build-id 872c5fc2] \
  [--confluence-parent-id 949354515] [--confluence-page-id <id>] \
  [--plane-project "NTV Player V1"] \
  [--followups "<follow-up ticket titles>"] [--rollback-plan "<text>"] \
  [--repo-dir /data/dev/work/ntv/player-server] \
  [--fleet-gitops-dir /data/dev/work/ntv/fleet-gitops] [--obsidian-dir <dir>] \
  [--skip-validate] [--no-wait] [--resume]
```

`[--tickets ...]` is optional, but omitting it does **not** mean "no Plane
work" — it means worker 3 creates the ticket that should have existed already
(see hard rule 5 and worker 3's contract below).

1. **Input** — fix-id (slug), fix_branch, versions `{server, ui|null}`,
   fix_summary (1–2 sentences), deploy_date (ISO 8601).
2. **Pre-dispatch validation** — `pre-dispatch-validate.sh`: fix_branch exists
   on origin, Obsidian dir writable, Confluence reachable, Plane/infisical
   secrets available. Orchestrator aborts on failure.
3. **Task file generation** — `gen-task-{source,docs,plane,announce}.sh` render
   `templates/task-*-template.md` with `{{PLACEHOLDER}}` substitution, then
   scan each task file with
   `~/.pi/agent/skills/delegation-validator/scripts/validate.sh`
   (self-containedness gate; generation fails on suspicious relative refs).
4. **Dispatch 4 workers in parallel.** Two modes:
   - `SHIP_WORKER_CMD` env set (a command taking `<task-file> <result-file>`):
     orchestrate.sh backgrounds each with its per-worker `timeout`.
   - Otherwise (normal pi usage): orchestrate.sh prints a dispatch block; the
     **dispatching agent** launches 4 parallel subagents, each told to execute
     one task file and write its declared result file. Prompt shape:
     "Execute the self-contained task in `<task-file>`. Write your result to
     `<result-file>` in the exact format the task specifies. Touch nothing
     outside the task's scope fence."
5. **Wait** — poll for the 4 result files; per-worker deadlines 10/15/10/5 min,
   overall cap 15 min. Missing past deadline = TIMEOUT (recorded, not fatal to
   the other workers).
6. **Collect** — `collect-results.sh <fix-id>` parses the `status:` line and
   key fields from each result file.
7. **Final verification (parent, independent of worker claims)** — git log +
   ls-remote on both remotes for the merge/version, `aws s3 ls` for the
   BUILD_ID (if given), `curl` the Confluence page URL from worker 2's result,
   Plane ticket state query via plane-tasks (if project id resolvable).
8. **Summary** — written to `/tmp/ship-summary-<fix-id>.md` and stdout: merge
   status, docs status, tickets updated, Teams draft preview (first 200 chars),
   and action items ("review + paste Teams message", "ticket X now Done",
   "rollback: <command>").

Re-running after manual subagent dispatch: `orchestrate.sh --fix-id <id> --resume …`
skips validation/generation and goes straight to wait → collect → verify → summary.

## Worker Contracts (summary — full detail in templates/)

- **Worker 1 — source fix**: merge fix branch into `next` with `--no-ff`, bump
  `package.json` version, push to **both** remotes (origin + forgejo). Mutates
  only the player-server repo. No scope creep into unrelated files.
- **Worker 2 — docs**: fleet-gitops release record (dir + `release.yaml` +
  `rollback.md` + `verification.md`), Obsidian rationale note (frontmatter
  date, rationale only, pointer links for live state), Confluence release
  notes via `confluence-publisher/scripts/publish.sh`.
- **Worker 3 — Plane**: if `--tickets` was supplied, state transitions +
  deployment comment (with commit hash) on those tickets; if not, **create the
  primary ticket first** (`plane-create.sh`, title from fix-id + summary) and
  then transition/comment on it the same way — a fix with no ticket at all is
  not an acceptable outcome. Plus follow-up ticket creation. All via
  `plane-tasks` scripts under `infisical run --` from the plane-tasks
  directory. No orphaned follow-ups: if creation fails, say so in the result
  rather than retrying blind.
- **Worker 4 — Teams draft**: two-part message (exec summary in plain
  language, then technical detail: commit hashes, deploy command with absolute
  URL + BUILD_ID, verification steps, rollback). Format per the
  `internal-comms` skill (`examples/general-comms.md`). **Draft only.**

## Result File Format (all workers)

Each result file starts with a machine-parseable header, then free-form detail:

```
# ship-<worker> result: <fix-id>
status: success | partial | failed
<worker-specific key>: <value>
...

## Details
<free text>
```

Worker-specific keys are listed in each task template. `collect-results.sh`
greps these keys — keep them one per line, `key: value`.

## Dependencies

- `/home/codeweaver/.pi/agent/skills/confluence-publisher/` — worker 2 Confluence writes
- `/home/codeweaver/.pi/agent/skills/plane-tasks/` — worker 3 Plane calls (cwd-sensitive)
- `/home/codeweaver/.pi/agent/skills/internal-comms/` — worker 4 message format
- `/home/codeweaver/.pi/agent/skills/delegation-validator/scripts/validate.sh` — task-file self-containedness gate
- `infisical`, `aws`, `curl`, `jq`, `git` on PATH

## Known Limitations

- No auto-post to Teams (by design — hard rule 1). Future: webhook post behind
  an explicit human confirmation.
- Result parsing is line-oriented `key: value` grep — fragile to creative
  worker output. Future: JSON results.
- No rollback automation: the rollback command is surfaced in the summary, a
  human executes it.
- Worker 3 does not yet link follow-up tickets to the parent release ticket.
- Per-worker timeouts are fixed (10/15/10/5 min).
- ~~No Plane ticket integration~~ — closed: worker 3 now creates a primary
  ticket when `--tickets` is omitted instead of skipping Plane (hard rule 5).
  This was previously a recurring gap where fixes shipped without ever
  getting ticketed.
