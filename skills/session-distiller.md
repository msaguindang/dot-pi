---
name: session-distiller
description: Distill and summarize the current session into a durable handoff artifact for a future fresh session. Use when user says "distill this session", "summarize the session", "wrap up", "create a handoff", "I'm switching sessions", "context is about to be lost", or before starting a new session that continues the current work.
allowed-tools: Bash Write
---

## Purpose

Write a compact, dense handoff markdown file to `/tmp/handoffs/<slug>.md` capturing everything a fresh session needs to continue this work without re-reading the conversation.

---

## Trigger Conditions

- User says: distill / summarize / wrap up / create a handoff / switching sessions / context about to be lost / before /clear
- User is about to start a new session continuing current work
- Context window is nearing saturation and work is unfinished

---

## Step 1 — Derive Slug

Pick a short kebab-case slug (2–5 words) from the dominant topic of the session.
Examples: `ntv-player-auth-fix`, `pi-skill-refactor`, `db-migration-debug`

---

## Step 2 — Ensure Output Directory Exists

```bash
mkdir -p /tmp/handoffs
```

---

## Step 3 — Compose the Handoff

Write dense bullet-point content. No filler, no prose padding, no full tool-output dumps — conclusions only.

Use this exact structure:

```markdown
# Handoff: <slug>
_Distilled: <ISO timestamp>_

## Current State
- <1–3 bullets: where work stands right now — what is done, what is half-done>

## Key Decisions (with Rationale)
- **<Decision>**: <why — the constraint or evidence that drove it>

## Verified Facts / Root Causes
> Distinguish clearly from assumptions.
- **CONFIRMED**: <fact verified by tool output, test result, or explicit user statement>
- **ASSUMED**: <plausible but not yet verified>

## Open Risks / Unresolved Questions
- <risk or question> — recommended action: <what to do>

## Concrete Next Steps
1. <first action — specific enough to execute without re-reading the session>
2. <second action>
...

## Artifacts & File Paths
- `<path>` — <what it is / current status>
```

---

## Distillation Rules (apply these while composing)

- **Decisions + rationale over raw transcript.** Why > what.
- **Separate CONFIRMED from ASSUMED explicitly.** Never conflate them. Assumptions that were never verified must be labeled ASSUMED.
- **Reference file paths instead of duplicating content.** If an artifact was produced, name its path and state — do not inline its full contents.
- **No tool output dumps.** Only the conclusion drawn from the output.
- **Do not fabricate.** If the session did not cover something, omit it. Do not fill gaps with plausible guesses.
- **Token-efficient.** Each bullet must carry signal. Remove adjectives and qualifiers that add no information.
- **Next steps must be executable.** A next step like "continue work" is invalid. Specify the file, command, or decision needed.

---

## Step 4 — Write the File

Write the composed content to `/tmp/handoffs/<slug>.md`.

---

## Step 5 — Report to User

Reply with:
- Exact path written: `/tmp/handoffs/<slug>.md`
- One-line summary of what the handoff covers
- Reminder: load this file at the start of the next session with `read /tmp/handoffs/<slug>.md`
