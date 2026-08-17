# Skill Loading Rules

Reference card for skill prerequisites, load order, and invocation. Load skills explicitly — do not rely solely on auto-trigger descriptions.

---

## Rule: Load Before Acting

Skills must be loaded **before** the task they govern, not after. Loading mid-task doesn't retroactively apply the skill's constraints to work already done.

---

## Skills That Are Prerequisites for Agent Dispatch Patterns

| Before doing this... | Load this skill first | Why |
|---|---|---|
| Any R2/R3 multi-agent pipeline (design → implement → review) | `delegate` | Defines the Phase 1/2/3 gate structure mapped to R2/R3 tier policies; without it, orchestrator improvises the pipeline incorrectly |
| Dispatching any `subagent()` chain | `pi-subagents` | Chain syntax (`subagent({ chain: [...] })`) is only available after this skill is loaded |
| Dispatching any subagent with a complex task prompt | `delegation-validator` | Scans the prompt for relative context references that will silently fail in forked sessions |
| Any NTV domain question, harness question, hyprland, or wezterm | `pi-knowledge-search` | Context is NOT auto-loaded — LLM has no NTV-specific facts without it |
| Starting work on any NTV ticket, feature, or bug fix | `ntv-worktree-manager` | Creates synchronized worktrees across NTV repos before any code touches the filesystem |
| Any Plane ticket query or status update | `plane-tasks` | Provides Plane API access and NTV project IDs |
| Morning session start / briefing | `session-clock-in` | Restores handoff state from `~/.agents/state/handoffs/`; without it the session starts blind |
| Session end / wrapping up / day log | `session-clock-out` | Chains to `work-log-writer`; write the handoff correctly before clearing context |
| Any NTV PR review | `ntv-pr-reviewer` | Parallel 6-agent review; without the skill the orchestrator improvises a single-pass review |
| Deploying to a Raspberry Pi device | `rpi-deploy` | Enforces preflight checks (right branch, clean tree), confirmation gate, post-deploy verify |
| Imaging an SD card or prepping a Pi for cloning | `rpi-imager` | The scripts are headless and self-verifying — the skill explains the one-shot contract |

---

## Skill Dependency Order

Where one skill's workflow depends on another being loaded first:

```
session-clock-out
  └─ work-log-writer       (chains automatically — invoked by clock-out)

delegate
  └─ delegation-validator  (load both when using the delegate pipeline)
  └─ pi-subagents          (required for CHAIN tier inside delegate)

ntv-pr-reviewer
  └─ pi-knowledge-search   (NTV reviewer agents must load domain context — see APPEND_SYSTEM.md)

rpi-deploy
  └─ rpi-doctor            (optional — run if post-deploy verify fails to diagnose device state)
```

---

## Invocation Reference

All skills are invoked via slash command in a pi session:

| Skill | Slash Command | Notes |
|---|---|---|
| `delegate` | `/delegate` | Multi-agent pipeline mapped to R2/R3 tiers |
| `delegation-validator` | `/delegation-validator` | Pass the draft subagent prompt inline after the command |
| `discord-eod-fetcher` | `/discord-eod-fetcher` | Manual fetch trigger; normally runs via systemd timer |
| `gmail` | `/gmail` | Requires `gmail.ts` extension enabled and OAuth configured |
| `internal-comms` | `/internal-comms` | Prompts for communication type, then loads relevant template |
| `ntv-pr-reviewer` | `/ntv-pr-reviewer <commit-or-branch>` | Parallel 6-agent PR review |
| `ntv-worktree-manager` | `/ntv-worktree-manager` | Prompts for ticket ID, type, description, repos |
| `pi-knowledge-search` | `/pi-knowledge-search` | Pass search query as argument |
| `plane-tasks` | `/plane-tasks` | Fetch/filter/update Plane issues |
| `repo-onboarder` | `/repo-onboarder` | Pass repo path or run from repo root |
| `research-with-persistence` | `/research-with-persistence` | Persists researcher output to `/tmp/pi-research/<slug>.md` |
| `rpi-deploy` | `/rpi-deploy` | Args: `<branch> <env> <ui\|server\|both>` |
| `rpi-doctor` | `/rpi-doctor` | Pass device alias or IP + symptom description |
| `rpi-imager` | `/rpi-imager` | Headless — invoke once, read one structured JSON summary |
| `session-clock-in` | `/session-clock-in` | Morning briefing; reads `~/.agents/state/handoffs/` |
| `session-clock-out` | `/session-clock-out` | Saves handoff state, chains to `work-log-writer` |
| `subagents-list` | `/subagents-list` | Renders colored agent card grid in TUI |
| `ticktick` | `/ticktick` | Task management via local TickTick CLI |
| `weekly-report-compiler` | `/weekly-report-compiler` | Compiles week's logs → Obsidian + .docx |
| `weekly-report-generator` | `/weekly-report-generator` | Synthesizes raw logs into management-friendly report |
| `work-log-writer` | `/work-log-writer` | Creates/updates today's Obsidian daily work log |

---

## Never Load These in Isolation

- `work-log-writer` — always invoked through `session-clock-out`; standalone use skips the handoff state capture
- `delegation-validator` — meaningless without a candidate subagent prompt to validate; always pair with an actual dispatch
