/**
 * context-profile-picker.ts — Interactive context profile selector
 *
 * Hooks into session_start to mark eligibility, then prompts from
 * before_agent_start on the first turn (when interactive input loop is live).
 * Reads available profiles from ~/.pi/agent/profiles/ and sets
 * process.env.PI_PROFILE for the current session (no file write needed;
 * context-resolver.ts re-reads env on every turn).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

interface ContextProfilePickerConfig {
  enabled: boolean;
}

function readConfig(): ContextProfilePickerConfig {
  const defaults: ContextProfilePickerConfig = { enabled: true };
  try {
    const settingsPath = join(homedir(), ".pi", "agent", "settings.json");
    if (!existsSync(settingsPath)) return defaults;
    const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
    const enabled = settings?.contextProfilePicker?.enabled;
    return {
      enabled: typeof enabled === "boolean" ? enabled : defaults.enabled,
    };
  } catch {
    return defaults;
  }
}

interface ProfileEntry {
  name: string;
  label: string;
}

function readAvailableProfiles(): ProfileEntry[] {
  const profilesDir = join(homedir(), ".pi", "agent", "profiles");
  if (!existsSync(profilesDir)) return [];

  try {
    const files = readdirSync(profilesDir);
    const markdownFiles = files.filter((f) => f.endsWith(".md"));

    const profiles: ProfileEntry[] = markdownFiles.map((file) => {
      const name = file.slice(0, -3);
      const filePath = join(profilesDir, file);

      let label = name;
      try {
        const content = readFileSync(filePath, "utf-8");
        const firstLine = content.split("\n")[0];
        if (firstLine?.startsWith("#")) {
          label = firstLine.slice(1).trim();
        }
      } catch {
        // Fall back to profile name if file read fails
      }

      return { name, label };
    });

    return profiles;
  } catch {
    return [];
  }
}

// Module-scope state: set during session_start, checked during before_agent_start
let eligibleToPrompt = false;
let alreadyPrompted = false;

export default function (pi: ExtensionAPI): void {
  const config = readConfig();

  // Phase 1: session_start — cheap, synchronous eligibility check only
  pi.on("session_start", (event, ctx) => {
    // Reset state for new session
    alreadyPrompted = false;

    // Early returns: no UI, feature disabled, or not a new session type
    if (!ctx.hasUI) {
      eligibleToPrompt = false;
      return;
    }
    if (!config.enabled) {
      eligibleToPrompt = false;
      return;
    }

    // Only prompt on startup, reload, and new; skip resume and fork
    const promptableReasons = ["startup", "reload", "new"] as const;
    if (!promptableReasons.includes(event.reason as typeof promptableReasons[number])) {
      eligibleToPrompt = false;
      return;
    }

    // If PI_PROFILE is already set explicitly, respect that choice
    if (process.env.PI_PROFILE) {
      eligibleToPrompt = false;
      return;
    }

    // All checks passed — we are eligible to prompt on first turn
    eligibleToPrompt = true;
  });

  // Phase 2: before_agent_start — do the actual prompting on first turn only
  pi.on("before_agent_start", async (event, ctx) => {
    // Only proceed if session_start deemed this session eligible AND we haven't prompted yet
    if (!eligibleToPrompt || alreadyPrompted) return;

    // Set flag immediately (before awaiting) to prevent double-prompt on concurrent/slow turns
    alreadyPrompted = true;

    // Read available profiles
    const profiles = readAvailableProfiles();
    if (profiles.length === 0) return;

    // Build choice labels from profiles
    const choices = profiles.map((p) => p.label);

    // Prompt user with the harness's native dialog timeout (not a manual
    // Promise.race — that only resolves a value, it never tells the actual
    // dialog widget to unmount, which is what caused the picker to stay
    // mounted and keep redrawing on top of the streaming response after the
    // race "timed out" (known incident: session appeared stuck/looping).
    // The native { timeout } option properly auto-dismisses the widget
    // itself (see docs/extensions.md "Timed Dialogs with Countdown").
    const selected = await ctx.ui.select(
      "Choose a context profile for this session:",
      choices,
      { timeout: 10000 },
    );

    // On cancel or timeout (undefined), silently use default resolution chain (env → settings → "default")
    if (selected === undefined) return;

    // Map label back to profile name
    const profile = profiles.find((p) => p.label === selected);
    if (!profile) return;

    // Set environment variable for this session
    process.env.PI_PROFILE = profile.name;

    // Notify user
    ctx.ui.notify(
      `Context profile set to '${profile.name}' for this session.`,
      "info",
    );
  });
}
