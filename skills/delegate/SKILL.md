---
name: delegate
description: "Pi's R2/R3 delegation recipe; route selection is owned by APPEND_SYSTEM.md."
---

# Pi delegation recipe

Read `APPEND_SYSTEM.md` for the canonical DIRECT/R0, ordinary R1 worker, REV, R2, R3, and
CHAIN routes, and `~/.agents/standards/orchestration-policy.md` for shared invariants. This
skill supplies the mechanics for non-trivial multi-agent work; it must not create another
risk taxonomy or weaken the adapter.

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
