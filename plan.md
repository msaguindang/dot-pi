# Implementation Plan

## Goal

Add startup-time context-profile selection to the pi harness so that the set of domain `@include` files injected into the system prompt is determined by a `PI_PROFILE` env var (or `settings.json` fallback key) before any agent turn begins, while keeping safety/tool-policy rules in every profile.

---

## Background Facts (from code inspection)

- `extensions/context-resolver.ts` fires on `before_agent_start`, receives `event.systemPrompt`, scans it line-by-line for `@path` directives, and expands them by inline-replacing with file content. Expansion is **single-pass** (files included via `@` inside an included file are NOT re-expanded).
- `AGENTS.md` (harness root) currently has 5 `@` lines: identity, environment, long-term, code-style, tool-policy. This is the only harness-controlled system-prompt file. `APPEND_SYSTEM.md` (orchestration rules, gates, routing) is already always loaded by pi core and is NOT processed by `context-resolver.ts`.
- Ancestor AGENTS.md files (`/AGENTS.md`, `/home/codeweaver/AGENTS.md`) are injected by pi core from ancestor directories of CWD. They appear as **plain text** in `event.systemPrompt`—no `@` markers—so `context-resolver.ts` cannot filter or strip them. This is a hard constraint: profile selection controls **only the harness AGENTS.md layer**, not ancestor project files.
- No `tests/` directory exists; no bats suite. Validation is done via `harness-audit.sh` (bash assert loop, exits non-zero on failure).
- `MANIFESTS.md` Section 3 ("Extension / TUI Manifest") governs any changes to `extensions/*.ts`.

---

## Tasks

### 1. Create `profiles/` directory with five profile files
- **File**: `~/.pi/agent/profiles/default.md` (new)
- **Changes**: Contains the exact `@` includes currently in `AGENTS.md` minus `tool-policy.md` (which moves to the immutable AGENTS.md header). This preserves current behavior when no profile is selected.
  ```
  @~/.agents/context/identity.md
  @~/.agents/context/environment.md
  @~/.agents/context/long-term.md
  @~/.agents/standards/code-style.md
  ```
- **Acceptance**: File exists; `diff <(cat profiles/default.md) <(...)` matches expected lines.

- **File**: `~/.pi/agent/profiles/ntv.md` (new)
- **Changes**: NTV-scoped domain context only.
  ```
  @~/.agents/context/identity.md
  @~/.agents/context/environment.md
  @~/.agents/context/long-term-ntv-v1.md
  @~/.agents/context/long-term-ntv-v2.md
  @~/.agents/standards/code-style.md
  ```
- **Acceptance**: All referenced files exist at those paths (validate in Task 6 audit check).

- **File**: `~/.pi/agent/profiles/pi-harness.md` (new)
- **Changes**: Pi extension patterns context only.
  ```
  @~/.agents/context/identity.md
  @~/.agents/context/environment.md
  @~/.agents/context/long-term-pi-extensions.md
  @~/.agents/standards/code-style.md
  ```

- **File**: `~/.pi/agent/profiles/desktop.md` (new)
- **Changes**: Hyprland/desktop context only.
  ```
  @~/.agents/context/identity.md
  @~/.agents/context/environment.md
  @~/.agents/context/long-term-hyprland.md
  @~/.agents/standards/code-style.md
  ```

- **File**: `~/.pi/agent/profiles/brainstorm.md` (new)
- **Changes**: Minimal — identity only. No domain knowledge, no code-style, no environment details.
  ```
  @~/.agents/context/identity.md
  ```
  Include a comment at top: `# brainstorm profile — minimal identity only; tool-policy loaded from AGENTS.md core`

- **Acceptance** (all 5): `ls profiles/*.md` lists all 5; each references only files that exist on disk.

---

### 2. Restructure `AGENTS.md` to separate immutable core from profile dispatch
- **File**: `~/.pi/agent/AGENTS.md`
- **Changes**:
  Replace the current 5-line `@include` block with:
  ```
  # Immutable core — loaded in every profile:
  @~/.agents/standards/tool-policy.md

  # Profile-gated domain context — swapped by context-resolver.ts based on PI_PROFILE:
  # (see ~/.pi/agent/profiles/ for available profiles)
  @~/.pi/agent/profiles/default.md
  ```
  The reference to `profiles/default.md` is the sentinel line that `context-resolver.ts` will substitute. Using an explicit path (not a relative `profiles/default.md`) makes matching unambiguous.
- **Acceptance**: `cat AGENTS.md` shows exactly 2 `@` lines; `tool-policy.md` include appears first; `profiles/default.md` appears second.
- **Risk**: If `before_agent_start` does NOT fire for the main orchestrator startup (only for subagent dispatch), the `@` lines in AGENTS.md would never be processed — verify this against actual pi behavior before implementing. If orchestrator startup is excluded, the profile substitution must happen at a different event hook.

---

### 3. Add recursive `@` expansion to `context-resolver.ts`
- **File**: `~/.pi/agent/extensions/context-resolver.ts`
- **Changes**: The current `expandSystemPrompt` is single-pass; profile files themselves contain `@` lines that must be expanded. Refactor to recursive expansion with depth guard:
  - Extract `expandSystemPrompt` to accept a `depth: number` parameter (default `0`) and a `maxDepth` (e.g., `5`)
  - If `depth > maxDepth`, return the prompt unchanged with a warning
  - The inner recursion call passes `depth + 1`
  - Accumulate `resolved[]` and `failed[]` across all recursion levels
  - Deduplicate `resolved[]` before notifying (avoid noise from profiles listing the same files)

- **Acceptance**: A profile file containing an `@` line causes that file's content to appear in the final system prompt (verifiable by checking the resolved list shown in the notify banner).

---

### 4. Add profile selection logic to `context-resolver.ts`
- **File**: `~/.pi/agent/extensions/context-resolver.ts`
- **Changes**: In the `before_agent_start` handler, before calling `expandSystemPrompt`:
  1. Read active profile:
     ```typescript
     const VALID_PROFILES = ["default", "ntv", "pi-harness", "desktop", "brainstorm"] as const;
     type Profile = typeof VALID_PROFILES[number];

     function readActiveProfile(agentDir: string): { profile: Profile; source: string } {
       // Priority 1: PI_PROFILE env var
       const envProfile = process.env.PI_PROFILE;
       if (envProfile) {
         if (VALID_PROFILES.includes(envProfile as Profile)) {
           return { profile: envProfile as Profile, source: "PI_PROFILE env" };
         }
         // Unknown env var value — warn but fall through
       }
       // Priority 2: settings.json contextProfile key
       const settingsPath = join(agentDir, "settings.json");
       if (existsSync(settingsPath)) {
         try {
           const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
           if (settings.contextProfile && VALID_PROFILES.includes(settings.contextProfile)) {
             return { profile: settings.contextProfile, source: "settings.json" };
           }
         } catch { /* ignore parse errors */ }
       }
       // Priority 3: hardcoded fallback
       return { profile: "default", source: "fallback" };
     }
     ```
  2. Compute `agentDir` from `import.meta.url` (or `__dirname` if CommonJS) or derive from the known settings path using `homedir()`.
  3. If profile is not `"default"`: find-and-replace the sentinel line in `event.systemPrompt`:
     ```typescript
     const DEFAULT_PROFILE_SENTINEL = `@${agentDir}/profiles/default.md`;
     const activeProfilePath = `@${agentDir}/profiles/${profile}.md`;
     const profiledPrompt = event.systemPrompt.replace(DEFAULT_PROFILE_SENTINEL, activeProfilePath);
     ```
     If the sentinel is NOT found (AGENTS.md has been changed without updating the extension), log a warning and proceed without substitution rather than silently using default.
  4. Validate the profile file exists before substitution; if missing, fall back to default and emit a `"warning"` notify.
  5. Pass `profiledPrompt` to `expandSystemPrompt` (recursive) instead of raw `event.systemPrompt`.
  6. Prepend profile announcement to the notify banner: `🎯 Profile: ${profile} (${source})`.

- **Acceptance**:
  - `PI_PROFILE=ntv pi` session: notify shows `🎯 Profile: ntv (PI_PROFILE env)` and resolved list includes `long-term-ntv-v1.md`, `long-term-ntv-v2.md`.
  - No `PI_PROFILE` set: notify shows `🎯 Profile: default (fallback)` and resolved list matches current behavior.
  - `PI_PROFILE=nonexistent pi`: notify shows warning, falls back to default.

---

### 5. Document `contextProfile` key in `settings.json.example`
- **File**: `~/.pi/agent/settings.json.example`
- **Changes**: Add after `"quietStartup": true`:
  ```json
  "contextProfile": "default",
  ```
  Add an inline JSON comment block (or adjacent `_comment` key) documenting:
  - Valid values: `default`, `ntv`, `pi-harness`, `desktop`, `brainstorm`
  - Override with env var: `PI_PROFILE=ntv pi`
  - This key only takes effect at session startup; changing it mid-session has no effect until restart
- **Acceptance**: `settings.json.example` contains the `contextProfile` key with a comment explaining the env var override.

---

### 6. Add profile invariants to `harness-audit.sh` (INV-15, INV-16, INV-17)
- **File**: `~/.pi/agent/harness-audit.sh`
- **Changes**: Add a new `== Context profile ==` section after `== Extension hygiene ==`:

  **INV-15** — all 5 profile files exist:
  ```bash
  echo "== Context profile =="
  PROFILES_DIR="${script_dir}/profiles"
  _required_profiles=("default.md" "ntv.md" "pi-harness.md" "desktop.md" "brainstorm.md")
  for _p in "${_required_profiles[@]}"; do
      if [[ -f "${PROFILES_DIR}/${_p}" ]]; then
          pass "INV-15 profiles/${_p} exists"
      else
          fail "INV-15 profiles/${_p} MISSING"
      fi
  done
  ```

  **INV-15b** — every `@` reference inside each profile file resolves on disk:
  ```bash
  while IFS= read -r _pfile; do
      while IFS= read -r _inc_line; do
          _inc_path="${_inc_line:1}"  # strip leading @
          _inc_abs="${_inc_path/\~/$HOME}"
          if [[ -e "$_inc_abs" ]]; then
              pass "INV-15b ${_pfile##*/}: ${_inc_path} resolves"
          else
              fail "INV-15b ${_pfile##*/}: ${_inc_path} MISSING on disk"
          fi
      done < <(grep -E '^@' "$_pfile" 2>/dev/null || true)
  done < <(find "$PROFILES_DIR" -name "*.md" -type f 2>/dev/null)
  ```

  **INV-16** — tool-policy.md is in AGENTS.md immutable core (not profile-delegated):
  ```bash
  if grep -qE '^@.*tool-policy\.md' "${script_dir}/AGENTS.md" 2>/dev/null; then
      pass "INV-16 tool-policy.md present in AGENTS.md immutable @include"
  else
      fail "INV-16 AGENTS.md missing @~/.agents/standards/tool-policy.md — must be in immutable core"
  fi
  ```

  **INV-17** — if `contextProfile` is set in settings.json, it must be a known value:
  ```bash
  _ctx_profile="$(python3 -c "import json,sys; d=json.load(open('${SETTINGS}')); print(d.get('contextProfile',''))" 2>/dev/null || echo "")"
  _valid_profiles=("default" "ntv" "pi-harness" "desktop" "brainstorm")
  if [[ -z "$_ctx_profile" ]]; then
      pass "INV-17 contextProfile not set in settings.json (PI_PROFILE env is primary)"
  else
      _found=false
      for _vp in "${_valid_profiles[@]}"; do
          [[ "$_ctx_profile" == "$_vp" ]] && _found=true && break
      done
      if $_found; then
          pass "INV-17 contextProfile='${_ctx_profile}' is a valid profile name"
      else
          fail "INV-17 contextProfile='${_ctx_profile}' is not a recognized profile (${_valid_profiles[*]})"
      fi
  fi
  ```

- **Acceptance**: `./harness-audit.sh` passes all existing invariants AND the 3 new ones (INV-15, INV-16, INV-17). Exit code 0.

---

### 7. Document INV-15/16/17 in `HARNESS_INVARIANTS.md`
- **File**: `~/.pi/agent/HARNESS_INVARIANTS.md`
- **Changes**: Add a new `## Context profile` section after `## Extension load order`:
  ```markdown
  ## Context profile

  - **INV-15** `profiles/` directory exists with all five profile files: `default.md`, `ntv.md`,
    `pi-harness.md`, `desktop.md`, `brainstorm.md`. Every `@` include inside each profile must
    resolve to an existing file on disk. Check: `harness-audit.sh` INV-15/15b.
  - **INV-16** `~/.agents/standards/tool-policy.md` must remain as a direct `@include` in
    `AGENTS.md` (not delegated to a profile file). It is the immutable safety core and must load
    in every profile. Check: grep AGENTS.md for `@.*tool-policy.md`.
  - **INV-17** If `contextProfile` is set in `settings.json`, its value must be one of the five
    known profile names. The `PI_PROFILE` env var takes priority over this key at runtime.
    Check: `harness-audit.sh` INV-17. Note: changing either key mid-session has no effect; the
    system prompt is fixed once a session starts. A session restart is required for any profile
    change to take effect.

  **Ancestor injection caveat (documented limitation):** Pi core injects AGENTS.md files from
  ancestor directories (`/AGENTS.md`, `/home/codeweaver/AGENTS.md`) as plain text before
  `context-resolver.ts` runs. These files contain NTV project overview, skills list, and tool
  safety pointers that `context-resolver.ts` cannot suppress. Profile selection controls only
  the `~/.pi/agent/AGENTS.md` layer. For a truly minimal brainstorm context, the NTV skills
  list and project overview from `/AGENTS.md` will still be present. This is a pi-core
  limitation, not addressable at the extension layer.
  ```
- **Acceptance**: `HARNESS_INVARIANTS.md` contains the new section with all three invariant entries and the ancestor caveat.

---

### 8. Add profile usage note to `README.md`
- **File**: `~/.pi/agent/README.md`
- **Changes**: Add a `## Context Profiles` section (or subsection under System Prompt / context-resolver entry):
  - Explain the 5 profiles and what each loads
  - Show the env var invocation: `PI_PROFILE=ntv pi`
  - Show the settings.json fallback key
  - Note the session-restart requirement
  - Note the ancestor AGENTS.md caveat for brainstorm/desktop
- **Acceptance**: README contains `PI_PROFILE` and lists all 5 profiles.

---

### 9. Validate with `harness-audit.sh` and manual spot-check
- **Commands to run**:
  ```bash
  cd ~/.pi/agent
  ./harness-audit.sh
  # Must exit 0 with all INV-1..17 passing

  PI_PROFILE=ntv pi --dry-run   # if pi supports dry-run, or
  PI_PROFILE=ntv pi             # start session, check greeting notify banner
  # Verify: "🎯 Profile: ntv (PI_PROFILE env)" appears
  # Verify: resolved list includes long-term-ntv-v1.md, long-term-ntv-v2.md
  # Verify: resolved list does NOT include long-term-pi-extensions.md

  PI_PROFILE=brainstorm pi
  # Verify: resolved list includes only identity.md
  # Verify: tool-policy.md still resolved (from AGENTS.md immutable line)

  # No profile set:
  pi
  # Verify: "🎯 Profile: default (fallback)" in banner
  # Verify: resolved list matches current behavior (identity, environment, long-term, code-style, tool-policy)
  ```
- **Acceptance**: All 3 spot-checks produce expected notify banners and resolved lists.

---

### 10. (Optional) Add thin convenience skill for profile announcement
- **File**: `~/.pi/agent/skills/set-profile/SKILL.md` (new — optional)
- **Changes**: A skill that:
  - Accepts a profile name argument
  - Prints clear instructions: "Profile switching requires session restart. Run: `PI_PROFILE=<name> pi`"
  - Optionally updates `settings.json` `contextProfile` key for the next default
  - Explicitly disclaims it does NOT switch context live
- **When to implement**: Only if the user asks. This is a convenience wrapper, not a functional requirement. Do not implement speculatively.
- **Acceptance**: N/A (optional).

---

## Files to Modify

- `~/.pi/agent/AGENTS.md` — Replace 5 `@` include lines with 2 (immutable tool-policy core + profile sentinel)
- `~/.pi/agent/extensions/context-resolver.ts` — Add recursive expansion, profile reading, profile-line substitution, profile notify
- `~/.pi/agent/settings.json.example` — Add documented `contextProfile` key
- `~/.pi/agent/harness-audit.sh` — Add INV-15/15b/16/17 checks
- `~/.pi/agent/HARNESS_INVARIANTS.md` — Document new invariants and ancestor caveat
- `~/.pi/agent/README.md` — Add Context Profiles section

## New Files

- `~/.pi/agent/profiles/default.md` — Current domain context (identity, environment, long-term, code-style)
- `~/.pi/agent/profiles/ntv.md` — NTV v1 + v2 domain context
- `~/.pi/agent/profiles/pi-harness.md` — Pi extension patterns context
- `~/.pi/agent/profiles/desktop.md` — Hyprland/desktop context
- `~/.pi/agent/profiles/brainstorm.md` — Minimal identity only

## Dependencies

```
Task 1 (profiles/) must complete before Task 2 (AGENTS.md restructure)
Task 1 must complete before Task 3 (recursive expansion)
Task 2 + Task 3 must complete before Task 4 (profile selection logic)
Task 4 must complete before Task 9 (validation)
Task 6 (harness-audit.sh) can be done in parallel with Tasks 3–5
Task 7 (HARNESS_INVARIANTS.md) can be done in parallel with Tasks 3–6
Task 8 (README) can be done last — no functional dependency
Task 10 (skill) is optional, no dependency
```

---

## Risks

### Risk 1: `before_agent_start` may not fire for orchestrator main session
**Severity**: HIGH / blocking.
The entire approach assumes `context-resolver.ts`'s `before_agent_start` hook fires when the main orchestrator session starts, not only for subagent dispatch. If it fires only for subagents, the `@` lines in `AGENTS.md` are never expanded for the main session, and profile substitution would have no effect.

**Validation step** (must be done BEFORE implementing Tasks 2–4): Check whether current `context-resolver.ts` actually resolves `@` lines in the main session's system prompt by inspecting the notify banner on a plain `pi` launch. If the banner shows `✓` resolved paths, the hook fires for the orchestrator. If it never fires, a different event hook is needed.

**Mitigation if hook doesn't fire**: Look for a `session_start` or `before_system_prompt_render` event in pi's ExtensionAPI. If no such hook exists, the profile system must be implemented differently — e.g., a pre-launch shell wrapper that generates `AGENTS.md` dynamically before `pi` is invoked.

### Risk 2: Sentinel line matching fragility
If `AGENTS.md` is edited and the `@~/.pi/agent/profiles/default.md` line changes format (whitespace, relative vs. absolute path), the string replacement in Task 4 silently falls back to default without a substitution. This is safe but invisible.

**Mitigation**: Add an explicit warning notify if the sentinel line is not found in the system prompt: `⚠️ Profile sentinel not found in system prompt — profile substitution skipped; using embedded @includes`.

### Risk 3: Recursive expansion infinite loop / depth blowout
If a profile file accidentally `@includes` itself (or a cycle forms), the recursive expander will hit the depth limit and stop. The depth limit (5) must be low enough to prevent runaway but high enough for legitimate 2-level nesting (AGENTS.md → profile → context file).

**Mitigation**: Depth limit of 5 is sufficient for the current 2-level chain. Add cycle detection by tracking already-resolved absolute paths in a `Set<string>` passed through recursion.

### Risk 4: Ancestor AGENTS.md pollution (documented limitation)
`/AGENTS.md` (NTV overview, skills list ~130 lines) and `/home/codeweaver/AGENTS.md` (4 lines, tool-safety pointer) are injected by pi core and cannot be suppressed. The `brainstorm` and `desktop` profiles will still receive this content.

**Impact**: Brainstorm profile is not truly "context-free"; NTV skills list and project overview will be present. This is acceptable for the current phase. A future enhancement could launch `pi` from a neutral CWD where pi does not walk up to `/AGENTS.md`, but even then the root-level file will likely still be loaded.

**Mitigation for now**: Document clearly in `HARNESS_INVARIANTS.md` and `README.md`. Do not promise a fully clean brainstorm context.

### Risk 5: `long-term.md` vs. granular files in `default.md`
The current AGENTS.md references `@~/.agents/context/long-term.md`, which itself is a redirect file saying "use pi-knowledge-search for specific details." The `ntv.md` profile references `long-term-ntv-v1.md` and `long-term-ntv-v2.md` directly. This is correct but creates a content mismatch — `default` profile includes the generic redirect, while `ntv` includes the actual NTV details.

**Decision needed**: Should `default.md` keep referencing the generic `long-term.md` (redirect/minimal) or should it load all domain files? Current behavior (`long-term.md` as redirect) means `default` is intentionally minimal and profiles exist to add specificity. This matches the stated goal.

### Risk 6: `agentDir` path resolution in `context-resolver.ts`
The extension needs to know its own directory (`~/.pi/agent/`) to construct the profile file path. Options:
- Derive from `homedir()`: `join(homedir(), ".pi", "agent")` — simple and reliable
- Use `import.meta.url` — requires ESM and may be unavailable depending on pi's module system

**Recommendation**: Use `join(homedir(), ".pi", "agent")` as the agent directory since this is the established convention used elsewhere in the file (`relPath.replace(/^~/, homedir())`).

### Risk 7: `settings.json` read race / parse failure
If `settings.json` is malformed at startup, the try/catch fallback handles it silently. This is safe. If `settings.json` is being written by another process at the exact moment `context-resolver.ts` reads it, a partial read could fail — the try/catch handles this too.

### Decisions Needed (surface to user before implementation)

1. **Confirm `before_agent_start` fires for orchestrator startup** (Risk 1 — blocking). This must be verified by inspecting current session notify banners before any code is written.
2. **Confirm `default.md` keeps `long-term.md` (generic redirect)** vs. loading all domain files (Risk 5). Current plan uses the generic redirect — this is the safer/smaller default.
3. **Confirm recursive expansion is wanted** vs. keeping profile files flat (all context inlined, no `@` lines inside profile files). Recursive is more DRY but adds code complexity; flat is simpler but duplicates paths. Plan recommends recursive.
