# Skill Loading Rules (Pi adapter)

`APPEND_SYSTEM.md` is the canonical Pi routing adapter. Load a governing skill before acting;
these rules describe prerequisites and discovery, not a second risk taxonomy. Shared risk,
authorization, evidence, diagnostic, and escalation invariants are in
`~/.agents/standards/orchestration-policy.md`.

## Prerequisites

| Before acting | Load first |
|---|---|
| R2/R3 design → implementation → review | `delegate` |
| Any `subagent()` CHAIN | `pi-subagents` |
| Complex subagent prompt | `delegation-validator` |
| NTV, harness, Hyprland, or WezTerm domain work | `pi-knowledge-search` |
| NTV ticket/feature/bug | `ntv-worktree-manager` (REV is exempt) |
| Plane task query | `plane-tasks` |
| Raspberry Pi deployment | `rpi-deploy` (and `rpi-doctor` when post-state diagnosis is needed) |
| Session start/end | `session-clock-in` / `session-clock-out` |

`session-clock-out` chains to `work-log-writer`; `delegation-validator` is meaningful only
with a candidate prompt; `work-log-writer` is not loaded standalone. NTV PR review uses
`ntv-pr-reviewer`, which requires `pi-knowledge-search` for player-ui context.

## Invocation reference

Skills are slash commands: `/delegate`, `/pi-subagents`, `/delegation-validator`,
`/pi-knowledge-search`, `/ntv-worktree-manager`, `/plane-tasks`, `/rpi-deploy`,
`/rpi-doctor`, `/ntv-pr-reviewer <commit-or-branch>`, `/session-clock-in`, and
`/session-clock-out`. The canonical pilot skills (`jot`, `start-day`, `session-log`) are
auto-discovered from `~/.agents/skills`; do not copy them into this harness.

For detailed delegation, airlock, worktree, and device mechanics, read the corresponding
skill. Route selection itself remains solely in `APPEND_SYSTEM.md`.
