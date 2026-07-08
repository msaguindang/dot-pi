---
name: skill-creator
description: Create, edit, or audit pi coding agent skills. Knows pi skill schema, discovery locations, invocation syntax, and what separates a good skill from a bad one. Not for Claude Code skills — those use a different format and live in ~/.claude/skills/.
---

## Pi Skill Schema

Every pi skill is a markdown file with YAML frontmatter.

**Required fields:**
```yaml
---
name: kebab-case-name          # 1–64 chars, lowercase a-z, 0-9, hyphens only
description: one-line purpose  # max 1024 chars — used by pi to match skill to invocations
---
```

**Optional fields:**
```yaml
license: MIT
compatibility: Requires infisical running locally. Needs pi >= 0.75.0.  # max 500 chars
metadata:
  key: value                   # arbitrary — use for tool version pins, env requirements
allowed-tools: Bash Read Edit  # space-delimited — pre-approved tools, no confirmation prompt
disable-model-invocation: true # forces explicit /skill:name call; blocks contextual auto-trigger
```

---

## File Structure

**Flat file (preferred for simple skills):**
```
~/.pi/agent/skills/my-skill.md
```
Frontmatter + content in one file. Pi accepts this format.

**Directory-based (for skills with assets or scripts):**
```
~/.pi/agent/skills/my-skill/
  SKILL.md          ← required, uppercase
  scripts/          ← optional
  references/       ← optional
```
Use directory form only when the skill references external scripts or reference files.

---

## Discovery Locations (pi scans in this order)

1. `~/.pi/agent/skills/` — harness-global
2. `.pi/skills/` — project-local (up to git repo root)
3. `package.json` `pi.skills` entries — npm package skills
4. CLI: `pi --skill <path>` — session-only override

Place in `~/.pi/agent/skills/` if the skill should be available in every pi session.

---

## Invocation

```bash
/skill:name              # invoke by name
/skill:name some args    # invoke with arguments
```

Pi matches the `name` field exactly. Lowercase, hyphens, no colons in the name itself.

---

## Writing Effective Skill Content

A skill is injected as a system prompt fragment when invoked. Write it as instructions to the model, not as documentation.

**Good:**
- Starts with what the skill does and when to use it
- Encodes constraints, patterns, and non-obvious rules
- References exact file paths, tool names, command syntax
- Dense — the model should not need to look anything up

**Bad:**
- Introductory prose ("This skill helps you...")
- Vague guidance without actionable specifics
- Duplication of what the model already knows (language syntax, basic git commands)
- Missing `description` field — pi cannot match without it

**Description field matters most.** Pi uses it to decide when to auto-trigger the skill. Make it specific: say what the skill does AND what signals its use (e.g. "Use when creating pi extensions, auditing guardrails, or adding new tools to the harness").

---

## Checklist Before Saving

- [ ] `name` is lowercase kebab-case, no spaces
- [ ] `description` is under 1024 chars and specific enough for pi to match correctly
- [ ] Flat file unless scripts/references needed
- [ ] Placed in correct discovery location for intended scope
- [ ] Content starts with action, not prose
- [ ] `allowed-tools` set if skill always needs specific tools without confirmation

---

## Not Compatible With Claude Code

Pi skills use `SKILL.md` / flat `.md` with pi frontmatter. Claude Code skills use directory/`SKILL.md` format and live in `~/.claude/skills/` (registered as `claude-skills@claude-skills` plugin). Do not attempt to share files between the two systems.
