---
name: delegate
description: "Pi's R2/R3 delegation recipe; role selection is owned by ~/.agents/roles/execution.md."
---

# Pi delegation recipe

Read `~/.agents/roles/execution.md` for shared roles and
`~/.agents/adapters/pi.md` for Pi-specific mechanics. Shared invariants live in
`~/.agents/standards/orchestration-policy.md`. Use this recipe when a multi-agent
workflow is selected; it does not mandate worker routing for every local edit.

## R2

Dispatch one `worker` with a checked acceptance contract, then a fresh independent
`reviewer` against the contract and resulting artifact. Never treat the worker report as
proof and never collapse the review into the worker.

## R3

Require a plan/contract and domain manifest, run `oracle` preflight before action, dispatch
the worker only after preflight, and obtain independent review against the acceptance spec
before an irreversible step. Probe actual device/fleet post-state afterward. Use the
`delegation-airlock` skill for audited cross-repository or R3 work.

## Calls

```js
subagent({ agent: "worker", task: "..." })
subagent({ agent: "reviewer", task: "...", context: "fresh" })
subagent({ agent: "oracle", task: "..." })
```

For multi-step handoffs, load `pi-subagents` first and use its `subagent({ chain: [...] })`
form. If a genuinely blocking decision appears, return options plus a recommendation; do
not wait for supervisor feedback. Verify claimed artifacts independently before reporting
success.
