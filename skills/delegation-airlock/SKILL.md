---
name: delegation-airlock
description: Orchestrates safe, auditable delegation of code changes to subagents — pre-work task spec with checkable acceptance criteria, scope-fence validation, independent parent verification, dedicated reviewer dispatch, and recovery patterns for scope creep or blockers. Use when asked to "airlock this", "delegate with criteria", "safe delegation", "dispatch a worker", "scope fence this task", or before any subagent code mutation (fix branches, refactors, script edits, config changes).
---

# delegation-airlock

Every code mutation delegated to a subagent passes through an airlock: a
validated task file goes in, independently verified evidence comes out.
Nothing is trusted on the worker's word alone.

Pipeline: **task file → validate → dispatch worker → parent verify → dispatch reviewer → (recover if needed)**.

## Default Trigger — Don't Wait to Be Asked

This pipeline is the agent's own default initiative for non-trivial planning
and mutation work — not something invoked only when the user says "have
scout look at it" or "dispatch a worker for this". Two triggers apply
automatically, without being asked:

1. **Before drafting an implementation plan** for a non-trivial ticket or
   task, dispatch a scout / Explore-type read-only subagent to analyze the
   relevant mechanism first. Plan from what the scout found, not from
   assumption.
2. **Before any code mutation, test run, or build/deploy action**, route
   through this airlock pipeline (task file → validate → worker → verify →
   review) — or, at minimum, dispatch a worker — by default for non-trivial
   work.

Exception: trivial, single-line, obviously-correct changes (typo fix,
one-line config value, comment update) don't need the full ceremony — use
judgement, don't spin up a four-step pipeline for a one-line diff. If it's
unclear whether a task is "trivial", it isn't — run the pipeline.

MUST, no exception: for any task file targeting release/build/QA-candidate/
deploy work — anything touching `ntv-release`, a QA-candidate directory, or
a script governed by `deploy-script-standard.md` — the task file MUST be
produced by `scripts/create-task.sh`. A hand-written task file for this
category is a hard stop, not "acceptable if validated" by
`delegation-validator` alone. Run `scripts/check-task-provenance.sh
<task-file>` before dispatch; a missing or malformed `generated_by` /
`generated_at` stamp means: stop, regenerate the file via `create-task.sh`,
do not dispatch a worker against it.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/create-task.sh [slug] [title] [count] [fence]` | Generates `/tmp/<slug>-task.md` from template, auto-runs delegation-validator |
| `scripts/check-task-provenance.sh <task-file>` | Confirms a task file carries the `generated_by`/`generated_at` stamp `create-task.sh` writes — catches hand-written task files before dispatch |
| `scripts/create-review.sh [slug]` | Generates `/tmp/review-<slug>-task.md`, copies criteria verbatim from task file |
| `scripts/verify.sh <slug> [--repo DIR] [--fence f1,f2] [--script PATH]... [--skip-push] [--allow-dirty]` | Parent verification; writes `/tmp/verify-<slug>-evidence.txt`; exits non-zero on any deviation |

Templates live in `templates/` (task-template.md, review-template.md).

## Step 1: Task File Creation

```bash
~/.pi/agent/skills/delegation-airlock/scripts/create-task.sh fix-content-route "Fix Content route null guard" 6 "src/routes/Content.ts"
```

Produces `/tmp/<slug>-task.md` with YAML frontmatter (`slug`, `title`,
`acceptance_count`, `scope_fence`) and sections: Context Files, Exact Changes,
Hard Scope Fence, Acceptance Criteria. Fill in the placeholders.

Rules:
- Absolute paths MANDATORY in the context list.
- No "as discussed above" — each criterion must stand alone.
- Each criterion objectively checkable, with an evidence type: code diff,
  git status, API response, or file presence.
- 6–17 criteria typical.

## Step 2: Validation

```bash
bash /home/codeweaver/.pi/agent/skills/delegation-validator/scripts/validate.sh /tmp/<slug>-task.md
```

Fix and re-validate on failure until exit code 0. `create-task.sh` runs this
automatically on the fresh skeleton; re-run after filling in the placeholders.

Known limitation: the validator catches relative-context phrases
("previously discussed", "as above", …) only. It does NOT catch relative
file paths, semantic vagueness ("fix the bug"), or unspecific scope fences —
review those by eye.

## Step 3: Dispatch Worker

- `context: fresh` — no prior conversation.
- Explicit timeout (default 10 minutes; tune per task complexity).
- Instruction:

> Read `/tmp/<slug>-task.md` and implement exactly. Return structured
> results: Implemented / Changed files / Validation (criterion-by-criterion
> check) / Open risks / Recommended next step / Mutated: yes|no /
> Risk level (low|medium|high).

Worker MUST NOT modify the task file or acceptance criteria.

## Step 4: Parent Verification (BEFORE review dispatch)

Never trust the worker report alone. Run:

```bash
~/.pi/agent/skills/delegation-airlock/scripts/verify.sh <slug> \
  --repo /path/to/repo \
  --fence src/routes/Content.ts,package.json \
  --script /path/to/edited-script.sh
```

Checks performed (evidence logged to `/tmp/verify-<slug>-evidence.txt`,
timestamped, deviations highlighted, exit non-zero on any failure):

| Check | Command |
|---|---|
| Committed | `git status --short --branch` (dirty tree = fail unless `--allow-dirty`) |
| Commit message matches scope | `git log --oneline -1` (logged for eyeball check) |
| Mutated files within fence | `git show --name-only HEAD` vs `--fence` list |
| Pushed | `git ls-remote origin` contains local HEAD (skip: `--skip-push`) |
| Script syntax | `bash -n <path>` per `--script` |

For integrations, additionally re-check live state manually (Plane ticket
state, Confluence page content) — external API checks are not automated.

If verification fails: dispatch a dedicated revert-worker to restore HEAD
state (recovery pattern b), then re-dispatch a fresh worker.

## Step 5: Reviewer Dispatch

```bash
~/.pi/agent/skills/delegation-airlock/scripts/create-review.sh <slug>
```

Produces `/tmp/review-<slug>-task.md` with: acceptance criteria copied
VERBATIM from the task file, code-style reference
(`/home/codeweaver/.agents/standards/code-style.md`), a criterion checklist
with `[PASS/FAIL/BLOCKER]` placeholders, and a section to paste the worker
report summary (include commit hashes).

Dispatch a fresh reviewer with:

> Read `/tmp/review-<slug>-task.md`. Do not modify files. Return a
> criterion-by-criterion acceptance report with line-number evidence
> (`<file>:<line>`) for each criterion. Verdict: PASS / FAIL / BLOCKER
> (with root-cause brief).

Parse the reviewer report by matching each numbered criterion to its
`<file>:<line>` evidence; any criterion without line-number evidence is
treated as unverified (FAIL).

## Step 6: Recovery Patterns

### (a) Reviewer BLOCKER on a PRE-EXISTING condition

Example: reviewer flags the sibling repo `player-ui` as dirty — but it was
dirty before the task was ever dispatched.

1. Parent captures baseline via `git status` BEFORE task dispatch (always).
2. On re-dispatch, write an evidence block at the top of the task file:
   ```
   Pre-existing (baseline captured 2026-07-16T09:00:00+08:00, before dispatch):
    M src/legacy/old-widget.ts
   ?? scratch-notes.txt
   ```
3. Re-frame the criterion as "No NEW mutations beyond baseline" — NOT
   "fix baseline".
4. Never dispatch out-of-scope cleanup.

### (b) Worker scope creep into unrelated files

Example: task said "Mutate only: src/routes/Content.ts" but `verify.sh`
shows `src/unrelated.ts` in `git show --name-only HEAD` → fence violation,
exit non-zero.

1. Dispatch a dedicated revert-worker with fresh context, task
   `/tmp/revert-<slug>-task.md`:
   - Scope fence: "Restore `src/unrelated.ts` to HEAD exactly. Do not touch
     other files."
   - Single criterion: "`git diff HEAD src/unrelated.ts` is empty"
2. Parent re-runs `verify.sh` to confirm clean.
3. Outcome: if clean, re-dispatch the reviewer on trimmed acceptance
   criteria (excluding the unrelated file); if not clean, repeat with a
   fresh revert-worker.

### (c) Parallel task dispatch collision

Each parallel task MUST have a distinct artifact path:
`/tmp/<slug-A>-task.md`, `/tmp/<slug-B>-task.md` — never both
`/tmp/task.md`. Same for review files. Both generator scripts refuse to
overwrite an existing file for this reason. Parent aggregates independent
verification results per task.

### (d) Detached / unresumable child

Worker context expires or the worker becomes unresponsive:

- Never attempt to rebase or resume the child.
- Re-dispatch a fresh worker with prior state passed EXPLICITLY: commit
  hashes, remote URLs, working-tree state snapshot.
- The fresh worker re-reads `/tmp/<slug>-task.md` from scratch — no prior
  context assumption.

## Config Notes / TODOs (resolved conservatively from handoff ASSUMED items)

- Code-style reference `/home/codeweaver/.agents/standards/code-style.md`
  verified present 2026-07-16. TODO: re-verify if standards dir is
  reorganized.
- `delegation-validator/scripts/validate.sh` verified executable, bash-only
  (grep/tr), 2026-07-16. Do not modify it from this skill.
- `verify.sh` requires `git`. External CLIs (`aws`, Plane/Confluence API
  clients) are NOT assumed — live integration re-checks in Step 4 are
  manual. TODO: automate if a stable CLI becomes a hard dependency.
- Worker timeout default is 10 minutes — an untuned assumption. TODO: tune
  per-task after the first month of usage.
- No automated parsing of worker reports; the parent reads the structured
  response manually.
- Review file verdict is markdown placeholders, not a structured YAML
  `verdict:` field. TODO (future): add `verdict: PASS|FAIL|BLOCKER` to
  review frontmatter.
- `scripts/audit-trail.sh` (optional in handoff) not implemented — add when
  there are enough concurrent tasks in `/tmp` to need a summary table.
