# Pi runtime for the Adjutant harness

Personal instructions are authored in `~/.agents`, shared with Claude Code, OpenAI
Codex and Antigravity CLI. This repository owns Pi's extensions, settings, runtime
profiles and Pi-specific skills, not a second personal policy.

## Instructions

`~/.agents/scripts/sync-instructions.py --write` generates this repository's
`AGENTS.md` and compatibility `APPEND_SYSTEM.md`. Edit the canonical sources in
`~/.agents` instead of generated entries. Check deployment without writing:

```bash
python3 ~/.agents/scripts/sync-instructions.py
```

Shared roles are defined in `~/.agents/roles/execution.md`; Pi tool mechanics are in
`~/.agents/adapters/pi.md`. This supersedes the former mandatory worker/R1 and REV
routing in APPEND_SYSTEM. General assistants execute directly; an explicitly selected
supervisor coordinates workers. Independent review and operational safeguards remain
in the shared policy. See `~/.agents/README.md` for setup, ownership and boundaries.

## Pi context profiles

The existing `extensions/context-resolver.ts` adds profile context and expands Pi
include lines. `PI_PROFILE` wins over `settings.json`'s `contextProfile`; default is
`default`. Supported profiles: `default`, `ntv`, `pi-harness`, `desktop`, `brainstorm`.
Profiles add relevant context; none disables the shared safety and role instructions.
Restart for instruction changes. An OpenAI or Gemini model selected inside Pi still
uses Pi's tools and configuration, not the native Codex or Agy harness.

## Models and extensions

The main model is selected in `settings.json` or through Pi's model controls; it is
not pinned by the shared harness. Per-worker overrides remain in `agents/*.md` and
installed dispatch packages. Inspect current configuration rather than this README
for available models. No credentials or model settings are changed by instruction sync.

Extensions load through `settings.json`; a `-` prefix disables one. `context-resolver`
loads profile context, `guardrails` supplies runtime checks, and `tool-loader` discovers
registered tools. Confirm availability before depending on an extension. Skills and
scripts have their own domain prerequisites; see `SKILL_LOADING_RULES.md`.

## Verification and source control

Run relevant tests under `tests/` after changing the corresponding extension. For
instruction deployment, the isolated Python tests live under `~/.agents/tests/`.
Existing Pi hooks and extensions are not ported to native runtimes by shared Markdown.
Native tool permissions and guardrails must be evaluated separately.

Keep authentication, sessions, run history, caches and machine-local settings out of
commits. The separately managed personal context repository is private. The instruction
migration does not replace Firstmate's runtime records or watches.
