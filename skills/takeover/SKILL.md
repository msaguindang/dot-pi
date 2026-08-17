---
name: takeover
description: Consumer-side counterpart to handoff-doc-standard.md. Takes over a session handoff document with verification rigor — confirms every ASSUMED claim against the live system before relying on it (trusting CONFIRMED claims as-is), checks the doc's Concrete Next Steps against current reality for drift, then reports a plan and stops for explicit approval before mutating anything, unless the doc's own Ignition Block authorizes proceeding without a checkpoint. Use when the user says "takeover <path>", "take over task found in <path>", "resume handoff <path>", "pick up the handoff at <path>", or hands off a handoff doc for continuation.
---

# Takeover

Producer-side rigor for handoff docs is `~/.agents/standards/handoff-doc-standard.md`. This skill is the consumer side: when an agent is handed one of those docs, taking it over follows the same procedure every time — not whatever the prompting agent happens to remember to check.

Read `~/.agents/standards/handoff-doc-standard.md` in full before using this skill if you have not already; the section names below (CONFIRMED/ASSUMED, Concrete Next Steps, Artifacts & Paths) are defined there.

---

## Step 1: Read the handoff doc

Read the full doc at the given path, start to finish, before doing anything else. Note the header's session/source provenance (which pi session produced it, distillation timestamp) — if that provenance is missing, flag it as a standard violation before proceeding, don't silently tolerate a malformed handoff.

---

## Step 2: Verify every ASSUMED claim

This is the core discipline of the skill — do not skip it, do not sample it.

**Context-cost note:** raw verification probes (full `cat`, full `git diff`, full `git log`) landing inline in the main session are the dominant cost of a takeover — bigger than the handoff doc itself on a wide context window. Do not run these probes inline. Dispatch them.

- Collect every ASSUMED claim from the doc into a single list.
- Dispatch `subagent({ agent: 'scout', task: 'Verify these claims against the live system. For each: state Confirmed / Stale (with what the live system actually shows) / Could-not-verify (no probe available). Use scoped commands — git diff --stat before full diff, grep -n for specific text before reading whole files, git log -3 --oneline not full log. Return only the three-list verdict, no raw command output. Claims: <list>' })`.
- For every item labeled **CONFIRMED** in the doc, trust it as-is — do not dispatch verification for these, re-checking already-confirmed facts defeats the purpose of the CONFIRMED/ASSUMED split.
- Any claim that reads as load-bearing but isn't labeled either way: treat it as ASSUMED (per `tool-policy.md` §4 — never act on an unconfirmed fact without surfacing it first) and include it in the dispatch.

Report the outcome as the three short lists scout returns: **Confirmed as expected**, **Found stale/wrong**, **Could not verify**. Do not re-paste scout's raw tool output into the session — the verdict lists are the deliverable.

---

## Step 3: Check Concrete Next Steps against current reality

The doc's "Concrete Next Steps" describe what was still outstanding when it was written — time has passed since then. Fold this into the same scout dispatch as Step 2 (one dispatch, not two) — add to its task:

- Check `git log`/`git status`/`git diff --stat` against the branches/paths the doc names.
- Check file/artifact existence at the paths under Artifacts & Paths.
- Any ticket/deploy state the doc references, if a live check exists.
- Return: steps already done, steps now impossible/irrelevant, steps still accurate as written.

If the doc has no ASSUMED claims but does have Concrete Next Steps needing drift checks (or vice versa), dispatch scout for whichever is non-empty — skip the dispatch entirely only if both are empty.

---

## Step 4: Report a plan, then stop

Before mutating anything, report:
- What Step 2 and Step 3 found (confirmed / stale / drifted).
- The plan you're about to execute, informed by that verified state — not by the doc's original next steps verbatim if reality has since diverged.

**Stop here and wait for explicit approval** — unless the doc contains its own **Ignition Block** (per the handoff-doc-standard's Ignition Block section) that explicitly authorizes proceeding without a checkpoint. If present, follow its authorization exactly as scoped; do not read silence or an unrelated section as authorization.

Treat any section in the doc titled "Ignition Block" (or explicit unattended-execution authorization) as the only valid trigger to skip the checkpoint. No Ignition Block present means always stop and wait, no exceptions.

---

## Step 5: Execute and close the loop

Once approved (or authorized per Step 4), execute strictly within the doc's scope. As work completes:

- Update the handoff doc's own progress/state (mark steps done, add discoveries, note new blockers) — this is what closes the loop the doc's Concrete Next Steps describe. Don't leave the source doc stale for the next agent.
- If scope creep or a new blocker surfaces mid-execution, stop and report it rather than improvising past the doc's stated scope.
