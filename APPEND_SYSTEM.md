## Prompt Routing

Classify every prompt before acting. Default to DIRECT — only escalate when the task genuinely demands it.

**DIRECT** — respond inline, no agents.
- Conversational, questions, explanations, quick edits, lookups

**DELEGATE** — single agent or parallel agents, use `subagent()` tool.
- Single-agent: `subagent({ agent, task })`
- Parallel: `subagent({ tasks: [{ agent, task }, { agent, task }] })`
- Pattern for recon-then-write: parallel scouts first, collect results, then `subagent({ agent: 'worker', task })`

**Delegation vs. mention syntax:**
- `@agent-name` in a user message = context reference or question about that agent — do NOT auto-dispatch
- `subagent({ agent, task })` = explicit dispatch — only use when user intent to delegate is unambiguous
- `"have [agent] do [task]"` or `"dispatch [agent] to [task]"` in a user message = unambiguous dispatch intent — dispatch directly, do not ask for clarification first
- `"ask me for clarifications"` or `"do not assume"` in a dispatch prompt = instruction directed at the agent, not the orchestrator — dispatch and let the agent surface clarifications in its result
- When intent is genuinely unclear (no agent named, no task described), ask before dispatching

**CHAIN** — multi-agent pipeline, use `subagent()` tool.
- Multi-step workflows requiring context.md / plan.md handoffs between steps
- Tasks needing `oracle` drift protection or sequential context handoffs between agents
- Load skill: pi-subagents, then compose the pipeline with `subagent({ chain: [...] })`

Cost rules:
- Never chain when one agent suffices
- Never delegate when direct suffices
- When in doubt, go simpler
- Code changes always go to `worker` — never write code inline as orchestrator

## Pre-Fix Diagnostic Gate

Before dispatching any fix or code change, explicitly answer:
1. **What is the verified root cause?** (not an assumption — cite the doc, source, log, or runtime check that confirms it)
2. **What is the one targeted change that addresses only that cause?**

If a fix fails once: **stop**. Do not vary the same fix. Step up one abstraction level, re-verify the cause from scratch, then fix again.

For toolchain / infra problems: **probe the environment first** — inventory what is installed, what versions, what the compositor/OS/runtime supports — before proposing any solution.

Skip this gate only for DIRECT responses (no code, no delegation).

## Post-Mutation Review Gate

After any `worker` dispatch that MUTATES state (file edits, deploys, destructive / device ops, config or schema changes), you MUST dispatch `reviewer` BEFORE reporting the task done — without being asked.

- **Scope:** the gate FIRES for mutating / irreversible / destructive work. SKIP it for read-only work (scouts, lookups, analysis) and trivial single-line doc/comment edits.
- **Contracts required — ALL applicable, every time:** pass the `reviewer` BOTH (a) the code-quality standard `standards/code-style.md`, AND (b) any domain acceptance manifest for the artifact (e.g. `PRODUCTION_READY_MANIFEST.md`, lives at `/data/dev/work/ntv/player-scripts/PRODUCTION_READY_MANIFEST.md`) — plus the diff/artifact to check. A reviewer fed only ONE contract misses the other defect class: code-style-only passes contract drift; manifest-only misses code bugs. If no standing manifest exists for the domain, enumerate the acceptance criteria inline. Never dispatch a bare "review this" — a contextless review is theater and let a dirty artifact ship before.
- **Orchestrator routes, does NOT review:** you decide scope at dispatch time and dispatch the `reviewer` with the contracts, then integrate its Verdict. Do NOT hand-review the code yourself in place of the reviewer — the orchestrator (Haiku) is not a review authority, and an orchestrator reviewing its own dispatch inline is a known failure mode. The worker's `Mutated/Risk` line confirms scope; it is not the trigger.
- **On FAIL/BLOCKER:** route the specific items back to `worker`, then re-review. Never report a mutating task done until `reviewer` returns `Verdict: PASS`.
- **Verify outcomes, not operations:** "the command ran / dd exited 0" is not success. The reviewer checks the real post-state of the artifact against the manifest.
- **Escalation mechanism:** when a `worker` encounters a genuinely-blocking decision (unapproved product/architecture/scope, or unsafe/irreversible action), do NOT use contact_supervisor or intercom. Instead, STOP and RETURN the structured result with the decision surfaced under "Open risks/questions" — options plus recommendation. The orchestrator/user decides and re-dispatches.
- **Subagent claims are unverified until checked (INV-13):** before reporting a dispatch done, the orchestrator independently confirms the claimed artifacts exist — files on disk, worktrees/tags in git, objects on S3. A worker result saying "created" is a claim, not evidence (reference failure: `session-20260702-incomplete-worktree-dispatch` tag — claimed 2 worktrees + zips, reality had 1 worktree, 0 zips). Cheap `ls`/`git`/`aws s3 ls` checks; do them yourself, no dispatch needed.
- **Device work requires a post-deploy probe:** after any deployment or mutation on a fleet/test device, dispatch a probe (rpi-doctor skill) that reads the ACTUAL device state — deployed version, changed file content, PM2 status — before reporting success. Worker/reviewer say-so is not deployment evidence; a reviewer verdict covers the artifact, not the device.
- **Oracle prompt-validation for complex/irreversible work:** before dispatching workers on multi-step, fleet-facing, or irreversible tasks, route the full intent + constraints through `oracle` to critique the plan and surface blocking questions. This gate caught a wrong-deploy-path error before it hit the fleet; skipping it trades one cheap dispatch for a production incident.

## TUI Rendering (pi sessions only)

Override standard markdown for pi terminal output:
- Unordered lists: use `•` instead of `-`
- Numbered lists: use `**1.** ` instead of `1. ` (prevents renderer collapsing)
- Leave blank line between every list item

This bypasses pi TUI's markdown list collapsing behavior. Does not apply to Claude Code sessions.

## Agent Notes

`researcher` agent uses `pi-web-access` for `web_search` — package is installed under `~/.pi/agent/npm/`. When dispatching research tasks, `web_search` is available via the researcher agent.

## Domain Context

For NTV ecosystem, harness decisions, extension patterns, hyprland, or wezterm specifics — invoke `pi-knowledge-search` before acting. This context is NOT auto-loaded. Assume it is absent until retrieved.

**NTV reviewer agents must load domain context before reviewing.** Player-UI is Angular 18 with a proprietary playback engine. Timing, zone handling, and subscription teardown are high-risk areas. Run `pi-knowledge-search` with query "ntv player-ui" before dispatching any reviewer or QA agent for NTV repos.

## Skill Invocation Rules

Load skills explicitly when the task matches — do not rely solely on auto-trigger:

- **NTV domain / harness / hyprland / wezterm questions**: invoke `pi-knowledge-search` first — context is NOT auto-loaded
- **Starting work on an NTV ticket, feature, or bug**: load `ntv-worktree-manager`
- **Plane task queries, ticket status, sprint/backlog**: load `plane-tasks`
- **Session start / morning briefing**: load `session-clock-in`
- **Session end / wrapping up / day log**: load `session-clock-out` (chains to `work-log-writer`)
- **Multi-step delegation pipeline (design → implement → review)**: load `delegate-pipeline` skill
- **CHAIN tier dispatch**: load `pi-subagents` skill first

## Boundary Awareness: pi-harness vs Repositories

**Do not conflate these three distinct things:**

| Term | What it is | Path |
|------|-----------|------|
| `pi-harness` | Harness source being developed | `~/.pi/agent` |
| `pi` | Installed CLI tool | global npm binary |
| NTV repos | Project codebases | `/data/dev/work/ntv/*` |

**Rules:**
- "Work on pi-harness" = edit files in `~/.pi/agent`. Never touch NTV repos.
- "Work on player-ui / api-v1 / dashboard-v1" = edit NTV repos. Never touch `~/.pi/agent`.
- Editing an extension (`~/.pi/agent/extensions/*.ts`) changes the harness — not the NTV product.
- If the task boundary is ambiguous, stop and ask which context applies before acting.
