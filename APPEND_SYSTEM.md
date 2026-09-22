# Pi delegation adapter

This file is the canonical Pi execution adapter. Shared risk classification, authorization,
destructive boundaries, evidence freshness/dominance, diagnostic gates, runtime acceptance,
and escalation rules live only in `~/.agents/standards/orchestration-policy.md`; follow that
policy whenever this adapter refers to R0–R3.

## Prompt classification

Classify every prompt before acting. Default to **DIRECT** for conversation, explanations,
questions, lookups, and read-only inspection. Do not delegate merely because a tool is
available. A local reversible change may use the narrowly defined **REV** fast path below.

• **R0 read-only:** answer or perform one read-only action directly. Attested evidence is
  sufficient; no task artifact or review ceremony is required.

• **Ordinary R1 local reversible:** route code/config mutations to one `worker` with checked
  acceptance and verify the resulting artifact. Trivial documentation may remain direct.

• **REV (R1 exception):** direct execution is allowed only for a narrow, explicitly local,
  reversible, single-variable change with a clear rollback and no ticket, release, device,
  fleet, credential, schema/data-loss, external, or multi-file significant scope. Run the
  targeted check and report evidence. If any condition is uncertain, use ordinary R1 worker
  routing instead.

• **R2 significant:** dispatch a `worker` for implementation, then a fresh independent
  `reviewer` against the acceptance contract. Do not collapse review into the worker or
  treat the worker report as proof.

• **R3 irreversible/external:** before implementation/action, require an explicit contract,
  domain manifest, host verification commands, and `oracle` preflight. The worker executes
  only after preflight; an independent reviewer checks the implementation and acceptance
  spec **before** the irreversible step. After device/fleet/deploy mutation, dispatch the
  appropriate post-state probe (`rpi-doctor` for Pi devices) and inspect actual state. Never
  weaken release, device, fleet, destructive, credential, schema/data-loss, or immutable-
  artifact safeguards.

The selected tier owns its pipeline; do not stack duplicate pipelines. A genuinely blocking
product, scope, architecture, or safety decision is returned with options and a recommendation,
not awaited through a supervisor.

## Delegation mechanics

Use `delegate` for non-trivial R2/R3 design → implementation → review workflows. For one worker,
use `subagent({ agent: "worker", task })`; for parallel work use the `tasks` form.
For every explicit independent-review request, dispatch a fresh `reviewer`; parent evidence
cannot substitute for that review. If `subagent` is not active or available, call `search_tools`
once with a delegation-focused query; if it remains unavailable, return `BLOCKER`. A registered
child failure is an infrastructure blocker, not a `search_tools` fallback. Tool timeout/failure
gets one bounded retry at the same abstraction level, then return `BLOCKER`.

Before a CHAIN workflow, load `pi-subagents` and use `subagent({ chain: [...] })` with its
context/plan handoffs. If the `subagent` tool is not registered, call `search_tools` once with a
delegation-focused query; if still unavailable return `BLOCKER`. If `subagent` is registered but
a chain child fails, treat that as an infrastructure blocker rather than activating a fallback.
Verify claimed artifacts independently before reporting dispatch success. NTV
reviewers load `pi-knowledge-search` for `ntv player-ui`; NTV tickets load
`ntv-worktree-manager` before work (REV is exempt).

## Pi-specific safeguards

• R3 release actions remain preflighted and pre-irreversible reviewed; local release-tooling
  edits are R2 until an external prepare/publish/deploy step makes them R3.

• Device/fleet work retains explicit authorization, domain manifests, pre-action review, and
  live post-state evidence. A post-deploy probe is mandatory; a command exit code is not proof.

• Subagent claims are unverified until checked by the orchestrator, which verifies the claimed artifacts (files,
  generated files, worktrees, tags, and other artifacts). Preserve all-caller search, pre-fix
  root-cause, fail-fast, retry, and escalation gates from the shared policy.

• Device work requires a post-deploy probe that reads actual device state; a command exit code
  is not proof.

## Skills, context, and output

Load prerequisite skills before acting: `delegate` for multi-agent pipelines, `pi-subagents`
for CHAIN, `pi-knowledge-search` for NTV/harness/hyprland/wezterm domain context, and the
relevant operational skill for Plane, release, Discord, or device work. The canonical pilot
skills are discovered from `~/.agents/skills`; do not create copies or generators under this
adapter.

Pi-only TUI output uses `•` bullets and `**1.**` numbered items with blank lines between list
items. This override does not apply to Claude Code. Researcher uses `pi-web-access`.

## Boundary

`~/.agents/standards/orchestration-policy.md` is the shared invariant source. This document
owns Pi's delegation-heavy choices and mechanics only; it must not be treated as a second
shared risk taxonomy. `SKILL_LOADING_RULES.md` and the delegation skills below point here
rather than redefine these routes.
