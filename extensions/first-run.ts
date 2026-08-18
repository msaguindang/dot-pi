import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync as readFS } from "fs";
import { homedir, platform } from "os";
import { join } from "path";

const MARKER = join(homedir(), ".agents/.personalized");

type Platform = "linux" | "wsl" | "macos" | "windows" | "unknown";

function detectPlatform(): Platform {
  const p = platform();
  if (p === "darwin") return "macos";
  if (p === "win32") return "windows";
  if (p === "linux") {
    const isWSL =
      process.env.WSL_DISTRO_NAME !== undefined ||
      (existsSync("/proc/version") &&
        readFS("/proc/version", "utf-8").toLowerCase().includes("microsoft"));
    return isWSL ? "wsl" : "linux";
  }
  return "unknown";
}

function buildEnvironmentTemplate(detected: Platform): string {
  const namePlaceholder = "[Your Name]";
  const base = `# Environment: ${namePlaceholder} Workstation
- **Directory**: \`~/.agents\` (global context — synced via git)

## Active Technologies
- Core: Node.js, bash, git worktrees
- Agent harness: pi (https://github.com/mariozechner/pi-coding-agent)
- Fill in your stack below

## Key Paths & Repositories
`;

  const byPlatform: Record<Platform, string> = {
    linux: `${base}- \`~/Projects/\` — main project directory (fill in your repos)
- \`~/.config/\` — system config
- \`~/dotfiles/\` — dotfiles (if applicable)

## Shell & Terminal
- **Shell**: bash (or fill in: zsh, fish)
- **Terminal**: fill in (WezTerm, Alacritty, Kitty, etc.)
- **WM**: fill in (i3, Hyprland, GNOME, etc.)

## Aliases Available
- Fill in your shell aliases here

## Device Topology
- **This machine**: Linux desktop/laptop
- Fill in other devices if applicable

## Notes & Knowledge Base
`,
    wsl: `${base}- \`~/Projects/\` — WSL project directory (fill in your repos)
- \`/mnt/c/Users/[username]/\` — Windows home accessible from WSL
- \`~/.config/\` — WSL config

## Shell & Terminal
- **Shell**: bash in WSL2
- **Terminal**: Windows Terminal / WezTerm (fill in)
- **WSL Distro**: fill in (Ubuntu 24.04, Debian, etc.)
- **Windows Host**: fill in your Windows machine name

## Aliases Available
- Fill in your shell aliases here

## Device Topology
- **This machine**: Windows + WSL2
- Fill in other devices if applicable

## Notes & Knowledge Base
- Windows files accessible under /mnt/c/
- Clipboard: use xclip or pipe to clip.exe on the Windows host
`,
    macos: `${base}- \`~/Projects/\` — main project directory (fill in your repos)
- \`~/.config/\` — system config
- \`~/dotfiles/\` — dotfiles (if applicable)

## Shell & Terminal
- **Shell**: zsh (macOS default)
- **Terminal**: fill in (iTerm2, WezTerm, Terminal.app, etc.)

## Aliases Available
- Fill in your shell aliases here

## Device Topology
- **This machine**: macOS
- Fill in other devices if applicable

## Notes & Knowledge Base
- Homebrew packages at /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel)
- Clipboard: pbcopy / pbpaste
`,
    windows: `${base}- \`C:\\Users\\[username]\\Projects\\\` — main project directory
- Fill in your key paths

## Shell & Terminal
- **Shell**: PowerShell / fill in
- **Terminal**: Windows Terminal / fill in

## Aliases Available
- Fill in your shell aliases here

## Device Topology
- **This machine**: Windows
- Fill in other devices if applicable

## Notes & Knowledge Base
- Clipboard: Set-Clipboard / Get-Clipboard
`,
    unknown: `${base}- Fill in your project directories

## Shell & Terminal
- Fill in your shell and terminal

## Aliases Available
- Fill in your shell aliases here

## Device Topology
- Fill in your other devices if applicable
`,
  };

  return byPlatform[detected];
}

const DETECTED_PLATFORM = detectPlatform();

const PLATFORM_LABELS: Record<Platform, string> = {
  linux: "Linux (native)",
  wsl: "Windows + WSL2",
  macos: "macOS",
  windows: "Windows (native)",
  unknown: "Unknown OS",
};

const PLATFORM_TEMPLATE = buildEnvironmentTemplate(DETECTED_PLATFORM);

const SETUP_PROMPT = `
## FIRST-RUN SETUP

The agent identity has not been configured. Before doing anything else, guide the user through setup.

**Detected platform: ${PLATFORM_LABELS[DETECTED_PLATFORM as Platform]}**

Ask the user the following questions **one at a time**, waiting for each answer:
1. "What is your name?"
2. "What is your role or title? (e.g. Senior Software Engineer, DevOps Engineer)"
3. "Describe your working style or core principles in 1-3 sentences."

After all answers are collected:

**Write \`~/.agents/context/identity.md\`:**
\`\`\`
# Identity: <Role>
- **Core Principles**: <principles from answer 3>
- **Operational Constraints**: Normal mutation follows canonical orchestration; REV mode is the narrow exception defined there. Default to Caveman mode.
- **Output Preferences**: Direct, concise, technical; minimize boilerplate.
- **Behavioral Flags**: Challenge assumptions; verify step-by-step using raw outputs.
\`\`\`

**Write \`~/.agents/context/environment.md\`** using this pre-populated template for a ${PLATFORM_LABELS[DETECTED_PLATFORM as Platform]} machine. Replace "[Your Name]" with the user's actual name. Leave all other "[fill in]" placeholders for the user to complete manually:
\`\`\`
${PLATFORM_TEMPLATE}
\`\`\`

**Create \`~/.agents/.personalized\`** containing today's date (YYYY-MM-DD).

Tell the user:
- Their platform was detected as: **${PLATFORM_LABELS[DETECTED_PLATFORM as Platform]}**
- identity.md has been written
- environment.md has been pre-populated for a ${PLATFORM_LABELS[DETECTED_PLATFORM as Platform]} machine — they should review and fill in the [fill in] sections
- Run \`cat ~/.agents/context/environment.md\` to see what needs completing

Do NOT do any other work until setup is complete.
`;

export default function (pi: ExtensionAPI) {
  pi.on("before_agent_start", async (event, _ctx) => {
    if (existsSync(MARKER)) return {};
    return {
      systemPrompt: event.systemPrompt + "\n\n" + SETUP_PROMPT,
    };
  });
}
