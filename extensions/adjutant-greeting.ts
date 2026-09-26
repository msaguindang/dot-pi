/**
 * Adjutant Greeting — Foundry startup greeting with welcome overlay
 *
 * Shows a welcome overlay on session_start (unless resuming).
 * Displays agent roster widget until first agent message.
 * Includes integrated welcome overlay from pi-powerline-footer.
 */

import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { Component } from "@earendil-works/pi-tui";
import { readdirSync, existsSync, statSync, readFileSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir as osHomedir } from "node:os";

// ═══════════════════════════════════════════════════════════════════════════
// WELCOME OVERLAY — Integrated from pi-powerline-footer
// ═══════════════════════════════════════════════════════════════════════════

// ── Theme Colors (minimal subset for welcome overlay) ────────────────────

const ansi = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  bold: "\x1b[1m",
  unbold: "\x1b[22m",
  undim: "\x1b[22m",
};

// Simplified theme color helpers (using basic ANSI colors)
const themeColors = {
  accent: "\x1b[36m", // cyan
  model: "\x1b[35m", // magenta
  path: "\x1b[33m", // yellow
  gitClean: "\x1b[32m", // green
  sep: "\x1b[2m", // dim
};

function fgOnly(colorKey: keyof typeof themeColors, text: string): string {
  return themeColors[colorKey] + text + ansi.reset;
}

function getFgAnsiCode(colorKey: keyof typeof themeColors): string {
  return themeColors[colorKey];
}

function bold(text: string): string {
  return `${ansi.bold}${text}${ansi.unbold}`;
}

function dim(text: string): string {
  return getFgAnsiCode("sep") + text + ansi.reset;
}

// ── Welcome Data Types ───────────────────────────────────────────────────

export interface RecentSession {
  name: string;
  timeAgo: string;
}

export interface LoadedCounts {
  contextFiles: number;
  extensions: number;
  skills: number;
  promptTemplates: number;
}

interface WelcomeData {
  modelName: string;
  providerName: string;
  recentSessions: RecentSession[];
  loadedCounts: LoadedCounts;
}

// ── Pi Logo & Gradient ───────────────────────────────────────────────────

const PI_LOGO = [
  "██████████    ",
  "████  ████    ",
  "████  ████    ",
  "████████  ████",
  "████      ████",
  "████      ████",
];

const GRADIENT_COLORS = [
  "\x1b[38;5;199m",
  "\x1b[38;5;171m",
  "\x1b[38;5;135m",
  "\x1b[38;5;99m",
  "\x1b[38;5;75m",
  "\x1b[38;5;51m",
];

function gradientLine(line: string): string {
  const reset = ansi.reset;
  let result = "";
  let colorIdx = 0;
  const step = Math.max(1, Math.floor(line.length / GRADIENT_COLORS.length));

  for (let i = 0; i < line.length; i++) {
    if (i > 0 && i % step === 0 && colorIdx < GRADIENT_COLORS.length - 1)
      colorIdx++;
    const char = line[i];
    if (char !== " ") {
      result += GRADIENT_COLORS[colorIdx] + char + reset;
    } else {
      result += char;
    }
  }
  return result;
}

function centerText(text: string, width: number): string {
  const visLen = visibleWidth(text);
  if (visLen > width) return truncateToWidth(text, width, "…");
  if (visLen === width) return text;
  const leftPad = Math.floor((width - visLen) / 2);
  const rightPad = width - visLen - leftPad;
  return " ".repeat(leftPad) + text + " ".repeat(rightPad);
}

function fitToWidth(str: string, width: number): string {
  const visLen = visibleWidth(str);
  if (visLen > width) return truncateToWidth(str, width, "…");
  return str + " ".repeat(width - visLen);
}

// ── Welcome Box Rendering ────────────────────────────────────────────────

function buildLeftColumn(data: WelcomeData, colWidth: number): string[] {
  const logoColored = PI_LOGO.map((line) => gradientLine(line));

  return [
    "",
    centerText(bold("Welcome back!"), colWidth),
    "",
    ...logoColored.map((l) => centerText(l, colWidth)),
    "",
    centerText(fgOnly("model", data.modelName), colWidth),
    centerText(dim(data.providerName), colWidth),
  ];
}

function buildRightColumn(data: WelcomeData, colWidth: number): string[] {
  const hChar = "─";
  const separator = truncateToWidth(
    ` ${dim(hChar.repeat(colWidth - 2))}`,
    colWidth,
  );

  // Session lines
  const sessionLines: string[] = [];
  if (data.recentSessions.length === 0) {
    sessionLines.push(` ${dim("No recent sessions")}`);
  } else {
    for (const session of data.recentSessions.slice(0, 3)) {
      sessionLines.push(
        ` ${dim("• ")}${fgOnly("path", session.name)}${dim(` (${session.timeAgo})`)}`,
      );
    }
  }

  // Loaded counts lines
  const countLines: string[] = [];
  const { contextFiles, extensions, skills, promptTemplates } =
    data.loadedCounts;
  const itemPrefix = dim("- ");

  if (contextFiles > 0 || extensions > 0 || skills > 0 || promptTemplates > 0) {
    if (contextFiles > 0) {
      countLines.push(
        ` ${itemPrefix}${fgOnly("gitClean", `${contextFiles}`)} context file${contextFiles !== 1 ? "s" : ""}`,
      );
    }
    if (extensions > 0) {
      countLines.push(
        ` ${itemPrefix}${fgOnly("gitClean", `${extensions}`)} extension${extensions !== 1 ? "s" : ""}`,
      );
    }
    if (skills > 0) {
      countLines.push(
        ` ${itemPrefix}${fgOnly("gitClean", `${skills}`)} skill${skills !== 1 ? "s" : ""}`,
      );
    }
    if (promptTemplates > 0) {
      countLines.push(
        ` ${itemPrefix}${fgOnly("gitClean", `${promptTemplates}`)} prompt template${promptTemplates !== 1 ? "s" : ""}`,
      );
    }
  } else {
    countLines.push(` ${dim("No extensions loaded")}`);
  }

  return [
    ` ${bold(fgOnly("accent", "Tips"))}`,
    ` ${dim("/")} for commands`,
    ` ${dim("!")} to run bash`,
    ` ${dim("Shift+Tab")} cycle thinking`,
    separator,
    ` ${bold(fgOnly("accent", "Loaded"))}`,
    ...countLines,
    separator,
    ` ${bold(fgOnly("accent", "Recent sessions"))}`,
    ...sessionLines,
    "",
  ];
}

function renderWelcomeBox(
  data: WelcomeData,
  termWidth: number,
  bottomLine: string,
): string[] {
  const minLayoutWidth = 44;
  if (termWidth < minLayoutWidth) return [];

  const minWidth = 76;
  const maxWidth = 96;
  const boxWidth = Math.min(
    termWidth,
    Math.max(minWidth, Math.min(termWidth - 2, maxWidth)),
  );
  const leftCol = 26;
  const rightCol = Math.max(1, boxWidth - leftCol - 3);

  const hChar = "─";
  const v = dim("│");
  const tl = dim("╭");
  const tr = dim("╮");
  const bl = dim("╰");
  const br = dim("╯");

  const leftLines = buildLeftColumn(data, leftCol);
  const rightLines = buildRightColumn(data, rightCol);

  const lines: string[] = [];

  // Top border with title
  const title = " adjutant ";
  const titlePrefix = dim(hChar.repeat(3));
  const titleStyled = titlePrefix + fgOnly("model", title);
  const titleVisLen = visibleWidth(titlePrefix) + visibleWidth(title);
  const afterTitle = boxWidth - 2 - titleVisLen;
  const afterTitleText = afterTitle > 0 ? dim(hChar.repeat(afterTitle)) : "";
  lines.push(truncateToWidth(tl + titleStyled + afterTitleText + tr, boxWidth));

  // Content rows
  const maxRows = Math.max(leftLines.length, rightLines.length);
  for (let i = 0; i < maxRows; i++) {
    const left = fitToWidth(leftLines[i] ?? "", leftCol);
    const right = fitToWidth(rightLines[i] ?? "", rightCol);
    lines.push(v + left + v + right + v);
  }

  // Bottom border
  lines.push(bl + bottomLine + br);

  return lines;
}

// ── Welcome Component (Overlay Mode) ─────────────────────────────────────

class WelcomeComponent implements Component {
  private data: WelcomeData;
  private countdown: number = 20; // 20 seconds for adjutant

  constructor(
    modelName: string,
    providerName: string,
    recentSessions: RecentSession[] = [],
    loadedCounts: LoadedCounts = {
      contextFiles: 0,
      extensions: 0,
      skills: 0,
      promptTemplates: 0,
    },
  ) {
    this.data = { modelName, providerName, recentSessions, loadedCounts };
  }

  setCountdown(seconds: number): void {
    this.countdown = seconds;
  }

  invalidate(): void {}

  render(termWidth: number): string[] {
    const minLayoutWidth = 44;
    if (termWidth < minLayoutWidth) return [];

    const minWidth = 76;
    const maxWidth = 96;
    const boxWidth = Math.min(
      termWidth,
      Math.max(minWidth, Math.min(termWidth - 2, maxWidth)),
    );

    // Bottom line with countdown
    const countdownText = ` Press any key to continue (${this.countdown}s) `;
    const countdownStyled = dim(countdownText);
    const bottomContentWidth = boxWidth - 2;
    const countdownVisLen = visibleWidth(countdownText);
    const leftPad = Math.floor((bottomContentWidth - countdownVisLen) / 2);
    const rightPad = bottomContentWidth - countdownVisLen - leftPad;
    const hChar = "─";
    const bottomLine =
      dim(hChar.repeat(Math.max(0, leftPad))) +
      countdownStyled +
      dim(hChar.repeat(Math.max(0, rightPad)));

    return renderWelcomeBox(this.data, termWidth, bottomLine);
  }
}

// ── Discovery Functions ──────────────────────────────────────────────────

const loggedDiscoveryErrors = new Set<string>();

function logDiscoveryError(scope: string, error: unknown): void {
  const message = error instanceof Error ? error.message : String(error);
  const key = `${scope}:${message}`;
  if (loggedDiscoveryErrors.has(key)) return;

  loggedDiscoveryErrors.add(key);
  if (loggedDiscoveryErrors.size > 500) {
    loggedDiscoveryErrors.clear();
  }

  console.debug(`[adjutant-greeting] ${scope}:`, error);
}

function discoverLoadedCounts(): LoadedCounts {
  const homeDir = process.env.HOME || process.env.USERPROFILE || osHomedir();
  const cwd = process.cwd();

  let contextFiles = 0;
  let extensions = 0;
  let skills = 0;
  let promptTemplates = 0;

  // Context files
  const agentsMdPaths = [
    join(homeDir, ".pi", "agent", "AGENTS.md"),
    join(homeDir, ".claude", "AGENTS.md"),
    join(cwd, "AGENTS.md"),
    join(cwd, ".pi", "AGENTS.md"),
    join(cwd, ".claude", "AGENTS.md"),
  ];

  for (const path of agentsMdPaths) {
    if (existsSync(path)) contextFiles++;
  }

  // Extensions
  const extensionDirs = [
    join(homeDir, ".pi", "agent", "extensions"),
    join(cwd, "extensions"),
    join(cwd, ".pi", "extensions"),
  ];

  const countedExtensions = new Set<string>();

  const settingsPaths = [
    join(homeDir, ".pi", "agent", "settings.json"),
    join(cwd, ".pi", "settings.json"),
  ];

  for (const settingsPath of settingsPaths) {
    if (!existsSync(settingsPath)) continue;

    try {
      const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
      let packages: unknown = null;
      if (
        typeof settings === "object" &&
        settings !== null &&
        !Array.isArray(settings)
      ) {
        packages = (settings as { packages?: unknown }).packages;
      }

      if (Array.isArray(packages)) {
        for (const pkg of packages) {
          let source: unknown = null;
          let extensionsFilter: unknown = null;

          if (typeof pkg === "string") {
            source = pkg;
          } else if (
            typeof pkg === "object" &&
            pkg !== null &&
            !Array.isArray(pkg)
          ) {
            source = (pkg as { source?: unknown }).source;
            extensionsFilter = (pkg as { extensions?: unknown }).extensions;
          }

          if (typeof source !== "string") continue;

          const normalizedSource = source.trim();
          if (!normalizedSource.startsWith("npm:")) continue;

          if (Array.isArray(extensionsFilter) && extensionsFilter.length === 0)
            continue;

          const body = normalizedSource.slice(4);
          const versionIndex = body.lastIndexOf("@");
          const name = versionIndex > 0 ? body.slice(0, versionIndex) : body;
          if (!name || countedExtensions.has(name)) continue;

          countedExtensions.add(name);
          extensions++;
        }
      }
    } catch (error) {
      logDiscoveryError(`Failed to read settings at ${settingsPath}`, error);
    }
  }

  for (const dir of extensionDirs) {
    if (existsSync(dir)) {
      try {
        const entries = readdirSync(dir);
        for (const entry of entries) {
          const entryPath = join(dir, entry);

          try {
            const stats = statSync(entryPath);

            if (stats.isDirectory()) {
              if (
                existsSync(join(entryPath, "index.ts")) ||
                existsSync(join(entryPath, "index.js")) ||
                existsSync(join(entryPath, "package.json"))
              ) {
                if (!countedExtensions.has(entry)) {
                  countedExtensions.add(entry);
                  extensions++;
                }
              }
            } else if (
              (entry.endsWith(".ts") || entry.endsWith(".js")) &&
              !entry.startsWith(".")
            ) {
              const ext = entry.endsWith(".ts") ? ".ts" : ".js";
              const name = basename(entry, ext);
              if (!countedExtensions.has(name)) {
                countedExtensions.add(name);
                extensions++;
              }
            }
          } catch (error) {
            logDiscoveryError(
              `Failed to inspect extension entry ${entryPath}`,
              error,
            );
          }
        }
      } catch (error) {
        logDiscoveryError(`Failed to scan extensions dir ${dir}`, error);
      }
    }
  }

  // Skills
  const skillDirs = [
    join(homeDir, ".pi", "agent", "skills"),
    join(cwd, ".pi", "skills"),
    join(cwd, "skills"),
  ];

  const countedSkills = new Set<string>();

  for (const dir of skillDirs) {
    if (existsSync(dir)) {
      try {
        const entries = readdirSync(dir);
        for (const entry of entries) {
          const entryPath = join(dir, entry);
          try {
            if (statSync(entryPath).isDirectory()) {
              if (existsSync(join(entryPath, "SKILL.md"))) {
                if (!countedSkills.has(entry)) {
                  countedSkills.add(entry);
                  skills++;
                }
              }
            }
          } catch (error) {
            logDiscoveryError(
              `Failed to inspect skill entry ${entryPath}`,
              error,
            );
          }
        }
      } catch (error) {
        logDiscoveryError(`Failed to scan skills dir ${dir}`, error);
      }
    }
  }

  // Prompt templates
  const templateDirs = [
    join(homeDir, ".pi", "agent", "commands"),
    join(homeDir, ".claude", "commands"),
    join(cwd, ".pi", "commands"),
    join(cwd, ".claude", "commands"),
  ];

  const countedTemplates = new Set<string>();

  function countTemplatesInDir(dir: string) {
    if (!existsSync(dir)) return;
    try {
      const entries = readdirSync(dir);
      for (const entry of entries) {
        const entryPath = join(dir, entry);
        try {
          const stats = statSync(entryPath);
          if (stats.isDirectory()) {
            countTemplatesInDir(entryPath);
          } else if (entry.endsWith(".md")) {
            const name = basename(entry, ".md");
            if (!countedTemplates.has(name)) {
              countedTemplates.add(name);
              promptTemplates++;
            }
          }
        } catch (error) {
          logDiscoveryError(
            `Failed to inspect prompt template entry ${entryPath}`,
            error,
          );
        }
      }
    } catch (error) {
      logDiscoveryError(`Failed to scan prompt template dir ${dir}`, error);
    }
  }

  for (const dir of templateDirs) {
    countTemplatesInDir(dir);
  }

  return { contextFiles, extensions, skills, promptTemplates };
}

function getRecentSessions(maxCount: number = 3): RecentSession[] {
  const homeDir = process.env.HOME || process.env.USERPROFILE || osHomedir();

  const sessionsDirs = [
    join(homeDir, ".pi", "agent", "sessions"),
    join(homeDir, ".pi", "sessions"),
  ];

  const sessions: { name: string; mtime: number }[] = [];

  function scanDir(dir: string) {
    if (!existsSync(dir)) return;
    try {
      const entries = readdirSync(dir);
      for (const entry of entries) {
        const entryPath = join(dir, entry);
        try {
          const stats = statSync(entryPath);
          if (stats.isDirectory()) {
            scanDir(entryPath);
          } else if (entry.endsWith(".jsonl")) {
            const parentName = basename(dir);
            let projectName = parentName;
            if (parentName.startsWith("--")) {
              const parts = parentName.split("-").filter((p) => p);
              projectName = parts[parts.length - 1] || parentName;
            }
            sessions.push({ name: projectName, mtime: stats.mtimeMs });
          }
        } catch (error) {
          logDiscoveryError(
            `Failed to inspect session entry ${entryPath}`,
            error,
          );
        }
      }
    } catch (error) {
      logDiscoveryError(`Failed to scan sessions dir ${dir}`, error);
    }
  }

  for (const sessionsDir of sessionsDirs) {
    scanDir(sessionsDir);
  }

  if (sessions.length === 0) return [];

  sessions.sort((a, b) => b.mtime - a.mtime);

  const seen = new Set<string>();
  const uniqueSessions: typeof sessions = [];
  for (const s of sessions) {
    if (!seen.has(s.name)) {
      seen.add(s.name);
      uniqueSessions.push(s);
    }
  }

  const now = Date.now();
  return uniqueSessions.slice(0, maxCount).map((s) => ({
    name: s.name.length > 20 ? s.name.slice(0, 17) + "…" : s.name,
    timeAgo: formatTimeAgo(now - s.mtime),
  }));
}

function formatTimeAgo(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (days > 0) return `${days}d ago`;
  if (hours > 0) return `${hours}h ago`;
  if (minutes > 0) return `${minutes}m ago`;
  return "just now";
}

// ── Welcome Dismiss Scheduler ────────────────────────────────────────────

interface WelcomeDismissScheduler<Context> {
  schedule(ctx: Context): void;
  cancel(): void;
}

interface WelcomeDismissSchedulerOptions<Context> {
  dismiss(ctx: Context): void;
  getGeneration(): number;
  isEnabled(): boolean;
}

function createWelcomeDismissScheduler<Context>(
  options: WelcomeDismissSchedulerOptions<Context>,
): WelcomeDismissScheduler<Context> {
  let timer: ReturnType<typeof setTimeout> | null = null;

  return {
    schedule(ctx) {
      if (timer) return;

      const generation = options.getGeneration();
      timer = setTimeout(() => {
        timer = null;
        if (!options.isEnabled() || generation !== options.getGeneration())
          return;
        options.dismiss(ctx);
      }, 0);
    },
    cancel() {
      if (!timer) return;
      clearTimeout(timer);
      timer = null;
    },
  };
}

// ── Helper Functions ─────────────────────────────────────────────────────

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// ═══════════════════════════════════════════════════════════════════════════
// AGENT DATA & GREETING WIDGET (existing functionality)
// ═══════════════════════════════════════════════════════════════════════════

// ── Agent Data ────────────────────────────────────────────────────────────

interface AgentEntry {
  name: string;
  subtitle: string;
}

function loadDomainAgents(): AgentEntry[] {
  try {
    const agentsDir = join(osHomedir(), ".pi", "agent", "agents");
    return readdirSync(agentsDir)
      .filter(f => f.endsWith(".md"))
      .map(f => {
        const content = readFileSync(join(agentsDir, f), "utf-8");
        const name = content.match(/^name:\s*(.+)$/m)?.[1]?.trim() ?? basename(f, ".md");
        const subtitle = (content.match(/^description:\s*(.+)$/m)?.[1]?.trim() ?? "").replace(/^["']|["']$/g, "");
        return { name, subtitle };
      });
  } catch {
    return [];
  }
}

const ALL_DOMAIN_AGENTS: AgentEntry[] = loadDomainAgents();
const DOMAIN_OVERRIDE_NAMES = new Set(ALL_DOMAIN_AGENTS.map(a => a.name));

const PIPELINE_AGENT_NAMES = new Set(["scout", "oracle", "planner", "researcher", "reviewer", "context-builder", "worker", "delegate"]);

const TIER2_AGENTS: AgentEntry[] = [
  { name: "scout", subtitle: "recon" },
  { name: "oracle", subtitle: "consistency" },
  { name: "planner", subtitle: "planning" },
  { name: "researcher", subtitle: "web research" },
  { name: "reviewer", subtitle: "code review" },
  { name: "context-builder", subtitle: "deep analysis" },
  { name: "worker", subtitle: "implementation" },
  { name: "delegate", subtitle: "lightweight" },
].map(a => DOMAIN_OVERRIDE_NAMES.has(a.name) ? { ...a, subtitle: `${a.subtitle} · local` } : a);

const TIER3_AGENTS: AgentEntry[] = ALL_DOMAIN_AGENTS.filter(a => !PIPELINE_AGENT_NAMES.has(a.name));

// ── Agent Color Palette ──────────────────────────────────────────────────

const AGENT_COLORS: Record<string, { bg: string; br: string }> = {
  scout: { bg: "\x1b[48;2;12;40;65m", br: "\x1b[38;2;0;180;220m" },
  "context-builder": { bg: "\x1b[48;2;18;55;25m", br: "\x1b[38;2;80;190;80m" },
  oracle: { bg: "\x1b[48;2;65;30;18m", br: "\x1b[38;2;220;100;60m" },
  planner: { bg: "\x1b[48;2;45;20;70m", br: "\x1b[38;2;160;80;220m" },
  researcher: { bg: "\x1b[48;2;65;52;10m", br: "\x1b[38;2;200;170;40m" },
  reviewer: { bg: "\x1b[48;2;10;55;52m", br: "\x1b[38;2;40;190;170m" },
  worker: { bg: "\x1b[48;2;18;35;75m", br: "\x1b[38;2;60;120;230m" },
  delegate: { bg: "\x1b[48;2;65;20;58m", br: "\x1b[38;2;200;80;180m" },
  devops: { bg: "\x1b[48;2;65;18;25m", br: "\x1b[38;2;200;60;80m" },
  qa: { bg: "\x1b[48;2;30;22;70m", br: "\x1b[38;2;100;80;210m" },
  admin: { bg: "\x1b[48;2;38;52;15m", br: "\x1b[38;2;130;170;60m" },
};
const DEFAULT_COLORS = {
  bg: "\x1b[48;2;30;30;30m",
  br: "\x1b[38;2;120;120;120m",
};
const FG_RESET = "\x1b[39m";
const BG_RESET = "\x1b[49m";

function renderCard(
  name: string,
  subtitle: string,
  cardWidth: number,
): string[] {
  const { bg, br } = AGENT_COLORS[name] ?? DEFAULT_COLORS;
  const inner = cardWidth - 2;

  const bord = (s: string) => bg + br + s + BG_RESET + FG_RESET;
  const border = (content: string, visLen: number) => {
    const pad = " ".repeat(Math.max(0, inner - visLen));
    return bord("\u2502") + bg + content + bg + pad + BG_RESET + bord("\u2502");
  };

  const nameRaw = truncateToWidth(name, inner - 2, "...");
  const subRaw = truncateToWidth(subtitle, inner - 2, "...");

  const nameLine = border(
    " " + br + "\x1b[1m" + nameRaw + "\x1b[22m" + FG_RESET,
    1 + visibleWidth(nameRaw),
  );
  const statusLine = border(" " + "\x1b[2m" + "\u25cb idle" + "\x1b[22m", 7);
  const subLine = border(
    " " + "\x1b[2m" + subRaw + "\x1b[22m",
    1 + visibleWidth(subRaw),
  );
  const ulLine = border(" " + "\x1b[2m" + "_" + "\x1b[22m", 2);

  return [
    bord("\u250c" + "\u2500".repeat(inner) + "\u2510"),
    nameLine,
    statusLine,
    subLine,
    ulLine,
    bord("\u2514" + "\u2500".repeat(inner) + "\u2518"),
  ];
}

const GRID_KEY = "adjutant-agents";
const COLS = 3;
const CARD_GAP = 2;

function buildAgentGrid(width: number): string[] {
  const cardWidth = Math.floor((width - 1 - CARD_GAP * (COLS - 1)) / COLS);
  if (cardWidth < 14) return ["\x1b[2m terminal too narrow \x1b[22m"];

  const lines: string[] = [];

  const addGroup = (label: string, agents: AgentEntry[]) => {
    lines.push("");
    lines.push(" \x1b[2m" + label + "\x1b[22m");
    lines.push("");
    for (let i = 0; i < agents.length; i += COLS) {
      const row = agents.slice(i, i + COLS);
      const cards = row.map((a) => renderCard(a.name, a.subtitle, cardWidth));
      while (cards.length < COLS)
        cards.push(Array(6).fill(" ".repeat(cardWidth)));
      const h = cards[0].length;
      for (let l = 0; l < h; l++) {
        lines.push(
          " " + cards.map((c) => c[l] ?? "").join(" ".repeat(CARD_GAP)),
        );
      }
      lines.push("");
    }
  };

  addGroup("Pipeline Agents", TIER2_AGENTS);
  addGroup("Domain Agents", TIER3_AGENTS);
  return lines;
}

function buildAgentGridChat(termWidth: number): string[] {
  const cols = 3;
  const gap = 1;
  const cardWidth = Math.floor((termWidth - 1 - gap * (cols - 1)) / cols);
  if (cardWidth < 14) return ["\x1b[2m terminal too narrow \x1b[22m"];

  const chatLines: string[] = [];

  const addGroupChat = (label: string, agents: AgentEntry[]) => {
    chatLines.push("");
    chatLines.push(" \x1b[2m" + label + "\x1b[22m");
    chatLines.push("");
    for (let i = 0; i < agents.length; i += cols) {
      const row = agents.slice(i, i + cols);
      const cards = row.map((a) => renderCard(a.name, a.subtitle, cardWidth));
      while (cards.length < cols)
        cards.push(Array(6).fill(" ".repeat(cardWidth)));
      const h = cards[0].length;
      for (let l = 0; l < h; l++) {
        chatLines.push(
          " " + cards.map((c) => c[l] ?? "").join(" ".repeat(gap)),
        );
      }
      chatLines.push("");
    }
  };

  addGroupChat("Pipeline Agents", TIER2_AGENTS);
  addGroupChat("Domain Agents", TIER3_AGENTS);
  return chatLines;
}

// ── ASCII Art ────────────────────────────────────────────────────────────

const ASCII_ART = [
  " █████╗ ██████╗      ██╗██╗   ██╗████████╗ █████╗ ███╗   ██╗████████╗",
  "██╔══██╗██╔══██╗     ██║██║   ██║╚══██╔══╝██╔══██╗████╗  ██║╚══██╔══╝",
  "███████║██║  ██║     ██║██║   ██║   ██║   ███████║██╔██╗ ██║   ██║   ",
  "██╔══██║██║  ██║██   ██║██║   ██║   ██║   ██╔══██║██║╚██╗██║   ██║   ",
  "██║  ██║██████╔╝╚█████╔╝╚██████╔╝   ██║   ██║  ██║██║ ╚████║   ██║   ",
  "╚═╝  ╚═╝╚═════╝  ╚════╝  ╚═════╝    ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝  ",
];

let clockInterval: ReturnType<typeof setInterval> | undefined;

// ── GreetingWidget Component ────────────────────────────────────────────

class GreetingWidget {
  constructor(private readonly theme: Theme) {}

  private buildLines(width: number): string[] {
    const th = this.theme;

    // Center ASCII art
    const artWidth = visibleWidth(ASCII_ART[0] ?? "");
    const pad = Math.max(0, Math.floor((width - artWidth) / 2));
    const indent = " ".repeat(pad);

    // Live date + time
    const now = new Date();
    const datePart = now
      .toLocaleDateString("en-US", {
        weekday: "long",
        month: "long",
        day: "numeric",
        year: "numeric",
      })
      .replace(",", " -");
    const timePart = now.toLocaleTimeString("en-US", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });

    const msg1 = "Systems online. Awaiting your orders, commander.";
    const msg2 = `${datePart}  ·  ${timePart}`;
    const msgPad1 = " ".repeat(
      Math.max(0, Math.floor((width - visibleWidth(msg1)) / 2)),
    );
    const msgPad2 = " ".repeat(
      Math.max(0, Math.floor((width - visibleWidth(msg2)) / 2)),
    );

    return [
      "",
      "",
      ...ASCII_ART.map((line) =>
        truncateToWidth(th.fg("accent", indent + line), width),
      ),
      "",
      truncateToWidth(th.fg("muted", msgPad1 + msg1), width),
      truncateToWidth(th.fg("dim", msgPad2 + msg2), width),
      "",
      ...this.buildAgentList(width),
    ];
  }

  private buildAgentList(width: number): string[] {
    const th = this.theme;
    const COLS = 3;
    const colWidth = Math.floor((width - 2) / COLS);
    const lines: string[] = [];

    const padRight = (s: string, visW: number, toW: number) =>
      s + " ".repeat(Math.max(0, toW - visW));

    const formatAgent = (agent: AgentEntry): string => {
      const { br } = AGENT_COLORS[agent.name] ?? DEFAULT_COLORS;
      const maxNameW = Math.floor(colWidth * 0.48);
      const maxSubW = colWidth - maxNameW - 3;
      const nameStr = truncateToWidth(agent.name, maxNameW, "…");
      const subStr = truncateToWidth(agent.subtitle, maxSubW, "…");
      const entry = `${br}${nameStr}${FG_RESET} \x1b[2m(${subStr})\x1b[22m`;
      const entryVisW = visibleWidth(nameStr) + 2 + visibleWidth(subStr) + 1;
      return padRight(entry, entryVisW, colWidth);
    };

    const renderGroup = (label: string, agents: AgentEntry[]) => {
      lines.push(`  ${th.fg("dim", label)}`);
      for (let i = 0; i < agents.length; i += COLS) {
        const row = agents.slice(i, i + COLS);
        lines.push(
          truncateToWidth("  " + row.map(formatAgent).join(""), width),
        );
      }
      lines.push("");
    };

    renderGroup("pipeline", TIER2_AGENTS);
    renderGroup("domain", TIER3_AGENTS);
    return lines;
  }

  render(width: number): string[] {
    return this.buildLines(width);
  }

  invalidate(): void {}
}

// ═══════════════════════════════════════════════════════════════════════════
// EXTENSION — Integration Point
// ═══════════════════════════════════════════════════════════════════════════

const WIDGET_KEY = "adjutant-greeting";

// Welcome overlay state
let dismissWelcomeOverlay: (() => void) | null = null;
let welcomeOverlayShouldDismiss = false;
let sessionGeneration = 0;
let enabled = true;

export default function (pi: ExtensionAPI) {
  // Create dismissal scheduler
  const welcomeDismissScheduler = createWelcomeDismissScheduler({
    dismiss: (ctx: any) => dismissWelcome(ctx),
    getGeneration: () => sessionGeneration,
    isEnabled: () => enabled,
  });

  // Dismissal logic
  function dismissWelcome(ctx: any) {
    welcomeDismissScheduler.cancel();

    if (dismissWelcomeOverlay) {
      dismissWelcomeOverlay();
      dismissWelcomeOverlay = null;
    } else {
      welcomeOverlayShouldDismiss = true;
    }
  }

  // Welcome overlay setup
  function setupWelcomeOverlay(ctx: any) {
    const modelName = ctx.model?.name || ctx.model?.id || "No model";
    const providerName = ctx.model?.provider || "Unknown";
    const loadedCounts = discoverLoadedCounts();
    const recentSessions = getRecentSessions(3);

    const overlaySessionGeneration = sessionGeneration;

    // Small delay to let pi finish initialization
    setTimeout(() => {
      // Bail early if conditions changed
      if (
        !enabled ||
        welcomeOverlayShouldDismiss ||
        overlaySessionGeneration !== sessionGeneration
      ) {
        welcomeOverlayShouldDismiss = false;
        return;
      }

      // Check for existing session activity
      const sessionEvents = ctx.sessionManager?.getBranch?.() ?? [];
      const hasActivity = sessionEvents.some((entry: unknown) => {
        if (!isRecord(entry)) return false;
        if (entry.type === "tool_call" || entry.type === "tool_result")
          return true;
        return (
          entry.type === "message" &&
          isRecord(entry.message) &&
          entry.message.role === "assistant"
        );
      });
      if (hasActivity) return;

      // Mount overlay component
      ctx.ui
        .custom(
          (
            tui: any,
            _theme: any,
            _keybindings: any,
            done: (result: void) => void,
          ) => {
            const welcome = new WelcomeComponent(
              modelName,
              providerName,
              recentSessions,
              loadedCounts,
            );

            let countdown = 20; // 10 seconds for adjutant
            let dismissed = false;
            let interval: ReturnType<typeof setInterval> | null = null;
            let unsubscribeTerminalInput: (() => void) | null = null;

            const dismiss = () => {
              if (dismissed) return;
              dismissed = true;
              if (interval) clearInterval(interval);
              unsubscribeTerminalInput?.();
              unsubscribeTerminalInput = null;
              dismissWelcomeOverlay = null;
              done();
            };

            unsubscribeTerminalInput = ctx.ui.onTerminalInput(() => {
              dismiss();
              return { consume: true };
            });

            // Auto-dismiss countdown
            interval = setInterval(() => {
              if (dismissed) return;
              countdown--;
              welcome.setCountdown(countdown);
              tui.requestRender();
              if (countdown <= 0) dismiss();
            }, 1000);

            // Set global dismiss handle
            dismissWelcomeOverlay = dismiss;

            // Check pre-emptive dismiss flag
            if (welcomeOverlayShouldDismiss) {
              welcomeOverlayShouldDismiss = false;
              dismiss();
            }

            return {
              focused: false,
              invalidate: () => welcome.invalidate(),
              render: (width: number) => welcome.render(width),
              handleInput: () => dismiss(),
              dispose: () => {
                dismissed = true;
                if (interval) clearInterval(interval);
                unsubscribeTerminalInput?.();
                unsubscribeTerminalInput = null;
              },
            };
          },
          {
            overlay: true,
            overlayOptions: () => ({
              verticalAlign: "center",
              horizontalAlign: "center",
            }),
          },
        )
        .catch((error) => {
          console.debug("[adjutant-greeting] Welcome overlay failed:", error);
        });
    }, 100);
  }

  // ── Event Handlers ───────────────────────────────────────────────────

  pi.on("session_start", (event, ctx) => {
    if (!ctx.hasUI) return;

    sessionGeneration++;

    // Show welcome overlay on startup or new session (not on resume)
    if (
      event.reason === "reload" ||
      event.reason === "new_session" ||
      event.reason === "startup"
    ) {
      setupWelcomeOverlay(ctx);
    } else {
      // Resume session - dismiss any pending overlay
      dismissWelcome(ctx);
    }

    // Startup greeting widget disabled for a cleaner, pristine workspace.
    // Roster remains accessible on-demand via the /agents slash command.
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!ctx.hasUI) return;

    // Dismiss welcome overlay
    dismissWelcome(ctx);

    // Clear greeting widget and clock
    if (clockInterval) {
      clearInterval(clockInterval);
      clockInterval = undefined;
    }
    ctx.ui.setWidget(WIDGET_KEY, undefined);
  });

  pi.on("tool_call", (_event, ctx) => {
    // Dismiss welcome overlay on first tool call
    dismissWelcome(ctx);
  });

  pi.on("session_shutdown", async () => {
    sessionGeneration++;
    dismissWelcomeOverlay?.();
    dismissWelcomeOverlay = null;
    welcomeOverlayShouldDismiss = false;
    welcomeDismissScheduler.cancel();
    enabled = false;
  });

  // ── Tools & Commands ─────────────────────────────────────────────────

  pi.registerTool({
    name: "show_agents",
    label: "Show Agents",
    description: "Display the Adjutant agent roster as a colored card grid.",
    parameters: Type.Object({}),
    execute: async (_callId, _params, _signal, _onUpdate, ctx) => {
      const termWidth = Math.max(60, (process.stdout.columns || 120) - 6);
      const lines = buildAgentGridChat(termWidth);
      if (ctx.hasUI) {
        ctx.ui.notify(lines.join("\n"), "info");
      }
      return {
        content: [{ type: "text", text: "Agent roster displayed." }],
      };
    },
  });

  pi.registerCommand("agents", {
    description: "Show the Adjutant agent roster card grid",
    handler: async (_args, ctx) => {
      if (!ctx.hasUI) return;
      ctx.ui.setWidget(GRID_KEY, (_tui, _theme) => ({
        render: (w: number) => buildAgentGrid(w),
        invalidate: () => {},
      }));
    },
  });

  pi.registerCommand("agents-hide", {
    description: "Hide the agent roster card grid",
    handler: async (_args, ctx) => {
      if (!ctx.hasUI) return;
      ctx.ui.setWidget(GRID_KEY, undefined);
    },
  });
}
