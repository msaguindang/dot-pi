## Prompt Routing

Classify every prompt before acting. Default to DIRECT — only escalate when the task genuinely demands it.

**DIRECT** — respond inline, no agents.
- Conversational, questions, explanations, quick edits, lookups
- `REV` mode (Fast Path) local reversible edits as defined in orchestration-policy.md

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
- Code changes go to `worker` (unless `REV` fast path eligible) — never write code inline as orchestrator outside REV

## Orchestration & Risk Tiers

See `~/.agents/standards/orchestration-policy.md` for the canonical R0-R3 risk tier policies, Pre-Fix diagnostic gates, and Post-Mutation review triggers.

- The selected risk tier owns the orchestration path and subsumes matching generic pipelines. Do not stack duplicate pipelines.
- Do not weaken R3 device, release, or destructive safety.
- **Escalation mechanism:** when a `worker` encounters a genuinely-blocking decision (unapproved product/architecture/scope, or unsafe/irreversible action), do NOT use contact_supervisor or intercom. Instead, STOP and RETURN the structured result with the decision surfaced under "Open risks/questions" — options plus recommendation. The orchestrator/user decides and re-dispatches.
- **Subagent claims are unverified until checked (INV-13):** before reporting a dispatch done, the orchestrator independently confirms the claimed artifacts exist — files on disk, worktrees/tags in git, objects on S3. A worker result saying "created" is a claim, not evidence.
- **Device work requires a post-deploy probe:** after any deployment or mutation on a fleet/test device, dispatch a probe (rpi-doctor skill) that reads the ACTUAL device state before reporting success.
- **Oracle prompt-validation for complex/irreversible work:** before dispatching workers on multi-step, fleet-facing, or irreversible tasks, route the full intent + constraints through `oracle` to critique the plan and surface blocking questions.

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
- **Starting work on an NTV ticket, feature, or bug**: load `ntv-worktree-manager` (except for pre-classified `REV` edits; any ticket disqualifies REV)
- **Plane task queries, ticket status, sprint/backlog**: load `plane-tasks`
- **Session start / morning briefing**: load `session-clock-in`
- **Session end / wrapping up / day log**: load `session-clock-out` (chains to `work-log-writer`)
- **Multi-step delegation pipeline (design → implement → review)**: load `delegate` skill
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
