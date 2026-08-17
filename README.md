# Pi Agent Harness

Portable configuration layer for [`pi`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) — the multi-agent coding CLI. This repo (`~/.pi/agent`) is the shareable half. Personal context lives in a separate vault (`~/.agents`).

**Model stack:** Claude Haiku 4.5 (orchestrator, medium-thinking) + Claude Sonnet 4.6 (workers/reviewers). Requires Anthropic API key.

---

## Prerequisites

- Node.js 18+
- `npm install -g @earendil-works/pi-coding-agent`
- Git
- Anthropic API key

---

## Quick Start

### 1. Clone harness

```bash
git clone <dot-pi-repo-url> ~/.pi/agent
```

### 2. Create personal context vault

The harness loads `~/.agents/` at every session start. This directory is **not** included — it is personal. Create it from scratch or use this repo's structure as a template.

```bash
mkdir -p ~/.agents/{context,standards}
```

Required files — write these yourself:

| File | Contents |
|---|---|
| `~/.agents/context/identity.md` | Your role, team, communication style, behavioral rules |
| `~/.agents/context/environment.md` | Your device paths, shell aliases, active technologies |
| `~/.agents/context/long-term.md` | Domain knowledge, project context, decision log |
| `~/.agents/standards/code-style.md` | Your project's commit format, language conventions |

### 3. Copy settings

```bash
cp ~/.pi/agent/settings.json.example ~/.pi/agent/settings.json
```

`settings.json` is gitignored — pi writes runtime state back to it on every session (last model used, changelog version, etc). The example file has a working starting default (`anthropic/claude-sonnet-4-6`, medium thinking, all extensions, Tokyo Night theme) — the orchestrator model is NOT pinned/enforced by the harness (INV-1 retired 2026-07-13); pick whatever fits your context-window and cost tradeoff. Copy the example once; pi owns it from there.

### 4. Set up providers

```bash
pi auth login
```

Log in to the providers you plan to use. At minimum:

- **Anthropic** — workers (`anthropic/claude-sonnet-4-6`); orchestrator model is your choice

To verify available models after login:

```bash
pi --list-models
```

### 5. Verify

```bash
pi --version
pi "hello"
```

---

## Repo Structure

```
~/.pi/agent/                        ← this repo (shareable)
├── AGENTS.md                       # context chain — loads ~/.agents/ files
├── APPEND_SYSTEM.md                # routing rules, TUI rendering, NTV domain gates
├── settings.json.example           # template — copy to settings.json on first setup (gitignored at runtime)
├── agents/                         # specialized sub-agents
│   ├── delegate.md                 # local override
│   ├── linux-doctor.md
│   ├── oracle.md                   # local override
│   ├── planner.md                  # local override
│   ├── reviewer.md                 # local override
│   ├── session-auditor.md
│   ├── tui-worker.md
│   └── worker.md                   # local override
├── extensions/                     # TypeScript extensions loaded at startup
├── skills/                         # slash-command skills
└── themes/                         # custom TUI themes

~/.agents/                          ← personal vault (your own repo, not shared)
├── context/
│   ├── identity.md
│   ├── environment.md
│   └── long-term.md                # stub router → long-term-*.md atomic notes
├── standards/
│   ├── code-style.md
│   └── tool-policy.md
└── state/                          # runtime state, lessons
```

---

## Context Loading Chain

`AGENTS.md` at startup loads (in order):

```
@~/.agents/standards/tool-policy.md          # immutable core — every profile
@~/.pi/agent/profiles/<active-profile>.md    # profile-gated domain context
```

`context-resolver.ts` expands `@`-includes recursively (profile files themselves contain `@` lines) and substitutes the active profile into the sentinel line before expansion.

`APPEND_SYSTEM.md` appends harness-specific rules after the above (routing policy, TUI rendering overrides, agent notes, and NTV domain gates). Note: canonical risk tier policies, pre-fix gates, and post-mutation review logic have moved to `~/.agents/standards/orchestration-policy.md`.

### Context Profiles

Domain context (identity, environment, NTV knowledge, Hyprland notes, etc.) is profile-gated so unrelated sessions (e.g. editing this harness, or brainstorming) don't carry NTV work context they don't need. Safety/tool-policy rules load in every profile regardless.

| Profile | Loads |
|---|---|
| `default` | identity, environment, generic long-term redirect, code-style |
| `ntv` | identity, environment, NTV v1 + v2 domain knowledge, code-style |
| `pi-harness` | identity, environment, pi extension patterns, code-style |
| `desktop` | identity, environment, Hyprland notes, code-style |
| `brainstorm` | identity only — minimal, for consultation/ideation sessions |

Select a profile before starting a session (profile selection is startup-time only — the system prompt is fixed once a session starts, so changing it mid-session has no effect):

```bash
PI_PROFILE=ntv pi
```

Or set a persistent fallback in `settings.json`:

```json
"contextProfile": "ntv"
```

`PI_PROFILE` always wins over `contextProfile`. Neither set → `default`.

**Caveat:** pi core injects ancestor-directory `AGENTS.md` files (`/AGENTS.md`, `~/AGENTS.md`) as plain text before `context-resolver.ts` runs. Profile selection controls only this harness's `AGENTS.md` layer — it cannot suppress ancestor project files, so `brainstorm`/`desktop` won't be fully context-free if an ancestor `AGENTS.md` exists.

---

## Model Routing

Orchestrator model is set in `settings.json` and is **not pinned by the harness** — switch freely (`/model` mid-session, or edit the file directly) based on your own context-window/cost/capability tradeoff. Worker/subagent models are set per-agent in `agents/*.md` frontmatter and ARE pinned (see `HARNESS_INVARIANTS.md`).

| Config | Controls | Enforced? |
|---|---|---|
| `settings.json` → `defaultProvider` + `defaultModel` | Orchestrator (main session model) | No — user's choice |
| `agents/<name>.md` → `model:` frontmatter | Per-agent model override for subagents | Yes — audited (INV-2/3/4) |

Subagent dispatch is handled via `APPEND_SYSTEM.md` routing rules. The orchestrator decides when to delegate based on prompt context — no automatic prompt classification is applied.

### Changing the model stack

**Orchestrator** — edit `settings.json` (any provider/model you're logged into):

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4-6"
}
```

**Per-agent worker model** — edit `agents/<name>.md` frontmatter:

```yaml
---
name: worker
model: anthropic/claude-sonnet-4-6
thinking: medium
---
```

Run `pi --list-models` to see available model IDs for your configured providers.

---

## Extensions

Loaded automatically at startup via `settings.json` `extensions` array.

| Extension | Purpose |
|---|---|
| `adjutant-editor.ts` | TUI editor layout config |
| `adjutant-greeting.ts` | Startup greeting with session context |
| `bash-truncator.ts` | Truncates oversized bash output to prevent context overflow |
| `context-resolver.ts` | Resolves `@`-includes in AGENTS.md at load time |
| `cost-tracker.ts` | Tracks per-turn + per-session token cost in TUI status bar |
| `extension-watcher.ts` | Detects stale extension cache, warns before long sessions |
| `first-run.ts` | One-time onboarding wizard on fresh installs |
| `gmail.ts` | Gmail API integration (requires Google OAuth) |
| `guardrails.ts` | Blocks or confirms destructive ops (SSH rm/reboot, npm publish) |
| `session-name-status.ts` | Shows active session name in TUI status bar |
| `tool-cache.ts` | Caches repeated tool results within a session |
| `tui-dryrun.ts` | ANSI validation guard — blocks TUI edits without dry-run verification |
| `atuin.ts` | *(disabled by default)* Tracks pi bash commands in [Atuin](https://github.com/atuinsh/atuin) history with author `pi`. Requires `atuin` installed and `atuin hook install pi` run. Enable by changing `-extensions/atuin.ts` to `+extensions/atuin.ts` in `settings.json`. |

To disable an extension, prefix its entry with `-` in `settings.json`:

```json
"-extensions/gmail.ts"
```

---

## Utilities

| Script | Purpose |
|---|---|
| `inf-run` (`~/.local/bin/inf-run`) | `inf-run <skill-name> <command...>` — runs a command with that skill's Infisical secrets injected, regardless of caller cwd. Skills don't carry their own `.infisical.json`; it walks up from `skills/<name>/` to the shared config at `~/.pi/agent/.infisical.json` and passes it via `infisical run --project-config-dir`, so no `cd` juggling is needed. Noise (update-available tip, `INF` injection log) is suppressed via `--silent --log-level warn` rather than output-grepping. |

---

## Skills

Invoke with `/skill-name` in a pi session.

### Generic (usable by anyone)

| Skill | Purpose |
|---|---|
| `delegate` | Planner → Reviewer → Worker → QA pipeline template |
| `delegation-validator` | Validates sub-agent prompts are self-contained before dispatch |
| `gmail` | Search, read, draft, send Gmail |
| `internal-comms` | Internal communication templates (status reports, incident reports) |
| `pi-knowledge-search` | Ripgrep search across `~/.agents/context/` atomic notes |
| `repo-onboarder` | Registers a new repo into the `~/.agents` context ecosystem |
| `research-with-persistence` | Researcher agent with file-based output for sub-agent handoff |
| `skill-creator` | Schema reference for building new pi skills |
| `subagents-list` | Lists all available sub-agents and their roles |
| `ticktick` | TickTick task management integration |

### NTV-specific (adapt or remove for other setups)

| Skill | Purpose |
|---|---|
| `discord-eod-fetcher` | Fetches EOD updates from NTV Discord into Obsidian |
| `ntv-pr-reviewer` | 6-agent parallel PR review for NTV repositories |
| `ntv-worktree-manager` | Git worktree creation across NTV mono-repo ecosystem |
| `plane-tasks` | Fetch/update Plane work items (uses Infisical for secrets) |
| `repo-onboarder` | NTV-scoped repo registration (paths hardcoded to `~/Projects/work/ntv`) |
| `rpi-deploy` | Deploy player-server/UI to Raspberry Pi via native gulp pipelines |
| `rpi-doctor` | SSH diagnostic tool for RPi fleet health checks |
| `rpi-imager` | Raspberry Pi OS imaging helper |
| `rpi5-deployer` | **Deprecated** — use `rpi-deploy` |
| `session-clock-in/out` | Work session logging to Obsidian daily notes |
| `weekly-report-*` / `work-log-writer` | NTV weekly report generation from session logs |

---

## Agents

Located in `agents/`. Invoked via `subagent({ agent: "<name>", task })`.

| Agent | Purpose | Model |
|---|---|---|
| `linux-doctor` | System-level diagnostics (OS, drivers, services) | gemini-3.1-pro-preview |
| `session-auditor` | Audits active session for context drift and constraint violations | MiniMax-M3 |
| `tui-worker` | Specialized worker for TUI extension edits with 4-layer test loop | sonnet-4-6 |

Package agents (from `npm:pi-subagents`, included automatically):

| Agent | Role | Model |
|---|---|---|
| `scout` | Fast codebase recon | — |
| `context-builder` | Deep analysis + meta-prompt for planning | anthropic/claude-sonnet-4-6 *(local override)* |
| `oracle` | Decision-consistency, drift protection | anthropic/claude-sonnet-4-6 *(local override)* |
| `planner` | Implementation planning | anthropic/claude-sonnet-4-6 *(local override)* |
| `researcher` | Web research + doc lookup | google/gemini-3.1-pro-preview-customtools |
| `reviewer` | Code, plan, and PR review | anthropic/claude-haiku-4-5 *(local override)* |
| `worker` | Implementation with supervisor escalation | anthropic/claude-sonnet-4-6 *(local override)* |
| `delegate` | Lightweight worker, inherits parent model | inherit orchestrator *(local override)* |

**Note:** `researcher` and `context-builder` are model-pinned via `agentOverrides` in `settings.json.example` and do not have local `.md` overrides in `agents/`.

---

## Customization

### Change the default model

Edit `settings.json`:

```json
{
  "defaultProvider": "google",
  "defaultModel": "gemini-2.5-pro"
}
```

### Add a personal agent

Create `~/.pi/agent/agents/<name>.md`:

```markdown
---
name: my-agent
description: What this agent does and when to invoke it.
model: openai-codex/gpt-5.5
thinking: high
---
# My Agent

System prompt content here.
```

### Add a skill

Create `~/.pi/agent/skills/<skill-name>/SKILL.md`:

```markdown
---
name: skill-name
description: One-line description used for auto-triggering.
---

# Skill Title

Skill instructions here.
```

Run `/skill-creator` for the full schema and validation guide.

### Change theme

```bash
pi theme set tokyonight   # or: dracula, nord, gruvbox, rose-pine, etc.
```

Or edit `settings.json` → `"theme"`.

---

## What NOT to Commit

Already in `.gitignore`, but worth knowing:

| Path | Reason |
|---|---|
| `settings.json` | Pi rewrites this every session (last model, changelog version) — use `settings.json.example` to ship defaults |
| `auth.json` | API credentials |
| `sessions/` | Session transcripts |
| `cost-history.jsonl` | Machine-specific cost data |
| `run-history.jsonl` | Runtime artifacts |
| `usage-data/` | Pi-insights reports |
| `logs/` | Debug logs |
| `intercom/` | IPC mailboxes |

Your personal `~/.agents/` vault is a separate repo — never accidentally commit it here.

---

## Updating

```bash
cd ~/.pi/agent
git pull
```

Extension changes take effect on next `pi` session start.
