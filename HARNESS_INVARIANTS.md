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
| orchestrator (`settings.json`) | `anthropic/claude-haiku-4-5` | `low` | cheap, cached, reliable dispatch |
| `worker` | `anthropic/claude-sonnet-4-6` | **`medium`** | executor — planner already reasoned; high over-anchors + burns 2–5x tokens |
| `tui-worker` | `anthropic/claude-sonnet-4-6` | **`medium`** | executor (same as worker) |
| `planner` | `anthropic/claude-sonnet-4-6` | `high` | reasoning role — thinking belongs here |
| `session-auditor` | `minimax/MiniMax-M3` | `high` | cheap-tier bulk audit |
| `linux-doctor` | `google/gemini-3.1-pro-preview-customtools` | inherit (`low`) | diagnostics |
| `oracle` | `anthropic/claude-sonnet-4-6` | `high` | reasoning/review — fork context analysis |
| `researcher` | `google/gemini-3.1-pro-preview-customtools` | `medium` | web research + synthesis — Gemini strong on search tasks |
| `context-builder` | `anthropic/claude-sonnet-4-6` | `medium` | codebase analysis + handoff meta-prompt — code-heavy, Claude edge |
| `delegate` | inherit (orchestrator default) | inherit (`medium`) | lightweight dispatch, inherits parent |
| `reviewer` | `anthropic/claude-haiku-4-5` | `medium` | read-only gate — Haiku sufficient for verification |

- **INV-1** orchestrator pinned `defaultProvider=anthropic`, `defaultModel=claude-haiku-4-5`, `defaultThinkingLevel=medium`. Check: `grep settings.json`.
- **INV-2** `worker` + `tui-worker` are `thinking: medium` (NOT high). Check: frontmatter grep.
- **INV-3** `planner` is `thinking: high`. Check: frontmatter grep.
- **INV-4** every agent's `model:` matches the table (oracle, worker, tui-worker, planner, session-auditor, linux-doctor have explicit pins). Check: frontmatter grep.

## Delegation behavior

- **INV-5** No agent instructs a subagent to **block on a supervisor** — subagents are autonomous by default and **return** genuinely-blocking decisions in their result (options + recommendation). Blocking decisions are surfaced in the result, never waited on. Check: agent `.md` files contain "NEVER block" language and no "wait for reply" patterns.
- **INV-6** Agent autonomy: subagents do not block waiting for supervisor feedback. Genuinely-blocking decisions are surfaced in agent results with options + recommendation; the orchestrator/user decides and re-dispatches if needed. This constraint is enforced in agent `.md` documentation and validated during review.
- **INV-7** Providers are utilized, none idle by design: anthropic (orchestrator + worker/planner/tui-worker/oracle/context-builder), google (linux-doctor/researcher), minimax (session-auditor).

## Cost observability

- **INV-8** `cost-tracker.ts` footer aggregates subagent cost via `parentSessionId` (subagents run as separate processes with their own sessionId — the OLD filter on `sessionId` matched 0 and under-reported ~3x). Check: `grep parentSessionId extensions/cost-tracker.ts`.
- **INV-9** Footer total must match the **raw ground truth**: sum of `.message.usage.cost.total` across the parent `session.jsonl` + every subagent `*/run-*/session.jsonl`. Validate once per fresh session; reconcile periodically (session-auditor task). Do not trust the footer blind.

## Process discipline

- **INV-10** Review-as-default-gate: mutating / irreversible / destructive work (edits, deploys, device imaging) is reviewed against an acceptance spec **before** the irreversible step — not on user request. Review without a spec is theater; review checks a manifest (see `PRODUCTION_READY_MANIFEST.md` for the device case).
- **INV-11** Verify outcomes, not operations: tool exit 0 ≠ task success. Inspect the produced artifact against its acceptance criteria; report verified-vs-assumed, never present mechanical success as semantic success.
- **INV-13** Subagent success claims are unverified until the orchestrator confirms the claimed artifacts exist (files on disk, worktrees/tags in git, objects on S3). A result message is a claim, not evidence. Origin: `session-20260702-incomplete-worktree-dispatch` tag in player-server — worker claimed 2 worktrees + build zips; reality had 1 worktree and 0 zips. For device deployments this extends to a post-deploy probe of actual device state (rpi-doctor). Check: APPEND_SYSTEM.md Post-Mutation Review Gate contains the verification + probe clauses.

## Extension load order

- **INV-12** `adjutant-editor.ts` must load before `adjutant-greeting.ts`. Greeting reads editor state established by the editor extension; if editor loads after, the greeting renders against an uninitialized context. Check: `adjutant-editor` appears before `adjutant-greeting` in the `extensions` array in `settings.json`.
- **INV-14** `harness-audit-gate.ts` must load after `guardrails.ts`. The audit gate reads state that guardrails sets; loading before guardrails causes the gate to evaluate against uninitialized state and may pass checks that should block. Check: `harness-audit-gate` appears after `guardrails` in the `extensions` array in `settings.json`.
