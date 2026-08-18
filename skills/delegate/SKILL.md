---
name: delegate
description: "Use this skill when a task requires multi-agent delegation: design, implementation, and review."
---

Use this optional recipe for non-trivial tasks (multi-file edits, new features, refactors) mapping to R2 or R3 tiers. Skip for quick lookups, single-line fixes, and DIRECT/R1 responses.

## Pipeline by Tier

**R2 (Significant)**
- One `worker` to execute the changes.
- One independent `reviewer` to verify the diff against standards and domain criteria.
- (Optional) `planner` only if the task is complex enough to need a roadmap first.

**R3 (Irreversible/External)**
- (Required) `planner` to draft the implementation plan.
- (Required) `oracle` pre-flight review of the plan.
- `worker` to execute the plan.
- (Required) `reviewer` to verify the execution BEFORE the irreversible action.
- (Required) Post-state live probe.
- Domain manifests are mandatory.

## Tool Invocations

Each phase maps to a `subagent()` call. Use chain form only when automatic context handoff between steps is required.

**Dispatch Planner (if needed)**

```js
subagent({
  agent: "planner",
  task: "Produce a step-by-step implementation plan for the following task. Include exact file paths, the change required at each file, and a verification command per step. Output the plan only — no code.\n\nTask: <your task description here>"
})
```

**Dispatch Oracle Pre-flight (R3 only)**

```js
subagent({
  agent: "oracle",
  task: "Pre-flight: check the plan below against the task's acceptance criteria / relevant manifest for spec violations, missing edge cases, or incorrect assumptions. Output your Verdict (PASS/FAIL) with per-criterion findings.\n\nAcceptance criteria / manifest:\n<paste manifest path or criteria>\n\nPlan:\n<paste planner output verbatim here>"
})
```

**Dispatch Worker**

```js
subagent({
  agent: "worker",
  task: "Execute the following implementation plan exactly. One commit per logical unit. Self-review before each commit. Do not summarize — implement.\n\nPlan:\n<paste approved plan verbatim here>"
})
```

**Dispatch Reviewer (One pass for R2/R3)**

```js
subagent({
  agent: "reviewer",
  task: "Review the diff for correctness, error handling, adherence to standards/code-style.md, and compliance with the plan/domain manifest. Output your Verdict (PASS/FAIL) with per-criterion findings.\n\nPlan/Criteria:\n<paste plan/criteria>\n\nDiff:\n<paste git diff output>"
})
```

**When to use `subagent()` chain form instead**

Use `subagent({ chain: [...] })` (requires loading `pi-subagents` skill first) when:
- The pipeline needs automatic `context.md` / `plan.md` handoff written to disk between steps
- A step requires `oracle` drift protection or `contact_supervisor` escalation mid-chain
- The full pipeline should run unattended in the background without manual relay of outputs

For interactive, supervised pipelines where you relay outputs between phases yourself, `subagent()` at each phase is sufficient and cheaper.

## Orchestrator rules

- Pass the full plan doc to Worker. Do not summarize.
- Pass the plan + diff to Reviewer. Do not summarize.
- If Reviewer fails: route back to Worker with specific failure reason. Re-review after fix.
- Never mark a task complete until Reviewer passes.
- Never write code as the orchestrator for R2/R3/non-REV tasks — always delegate to Worker (REV bypasses delegation).