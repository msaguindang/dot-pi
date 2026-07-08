#!/usr/bin/env bash
set -euo pipefail

# harness-audit.sh — assert HARNESS_INVARIANTS.md programmatically.
# Prints pass/fail per invariant; exits non-zero if any HARD invariant fails.
# Run after any harness change (and on a freshly reloaded session).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${script_dir}/agents"
SETTINGS="${script_dir}/settings.json"
COST_TRACKER="${script_dir}/extensions/cost-tracker.ts"

fail_count=0

pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; fail_count=$((fail_count + 1)); }

# Read a frontmatter field (model:/thinking:) from an agent file.
agent_field() {
    local file="$1" key="$2"
    grep -m1 "^${key}:" "${AGENTS_DIR}/${file}" 2>/dev/null | sed "s/^${key}: *//" || true
}

assert_field() {
    local file="$1" key="$2" want="$3"
    local got; got="$(agent_field "$file" "$key")"
    if [[ "$got" == "$want" ]]; then
        pass "${file} ${key} = ${want}"
    else
        fail "${file} ${key} = '${got:-<unset>}' (want '${want}')"
    fi
}

echo "== Model routing =="
# INV-1 orchestrator defaults
if grep -q '"defaultModel": *"claude-haiku-4-5"' "$SETTINGS" 2>/dev/null \
    && grep -q '"defaultThinkingLevel": *"medium"' "$SETTINGS" 2>/dev/null \
    && grep -q '"defaultProvider": *"anthropic"' "$SETTINGS" 2>/dev/null; then
    pass "INV-1 orchestrator = anthropic/claude-haiku-4-5 thinking medium"
else
    fail "INV-1 orchestrator defaults (settings.json) not as expected"
fi

# INV-2/3/4 per-agent pins
assert_field "worker.md"          "model"    "anthropic/claude-sonnet-4-6"
assert_field "worker.md"          "thinking" "medium"               # INV-2
assert_field "tui-worker.md"      "model"    "anthropic/claude-sonnet-4-6"
assert_field "tui-worker.md"      "thinking" "medium"               # INV-2
assert_field "planner.md"         "model"    "anthropic/claude-sonnet-4-6"
assert_field "planner.md"         "thinking" "high"                 # INV-3
assert_field "session-auditor.md" "model"    "minimax/MiniMax-M3"
assert_field "linux-doctor.md"    "model"    "google/gemini-3.1-pro-preview-customtools"

# INV-4 no dropped providers in MODEL PINS (prose mentions in notes are fine)
if grep -rhE "^model:" "$AGENTS_DIR" | grep -qiE "openai-codex|gpt-5\.5"; then
    fail "INV-4 dropped provider (openai-codex/gpt-5.5) still pinned in an agent model:"
else
    pass "INV-4 no dropped-provider model pins"
fi

echo "== Delegation behavior =="
# INV-5 no blocking-wait escalation language (negative guards are allowed)
if grep -rniE "wait for the reply|stay alive to receive the reply" "$AGENTS_DIR" 2>/dev/null \
    | grep -viE "never|do not|don't" | grep -q .; then
    fail "INV-5 a blocking 'wait for the reply' instruction remains in agents/"
else
    pass "INV-5 no blocking supervisor-wait escalation"
fi

echo "== Process discipline =="
# INV-13 orchestrator verifies subagent claims; device work gets post-deploy probe
APPEND_SYSTEM="${script_dir}/APPEND_SYSTEM.md"
if grep -q "Subagent claims are unverified until checked" "$APPEND_SYSTEM" 2>/dev/null \
    && grep -q "Device work requires a post-deploy probe" "$APPEND_SYSTEM" 2>/dev/null; then
    pass "INV-13 claim-verification + post-deploy probe clauses present in APPEND_SYSTEM.md"
else
    fail "INV-13 APPEND_SYSTEM.md missing claim-verification / post-deploy probe clauses"
fi

echo "== Cost observability =="
# INV-8 footer aggregates via parentSessionId
if grep -q "parentSessionId" "$COST_TRACKER" 2>/dev/null; then
    pass "INV-8 cost-tracker aggregates subagent cost via parentSessionId"
else
    fail "INV-8 cost-tracker.ts missing parentSessionId aggregation"
fi

echo ""
if [[ "$fail_count" -gt 0 ]]; then
    printf '\033[1;31m%d invariant(s) FAILED\033[0m\n' "$fail_count"
    exit 1
fi
printf '\033[1;32mAll invariants PASS\033[0m\n'
# Note: INV-9 (footer == raw ground-truth) and INV-11 (outcome verification) are
# runtime/process checks, not statically assertable here — validate on a fresh session.
