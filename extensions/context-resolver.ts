import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, existsSync } from "fs";
import { homedir } from "os";
import { join, resolve } from "path";

interface ExpandResult {
  prompt: string;
  resolved: string[];
  failed: string[];
}

const MAX_EXPAND_DEPTH = 5;

function expandSystemPrompt(prompt: string, depth = 0, seen: Set<string> = new Set()): ExpandResult {
  const resolved: string[] = [];
  const failed: string[] = [];

  if (depth > MAX_EXPAND_DEPTH) {
    return { prompt, resolved, failed };
  }

  const lines = prompt.split("\n");
  const expanded: string[] = [];

  for (const line of lines) {
    if (line.trim().startsWith("@")) {
      const relPath = line.trim().slice(1);
      const absPath = relPath.startsWith("~")
        ? relPath.replace(/^~/, homedir())
        : resolve(relPath);

      if (seen.has(absPath)) {
        // Cycle guard — already expanded higher up this chain; keep the line inert.
        expanded.push(line);
        continue;
      }

      if (existsSync(absPath)) {
        const raw = readFileSync(absPath, "utf-8");
        const inner = expandSystemPrompt(raw, depth + 1, new Set(seen).add(absPath));

        expanded.push(`\n<!-- BEGIN DYNAMIC RESOLUTION: ${relPath} -->\n`);
        expanded.push(inner.prompt);
        expanded.push(`\n<!-- END DYNAMIC RESOLUTION: ${relPath} -->\n`);

        resolved.push(relPath, ...inner.resolved);
        failed.push(...inner.failed);
      } else {
        expanded.push(line);
        failed.push(relPath);
      }
    } else {
      expanded.push(line);
    }
  }

  return { prompt: expanded.join("\n"), resolved: [...new Set(resolved)], failed };
}

const VALID_PROFILES = ["default", "ntv", "pi-harness", "desktop", "brainstorm"] as const;
type Profile = (typeof VALID_PROFILES)[number];

function isValidProfile(v: string): v is Profile {
  return (VALID_PROFILES as readonly string[]).includes(v);
}

function readActiveProfile(agentDir: string): { profile: Profile; source: string; warning?: string } {
  const envProfile = process.env.PI_PROFILE;
  if (envProfile) {
    if (isValidProfile(envProfile)) {
      return { profile: envProfile, source: "PI_PROFILE env" };
    }
    // Unknown env value — fall through to settings.json / default, but say so.
    const warning = `⚠️ PI_PROFILE="${envProfile}" is not a recognized profile (${VALID_PROFILES.join(", ")}) — ignoring`;

    const settingsPath = join(agentDir, "settings.json");
    if (existsSync(settingsPath)) {
      try {
        const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
        if (settings.contextProfile && isValidProfile(settings.contextProfile)) {
          return { profile: settings.contextProfile, source: "settings.json", warning };
        }
      } catch {
        // Malformed settings.json — ignore, fall through to default.
      }
    }
    return { profile: "default", source: "fallback", warning };
  }

  const settingsPath = join(agentDir, "settings.json");
  if (existsSync(settingsPath)) {
    try {
      const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
      if (settings.contextProfile && isValidProfile(settings.contextProfile)) {
        return { profile: settings.contextProfile, source: "settings.json" };
      }
    } catch {
      // Malformed settings.json — ignore, fall through to default.
    }
  }

  return { profile: "default", source: "fallback" };
}

const DEFAULT_PROFILE_SENTINEL = "@~/.pi/agent/profiles/default.md";

export default function (pi: ExtensionAPI) {
  pi.on("before_agent_start", async (event, ctx) => {
    const agentDir = join(homedir(), ".pi", "agent");
    const { profile, source, warning } = readActiveProfile(agentDir);

    let systemPrompt = event.systemPrompt;
    const notifyLines: string[] = [];
    if (warning) notifyLines.push(warning);

    if (profile !== "default") {
      const profileAbsPath = join(agentDir, "profiles", `${profile}.md`);
      if (!existsSync(profileAbsPath)) {
        notifyLines.push(`⚠️ profile "${profile}" file missing — using default`);
      } else if (!systemPrompt.includes(DEFAULT_PROFILE_SENTINEL)) {
        notifyLines.push(`⚠️ profile sentinel not found — using embedded @includes (no substitution)`);
      } else {
        systemPrompt = systemPrompt.replace(
          DEFAULT_PROFILE_SENTINEL,
          `@~/.pi/agent/profiles/${profile}.md`,
        );
      }
    }

    const { prompt: resolvedPrompt, resolved, failed } = expandSystemPrompt(systemPrompt);

    notifyLines.push(`🎯 Profile: ${profile} (${source})`);
    if (resolved.length) notifyLines.push(`✓ ${resolved.join(", ")}`);
    if (failed.length) notifyLines.push(`✗ MISSING: ${failed.join(", ")}`);

    ctx.ui.notify(notifyLines.join(" | "), failed.length > 0 || warning ? "warning" : "info");

    return {
      systemPrompt: resolvedPrompt,
    };
  });
}
