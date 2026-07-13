#!/usr/bin/env bash
set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# Zero out colors if non-tty or NO_COLOR set
if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# Path constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${HOME}/.agents"
SETTINGS_SRC="${SCRIPT_DIR}/settings.json.example"
SETTINGS_DST="${SCRIPT_DIR}/settings.json"
PI_PKG="@earendil-works/pi-coding-agent"
NODE_MIN_MAJOR=18
PLATFORM="linux"

# detect_platform: Set PLATFORM based on environment
detect_platform() {
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        PLATFORM="wsl"
    elif [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version; then
        PLATFORM="wsl"
    else
        PLATFORM="linux"
    fi
}

# print_header: Print setup banner
print_header() {
    printf "${BOLD}========================================${RESET}\n"
    printf "${BOLD}  Pi Agent Harness — Setup${RESET}\n"
    printf "${BOLD}========================================${RESET}\n"

    local os_display="Linux (native)"
    if [[ "$PLATFORM" == "wsl" ]]; then
        os_display="Windows + WSL2"
    fi

    printf "  Platform : %s\n" "$os_display"
    printf "  Harness  : ~/.pi/agent\n"
    printf "  Vault    : ~/.agents\n"
    printf "${BOLD}========================================${RESET}\n"
    echo ""
}

# print_section: Print section header
print_section() {
    local title="$1"
    echo ""
    printf "${BOLD}[ %s ]${RESET}\n" "$title"
    echo ""
}

# Output helpers
print_ok() {
    printf "  ${GREEN}✓${RESET} %s\n" "$1"
}

print_fail() {
    printf "  ${RED}✗${RESET} %s\n" "$1"
}

print_skip() {
    printf "  ${YELLOW}→${RESET} %s\n" "$1"
}

print_info() {
    printf "  ${BLUE}…${RESET} %s\n" "$1"
}

# check_node: Verify Node.js is installed and meets minimum version
check_node() {
    print_section "Node.js"

    if ! command -v node &> /dev/null; then
        print_fail "Node.js not found"
        echo ""
        echo "  Install via nvm (recommended):"
        echo "    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
        echo "    source ~/.bashrc"
        echo "    nvm install --lts && nvm use --lts"
        echo ""
        if [[ "$PLATFORM" == "wsl" ]]; then
            echo "  On WSL, prefer nvm over apt — apt ships outdated Node versions."
            echo ""
        fi
        exit 1
    fi

    local node_version
    node_version=$(node --version | sed 's/v//')
    local node_major
    node_major=$(echo "$node_version" | cut -d. -f1)

    if (( node_major < NODE_MIN_MAJOR )); then
        print_fail "Node.js v$node_version found — need v$NODE_MIN_MAJOR+"
        echo ""
        echo "  Upgrade via nvm:"
        echo "    nvm install --lts && nvm use --lts"
        echo ""
        exit 1
    fi

    print_ok "Node.js v$node_version"
}

# install_pi: Install pi-coding-agent globally
install_pi() {
    print_section "Pi coding agent"

    if command -v pi &> /dev/null; then
        local pi_ver
        pi_ver=$(pi --version 2>/dev/null || echo "unknown")

        # Validate it's actually pi-coding-agent
        if pi --version 2>/dev/null | grep -qiE "pi-coding-agent|earendil|[0-9]+\.[0-9]+\.[0-9]+"; then
            print_skip "pi already installed (v$pi_ver)"
            return
        else
            echo ""
            echo "  Warning: A different 'pi' binary found at $(which pi) — this may conflict."
            print_info "Check PATH ordering or rename the conflicting binary."
            print_info "Continuing install — npm will install pi-coding-agent alongside it."
            echo ""
        fi
    fi

    print_info "Installing $PI_PKG globally..."
    echo ""

    if npm install -g "$PI_PKG"; then
        print_ok "pi installed"
    else
        local exit_code=$?
        print_fail "npm install failed (exit $exit_code)"
        echo ""

        local npm_prefix
        npm_prefix=$(npm config get prefix 2>/dev/null || echo "unknown")

        if [[ "$npm_prefix" == /usr* ]]; then
            echo "  npm is using a system prefix ($npm_prefix) — likely a permissions error."
            echo ""
            echo "  Fix options:"
            echo "    A (recommended): Use nvm — it sets prefix to ~/.nvm automatically"
            echo "    B: npm config set prefix ~/.local && export PATH=\"\$HOME/.local/bin:\$PATH\""
            echo "    C: sudo npm install -g $PI_PKG  (not recommended)"
            echo ""
        fi
        exit 1
    fi
}

# copy_settings: Copy settings.json.example to settings.json
copy_settings() {
    print_section "Settings"

    if [[ -f "$SETTINGS_DST" ]]; then
        print_skip "settings.json already exists — not overwriting"
        return
    fi

    if [[ ! -f "$SETTINGS_SRC" ]]; then
        print_fail "settings.json.example missing from $SCRIPT_DIR"
        echo ""
        echo "  Re-clone the harness: git clone <url> ~/.pi/agent"
        echo ""
        exit 1
    fi

    cp "$SETTINGS_SRC" "$SETTINGS_DST"
    print_ok "settings.json created from settings.json.example"
    print_info "Pi rewrites settings.json each session — do not commit it"
}

# scaffold_agents: Create ~/.agents directory structure and stub files
scaffold_agents() {
    print_section "~/.agents/ context vault"

    # Root warning
    if (( EUID == 0 )); then
        echo "  Warning: Running as root — ~/.agents will be created under /root. This is unusual."
        echo ""
    fi

    # Create directory structure
    mkdir -p "$AGENTS_DIR/context"
    mkdir -p "$AGENTS_DIR/standards"
    mkdir -p "$AGENTS_DIR/state"
    mkdir -p "$AGENTS_DIR/state/handoffs"
    mkdir -p "$AGENTS_DIR/state/archive"
    print_ok "Directory structure ready: $AGENTS_DIR"
    echo ""

    local stub_content="# Placeholder — the first-run wizard (launched by \`pi\`) will complete this file."

    declare -A stubs
    stubs["context/identity.md"]="$stub_content"
    stubs["context/environment.md"]="$stub_content"
    stubs["context/long-term.md"]="$stub_content"
    stubs["standards/code-style.md"]="$stub_content"
    stubs["standards/tool-policy.md"]="$stub_content"

    for file in "${!stubs[@]}"; do
        local target="$AGENTS_DIR/$file"
        if [[ -f "$target" ]]; then
            print_skip "~/.agents/$file (already exists)"
        else
            printf '%s\n' "${stubs[$file]}" > "$target"
            print_ok "Created ~/.agents/$file"
        fi
    done

    # first-run.ts owns ~/.agents/.personalized — never create it here
}

# print_auth_instructions: Print authentication setup instructions
print_auth_instructions() {
    print_section "Authentication"

    echo "  Run this to log in to your AI providers:"
    echo ""
    echo "    pi auth login"
    echo ""
    echo "    REQUIRED:"
    echo "      Anthropic API key  →  https://console.anthropic.com/"
    echo "      Powers: all workers (claude-sonnet-4-6) + orchestrator (your choice of model)"
    echo ""
    echo "    OPTIONAL:"
    echo "      Google OAuth  →  researcher agent (gemini-3.1-pro) + gmail extension"
    echo "      Skip if you do not need web research or Gmail."
    echo ""
    echo "  After authenticating:"
    echo "    pi --list-models    ← verify available models"
    echo "    pi \"hello\"          ← launches the identity setup wizard"
}

# main: Orchestrate setup flow
main() {
    detect_platform
    print_header

    # Root warning
    if (( EUID == 0 )); then
        print_fail "Running as root. Recommended: run as a normal user."
        print_info "Continuing anyway — but npm global installs will target /root."
        echo ""
    fi

    check_node
    install_pi
    copy_settings
    scaffold_agents
    print_auth_instructions

    echo ""
    printf "${BOLD}Setup complete.${RESET} Run ${BOLD}pi auth login${RESET} then ${BOLD}pi \"hello\"${RESET} to start.\n"
    echo ""
}

main "$@"
