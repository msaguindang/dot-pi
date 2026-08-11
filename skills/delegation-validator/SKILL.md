---
name: delegation-validator
description: Scans a subagent delegation task prompt for relative context references ("previously discussed", "as above", "the spec we agreed on") that may indicate a missing artifact attachment. Use before dispatching any subagent task to validate the prompt is self-contained.
---

# delegation-validator

A pre-dispatch guardrail skill that detects ambiguous relative references in delegation task prompts. Forked subagents receive only what is explicitly passed to them — references to "previously discussed" or "the spec we agreed on" are not valid across session boundaries.

## When to use this skill
- Before dispatching any `subagent()` call.
- When the task prompt may rely on context held only in the parent session.
- When you want to enforce self-contained delegation payloads.

## Suspicious Phrases

The skill scans for the following relative context indicators (case-insensitive):

| Phrase | Why it's a problem |
| :--- | :--- |
| `previously discussed` | Subagent has no prior session memory. |
| `as above` | Nothing is "above" in a forked context. |
| `as specified` | Spec must be inline or attached. |
| `as mentioned` | Subagent cannot retrieve prior mentions. |
| `the spec we agreed on` | Agreement exists only in parent context. |
| `the plan from earlier` | Plans must be passed as file attachments. |
| `per the prior` | No continuity across session boundaries. |
| `as you know` | Subagent's knowledge is reset to baseline. |
| `from before` | No continuity across session boundaries. |

## Workflow: Validate a Delegation Prompt

1.  **Compose the task prompt** as you normally would for a `subagent()` call.
2.  **Scan the prompt** for the suspicious phrases listed above.
3.  **Verify attachments**: For each phrase found, confirm the referenced information is either:
    *   Inlined in the task prompt.
    *   Passed as a file attachment (e.g., `/tmp/spec.md`).
4.  **Resolve warnings**: If no attachment exists, either:
    *   Materialize the spec to a file (`/tmp/...`) and pass the path.
    *   Inline the relevant content in the task prompt.
    *   Pause and ask the user to confirm scope before dispatching.

## Script: `scripts/validate.sh`

A helper script automates the scan. Pass the task prompt as a string or a file path:

```bash
# Scan an inline string
~/.pi/agent/skills/delegation-validator/scripts/validate.sh "Implement the spec as previously discussed."

# Scan a file
~/.pi/agent/skills/delegation-validator/scripts/validate.sh /path/to/task_prompt.md
```

Exit codes:
- `0`: No suspicious phrases found.
- `1`: Suspicious phrases found; prompt the user for confirmation.
- `2`: Invalid usage.

If the input is a file, the script also checks its YAML frontmatter for an
`output.path` (or `output.artifact_path`) field and warns — non-fatally — if
it's missing, since a task with no declared output location can lose its
artifact if the subagent's cwd differs from expected.

### Batch mode — output path collision detection

When dispatching a **parallel batch** of task files, validate them together
so two tasks can't silently declare the same output artifact path (last
writer wins, first task's output is lost with no warning):

```bash
~/.pi/agent/skills/delegation-validator/scripts/validate.sh --batch task-1.md task-2.md task-3.md
```

For each task file, it reads the YAML frontmatter's `output.path` /
`output.artifact_path` (flat `output.path: ...` or nested `output:\n  path: ...`),
resolves it to an absolute path (`~` expanded; relative paths resolved
against the task file's own directory), and fails if any two files resolve
to the same path — printing every task file + task id that collided.
A `${VAR}`-style path the script can't resolve is flagged as a warning
instead of silently treated as a collision candidate. A task file with no
`output.path` at all is warned (not failed) just like single-file mode.

```
ERROR: Output path collision detected!
  Task PV1-4 (task-plane-update-1.md): /tmp/plane-response.json
  Task PV1-5 (task-plane-update-2.md): /tmp/plane-response.json
Recommendation: change all but one task's output.path to a unique file.
```

Exit codes (batch mode):
- `0`: all declared output paths are unique (missing/unresolvable paths only warn).
- `1`: a collision was detected, or a task file couldn't be read.
- `2`: invalid usage (`--batch` given with no task files).

## Script: `scripts/validate_handoff.sh`

Lints a handoff document (markdown file) against `~/.agents/standards/handoff-doc-standard.md`. Use before treating any handoff doc as ready for takeover, or after writing one.

```bash
~/.pi/agent/skills/delegation-validator/scripts/validate_handoff.sh /path/to/handoff.md
```

Checks (all parsed live from the standard — no hardcoded section list, so it stays correct as the standard evolves):
1. **Required sections present** — whatever the standard's "Required Sections (in order)" list currently contains (e.g. Ignition Block, Current State, Key Decisions with Rationale, CONFIRMED vs ASSUMED, Open Risks, Concrete Next Steps, Artifacts & Paths). Matches by heading keyword, so it tolerates minor heading-text variation and a CONFIRMED/ASSUMED section expressed as one heading or two.
2. **CONFIRMED items carry an evidence-source indicator** — each bullet under CONFIRMED must have an `evidence_source:` tag (per `tool-policy.md` §4), an inline "Evidence:" citation, a `file:line`/"line N" reference, a commit hash, a URL, or a screenshot reference. ASSUMED bullets are not required to have one.
3. **No relative paths** — flags `./`, `../`, and `~/` anywhere in the doc (the standard requires absolute paths only).

Exit codes:
- `0`: doc meets the standard.
- `1`: one or more lint failures (missing sections / unlabeled CONFIRMED items / relative paths) — printed with line numbers.
- `2`: invalid usage, unreadable file, or the standard's section list could not be parsed.
