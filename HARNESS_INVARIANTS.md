# Harness Invariants

The contract for "the pi harness is working as expected." Each invariant is an
assertion + how to check it. Run the `pi-harness-auditor` Claude Code agent to verify all programmatically.

> **Meta-rule (the gotcha that keeps biting):** a fix is not live until the session
> is **reloaded**. Committed ≠ running. After any harness change, start a fresh /
> reloaded session before trusting behavior or re-auditing.

> **Per-agent override rule:** `settings.json` `defaultThinkingLevel` is the GLOBAL
> default only. A per-agent `thinking:` pin in `agents/*.md` frontmatter **overrides**
> it. Lowering the global does NOT touch pinned agents. Audit the pins, not the global.

## Model routing

| Role | Model | Thinking | Rationale |
|------|-------|----------|-----------|
| orchestrator (`settings.json`) | **user's choice — not pinned** | user's choice | see INV-1 retirement note below |
| `worker` | `google/gemini-3.1-pro-preview-customtools` | **`medium`** | executor — planner already reasoned; high over-anchors + burns 2–5x tokens |
| `tui-worker` | `google/gemini-3.1-pro-preview-customtools` | **`medium`** | executor (same as worker) |
| `planner` | `google/gemini-3.1-pro-preview-customtools` | `high` | reasoning role — thinking belongs here |
| `session-auditor` | `google/gemini-3.6-flash` | `high` | cheap-tier bulk audit |
| `linux-doctor` | `google/gemini-3.1-pro-preview-customtools` | inherit (`low`) | diagnostics |
| `oracle` | `google/gemini-3.1-pro-preview-customtools` | `high` | reasoning/review — fork context analysis |
| `researcher` | `google/gemini-3.1-pro-preview-customtools` | `medium` | web research + synthesis — Gemini strong on search tasks |
| `context-builder` | `google/gemini-3.1-pro-preview-customtools` | `medium` | codebase analysis + handoff meta-prompt (settings.json override) |
| `delegate` | inherit (orchestrator default) | inherit (`medium`) | lightweight dispatch, inherits parent |
| `reviewer` | `google/gemini-3.6-flash` | `medium` | read-only gate — Flash sufficient for verification |

- **INV-1 (retired 2026-07-13):** previously pinned the orchestrator to `anthropic/claude-haiku-4-5`
  at `defaultThinkingLevel=medium`. Retired by user decision: Haiku's context window is a poor fit
  for the orchestrator role, which accumulates the full session transcript across every delegated
  turn. The harness now deliberately supports free orchestrator model switching — no pin, no audit
  check, no gate. `settings.json` `defaultProvider`/`defaultModel` is entirely the user's call;
  change it via `/model` or by editing the file directly. This retirement also removes the model
  routing table's former justification for keeping the orchestrator on the cheap tier — that
  tradeoff is no longer enforced by the harness.
- **INV-2** `worker` + `tui-worker` are `thinking: medium` (NOT high). Check: frontmatter grep.
- **INV-3** `planner` is `thinking: high`. Check: frontmatter grep.
- **INV-4** every agent's `model:` matches the table (oracle, worker, tui-worker, planner, session-auditor, linux-doctor, reviewer have explicit pins). Check: frontmatter grep.
  - *2026-08-04 revision:* fleet moved to Gemini per user decision — Pro (`gemini-3.1-pro-preview-customtools`) for writer/reasoning roles (worker, tui-worker, planner, oracle, context-builder), Flash (`gemini-3.6-flash`) for cheap gates (reviewer, session-auditor). Replaces the previous anthropic/minimax pins. Thinking levels unchanged.

## Delegation behavior

- **INV-5** No agent instructs a subagent to **block on a supervisor** — subagents are autonomous by default and **return** genuinely-blocking decisions in their result (options + recommendation). Blocking decisions are surfaced in the result, never waited on. Check: agent `.md` files contain "NEVER block" language and no "wait for reply" patterns.
- **INV-6** Agent autonomy: subagents do not block waiting for supervisor feedback. Genuinely-blocking decisions are surfaced in agent results with options + recommendation; the orchestrator/user decides and re-dispatches if needed. This constraint is enforced in agent `.md` documentation and validated during review.
- **INV-7** Providers are utilized, none idle by design: anthropic (orchestrator + worker/planner/tui-worker/oracle/context-builder), google (linux-doctor/researcher), minimax (session-auditor).

## Cost observability

- **INV-8** `cost-tracker.ts` footer aggregates subagent cost via `parentSessionId` (subagents run as separate processes with their own sessionId — the OLD filter on `sessionId` matched 0 and under-reported ~3x). Check: `grep parentSessionId extensions/cost-tracker.ts`.
- **INV-9** Footer total must match the **raw ground truth**: sum of `.message.usage.cost.total` across the parent `session.jsonl` + every subagent `*/run-*/session.jsonl`. Validate once per fresh session; reconcile periodically (session-auditor task). Do not trust the footer blind.

## Process discipline

- **INV-10** Review-as-default-gate points to canonical rules (see `~/.agents/standards/orchestration-policy.md`). Explicitly distinguish R2 post-implementation review from R3 pre-irreversible review. Irreversible/destructive work (deploys, device imaging) is reviewed against an acceptance spec **before** the irreversible step — not on user request. Review without a spec is theater.
- **INV-11** Verify outcomes, not operations: tool exit 0 ≠ task success. Inspect the produced artifact against its acceptance criteria; report verified-vs-assumed, never present mechanical success as semantic success.
- **INV-13** Subagent success claims are unverified until the orchestrator confirms the claimed artifacts exist (files on disk, worktrees/tags in git, objects on S3). A result message is a claim, not evidence. Origin: `session-20260702-incomplete-worktree-dispatch` tag in player-server — worker claimed 2 worktrees + build zips; reality had 1 worktree and 0 zips. For device deployments this extends to a post-deploy probe of actual device state (rpi-doctor). Check: APPEND_SYSTEM.md Orchestration & Risk Tiers contains the verification + probe clauses.
- **INV-18** REV mode remains an R1 fast path shorthand. Normal R1/R2/R3 behavior is unchanged. Check: orchestration-policy and compile-workflow tests.

## Extension load order

- **INV-12** `adjutant-editor.ts` must load before `adjutant-greeting.ts`. Greeting reads editor state established by the editor extension; if editor loads after, the greeting renders against an uninitialized context. Check: `adjutant-editor` appears before `adjutant-greeting` in the `extensions` array in `settings.json`.
- **INV-14** `harness-audit-gate.ts` must load after `guardrails.ts`. The audit gate reads state that guardrails sets; loading before guardrails causes the gate to evaluate against uninitialized state and may pass checks that should block. Check: `harness-audit-gate` appears after `guardrails` in the `extensions` array in `settings.json`.

## Context profile

- **INV-15** `profiles/` directory exists with all five profile files: `default.md`, `ntv.md`,
  `pi-harness.md`, `desktop.md`, `brainstorm.md`. Every `@` include inside each profile must
  resolve to an existing file on disk. Check: `harness-audit.sh` INV-15/15b.
- **INV-16** `~/.agents/standards/tool-policy.md` must remain as a direct `@include` in
  `AGENTS.md` (not delegated to a profile file). It is the immutable safety core and must load
  in every profile. Check: grep AGENTS.md for `@.*tool-policy.md`.
- **INV-17** If `contextProfile` is set in `settings.json`, its value must be one of the five
  known profile names. The `PI_PROFILE` env var takes priority over this key at runtime.
  Check: `harness-audit.sh` INV-17. Note: changing either key mid-session has no effect; the
  system prompt is fixed once a session starts. A session restart is required for any profile
  change to take effect.

**Ancestor injection caveat (documented limitation):** Pi core injects AGENTS.md files from
ancestor directories (`/AGENTS.md`, `/home/codeweaver/AGENTS.md`) as plain text before
`context-resolver.ts` runs. These files contain NTV project overview, skills list, and tool
safety pointers that `context-resolver.ts` cannot suppress. Profile selection controls only
the `~/.pi/agent/AGENTS.md` layer. For a truly minimal brainstorm context, the NTV skills
list and project overview from `/AGENTS.md` will still be present. This is a pi-core
limitation, not addressable at the extension layer.

**Origin:** this mechanism was first attempted 2026-07-10 — a worker claimed all 9 plan tasks
complete and a reviewer passed it, but only the `profiles/` content files (task 1) had actually
landed; AGENTS.md, context-resolver.ts, settings.json.example, and harness-audit.sh were
untouched. Caught during a later unrelated session when the user asked how to select a profile.
This is the canonical example motivating INV-13 — verify subagent claims, don't trust them.
