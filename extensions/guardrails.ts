import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import { execSync } from "child_process";

export function isProtectedPath(filePath: string): boolean {
  const protectedScriptPatterns = [
    /ntv-rpi-prep/,
    /ntv-rpi-imager/,
    /-prep\.sh$/,
    /-imager\.sh$/,
    /-deploy/,
    /player-scripts/,
  ];
  return protectedScriptPatterns.some(p => p.test(filePath)) ||
    (/\.sh$/.test(filePath) && /(deploy|prep|imager|device|rpi)/.test(filePath));
}

export function isValidReviewMarker(cmd: string): boolean {
  const match = cmd.match(/Reviewed-by:\s+reviewer\/([a-zA-Z0-9]+)/i);
  return match !== null && /^[a-f0-9]{8,}$/.test(match[1]);
}

// Strips heredoc bodies (`<<EOF ... EOF` / `<<'EOF' ... EOF`) before pattern
// matching, so embedded documentation/review text (e.g. an ssh/rm -rf example,
// or a "git commit" mention) isn't mistaken for a literal shell invocation.
export function stripHeredocBodies(input: string): string {
  const lines = input.split("\n");
  const out: string[] = [];
  let delimiter: string | null = null;
  for (const line of lines) {
    if (delimiter === null) {
      const m = line.match(/<<-?\s*['"]?(\w+)['"]?\s*$/);
      if (m) {
        delimiter = m[1];
        out.push(line); // keep opener line
      } else {
        out.push(line);
      }
    } else {
      if (line.trim() === delimiter) {
        delimiter = null;
        out.push(line); // keep closing delimiter line
      }
      // else: silently drop body line
    }
  }
  return out.join("\n");
}

// Strips the *contents* of quoted string literals (single and double quoted),
// leaving the quote markers behind. Catches the case a heredoc-only stripper
// misses: a single-quoted payload passed inline on one `python3 -c '...'` line
// (or spanning multiple physical lines within the quotes, e.g. a triple-quoted
// Python string) that happens to contain the words "git commit"/"git push" as
// prose rather than as an actual command.
// ponytail: naive char-class scan — doesn't perfectly handle an escaped quote
// nested inside the opposite quote style (e.g. "it's" inside single quotes
// ends the string early). Good enough for the git-commit/push detector below;
// revisit if that produces a real false negative.
export function stripQuotedStrings(input: string): string {
  return input
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

// Combined sanitizer for the git commit/push detector: strips heredoc bodies
// and quoted-string contents so embedded prose can't be mistaken for an
// actual `git commit`/`git push` invocation, or for a `PI_REVIEW_OVERRIDE=1`
// prefix.
export function sanitizeForGitDetection(input: string): string {
  return stripQuotedStrings(stripHeredocBodies(input));
}

export function getChangedPaths(cmdType: "commit" | "push", cwd: string): string[] | null {
  try {
    if (cmdType === "commit") {
      const output = execSync("git diff --cached --diff-filter=ACMR --name-only -z", { cwd, stdio: "pipe" });
      return output.toString("utf8").split("\0").filter(Boolean);
    } else {
      const output = execSync("git diff --diff-filter=ACMR --name-only -z @{u}..HEAD", { cwd, stdio: "pipe" });
      return output.toString("utf8").split("\0").filter(Boolean);
    }
  } catch {
    return null;
  }
}

const pendingBackups = new Map<string, string | "NEW_FILE">();

export default function (pi: ExtensionAPI) {
  // ── Universal Dry-Run/Validation Gateway ──────────────────────────────
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "edit" || event.toolName === "write") {
      const targetFile = event.input.path as string;
      if (!targetFile) return;

      if (fs.existsSync(targetFile)) {
        const hash = crypto.randomBytes(8).toString("hex");
        const tmpPath = `/tmp/backup_${hash}_${path.basename(targetFile)}`;
        fs.copyFileSync(targetFile, tmpPath);
        pendingBackups.set(event.callId, tmpPath);
      } else {
        pendingBackups.set(event.callId, "NEW_FILE");
      }
    }
  });

  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName === "edit" || event.toolName === "write") {
      const backupPath = pendingBackups.get(event.callId);
      if (!backupPath) return;

      const targetFile = event.input.path as string;
      const ext = path.extname(targetFile);
      const fileName = path.basename(targetFile);

      let validator: string | null = null;
      if (ext === ".sh") validator = `bash -n ${targetFile}`;
      else if (ext === ".js") validator = `node -c ${targetFile}`;
      else if (ext === ".json") validator = `jq empty ${targetFile}`;
      else if (fileName === "config" && targetFile.includes("i3")) validator = `i3 -C -c ${targetFile}`;

      if (validator) {
        try {
          execSync(validator, { stdio: "pipe" });
        } catch (e: any) {
          // Validation failed: revert
          if (backupPath === "NEW_FILE") {
            if (fs.existsSync(targetFile)) fs.unlinkSync(targetFile);
          } else {
            fs.copyFileSync(backupPath, targetFile);
          }

          // Override the tool result so the LLM sees the error
          const stderr = e.stderr ? e.stderr.toString() : e.message;
          const newResult = {
            error: "Validation failed, file reverted.",
            validator: validator,
            details: stderr
          };
          
          if (typeof event.result === "string") {
            event.result = JSON.stringify(newResult);
          } else {
            // Assume object format
            (event.result as any).data = newResult;
          }
        }
      }

      // Cleanup
      if (backupPath !== "NEW_FILE" && fs.existsSync(backupPath)) {
        fs.unlinkSync(backupPath);
      }
      pendingBackups.delete(event.callId);
    }
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash" && event.toolName !== "safe_bash") return;
    const cmd = event.input.command ?? "";
    let rmHandled = false;
    // Sanitized view used anywhere we're detecting an actual `git commit`/
    // `git push` invocation (or an inline `PI_REVIEW_OVERRIDE=1` prefix) —
    // strips quoted-string/heredoc bodies so embedded prose mentioning those
    // words doesn't get mistaken for the real thing. Do NOT use this for
    // isValidReviewMarker: that reads the actual `-m` commit message, which
    // lives inside the quotes we strip here.
    const cmdForGitDetection = sanitizeForGitDetection(cmd);

    // Protected paths and dangerous bash ops...
    const watchedConfigDirs = [
      /rm\s+-rf?\s+~?\/?home\/[^/]+\/\.config\/hypr/,
      /rm\s+-rf?\s+~?\/?home\/[^/]+\/\.config\/waybar/,
      /rm\s+-rf?\s+~?\/?home\/[^/]+\/\.config\/i3/,
      /rm\s+-rf?\s+~?\/?home\/[^/]+\/\.config\/sway/,
    ];
    if (watchedConfigDirs.some(p => p.test(cmd))) {
      const ok = await ctx.ui.confirm("GUARDRAIL", `rm -rf on a compositor config detected. Proceed anyway?`);
      rmHandled = true;
      if (!ok) return { block: true, reason: "Blocked" };
    }
    const liveServiceConfigs = [
      /tee\s+.*\/(systemd|hypr|waybar|i3|sway|picom)\/.*\.conf/,
      /tee\s+.*\.service$/,
      />\s*~?\/?etc\/systemd/,
    ];
    if (liveServiceConfigs.some(p => p.test(cmd))) {
      const ok = await ctx.ui.confirm("GUARDRAIL", `Live service config overwrite detected. Proceed?`);
      if (!ok) return { block: true, reason: "Blocked" };
    }
    const projectPaths = [
      process.env.NTV_DIR ?? "/data/dev/work/ntv",
      "/var/www/html",
    ].filter(Boolean);
    for (const projectPath of projectPaths) {
      const escaped = projectPath.replace(/[\/]/g, "\\/");
      if (new RegExp(`rm\\s+-rf?\\s+${escaped}`).test(cmd)) {
        const ok = await ctx.ui.confirm("GUARDRAIL", `rm -rf on project path detected. Allow?`);
        rmHandled = true;
        if (!ok) return { block: true, reason: `Blocked` };
      }
    }
    // General rm -rf catch-all (paths not covered by specific guards above)
    if (/rm\s+-rf?\s+/.test(cmd) && !rmHandled) {
      const isIsolated = cmd.includes("/tmp/") && !cmd.includes("~") && !cmd.includes("/home/");
      if (!isIsolated) {
        const ok = await ctx.ui.confirm("GUARDRAIL", `rm -rf detected. Proceed?`);
        if (!ok) return { block: true, reason: "Blocked" };
      }
    }
    if (/>\s*(\.env|auth\.json|\.runner\/\.env|ec2_key\.pem)/.test(cmd)) {
      return { block: true, reason: "Blocked" };
    }
    if (/infisical\s+(secrets|export)/.test(cmd)) {
      return { block: true, reason: "Blocked" };
    }
    // ── Post-Mutation Review Gate (hook-layer enforcement) ────────────────
    // Prompt-level gate (APPEND_SYSTEM.md) was walked past by direct-to-main
    // commits. Enforce here: device/deploy script changes cannot land on
    // main/master without a reviewer sign-off marker. Hard block, not confirm
    // (confirms get rubber-stamped).
    const isCommit = /git\s+commit/.test(cmdForGitDetection);
    const isPush = /git\s+push/.test(cmdForGitDetection);
    if (isCommit || isPush) {
      const cwd = (event.input.cwd as string) ?? process.cwd();

      // Resolve current branch (best-effort; non-git dirs just skip the gate).
      let currentBranch = "";
      try {
        currentBranch = execSync("git rev-parse --abbrev-ref HEAD", {
          cwd,
          stdio: "pipe",
        }).toString().trim();
      } catch {
        currentBranch = "";
      }

      const protectedBranches = ["main", "master"];
      // A commit advances main/master only when HEAD is on main/master.
      // A push targets main/master when HEAD is on it OR the refspec names it.
      const branchPattern = new RegExp(`\\b(${protectedBranches.join("|")})\\b`);
      const advancesProtected =
        (isCommit && protectedBranches.includes(currentBranch)) ||
        (isPush && (protectedBranches.includes(currentBranch) || branchPattern.test(cmdForGitDetection)));

      if (advancesProtected) {
        const changedPaths = getChangedPaths(isCommit ? "commit" : "push", cwd);
        const requiresReview = changedPaths === null || changedPaths.some(isProtectedPath);

        if (requiresReview) {
          // Review markers that lift the block.
          const hasReviewedByTrailer = isValidReviewMarker(cmd);
          // process.env here is the hook's own (already-running) Node process —
          // an inline `PI_REVIEW_OVERRIDE=1 <cmd>` prefix on the bash command is
          // an env assignment meant for the *child* process the shell is about
          // to spawn; it never touches the hook's process.env. Also detect it
          // as a literal prefix in the command text itself (sanitized, so a
          // heredoc/quoted mention of it can't forge an override).
          const hasOverrideEnv =
            process.env.PI_REVIEW_OVERRIDE === "1" ||
            /(^|[;&|\s])PI_REVIEW_OVERRIDE=1(\s|$)/.test(cmdForGitDetection);
          let hasReviewMarkerFile = false;
          try {
            hasReviewMarkerFile = fs.existsSync(path.join(cwd, ".review-pass"));
          } catch {
            hasReviewMarkerFile = false;
          }

          if (!hasReviewedByTrailer && !hasOverrideEnv && !hasReviewMarkerFile) {
            return {
              block: true,
              reason:
                "BLOCKED: device/deploy script change to main requires reviewer sign-off. " +
                "Route through `reviewer` (Post-Mutation Review Gate) and add a 'Reviewed-by:' trailer " +
                "to the commit message, or set PI_REVIEW_OVERRIDE=1 for a documented emergency.",
            };
          }
        }
      }
    }

    if (isPush) {
      if (/--force|(?<![a-zA-Z])-f(?![a-zA-Z])/.test(cmdForGitDetection)) {
        return { block: true, reason: "Blocked" };
      }
      const productionBranches = ["main", "master", process.env.DEPLOY_BRANCH ?? "dev-deploy-environment"];
      const branchPattern = new RegExp(`\\b(${productionBranches.join("|")})\\b`);
      if (branchPattern.test(cmdForGitDetection)) {
        const ok = await ctx.ui.confirm("GUARDRAIL", `git push to production branch detected. Allow?`);
        if (!ok) return { block: true, reason: "Blocked" };
      }
    }
    if (/git\s+reset\s+--hard/.test(cmd)) {
      const isIsolated = cmd.includes("/tmp/") && !cmd.includes("~") && !cmd.includes("/home/");
      if (!isIsolated) {
        const ok = await ctx.ui.confirm("GUARDRAIL", `git reset --hard detected. Proceed?`);
        if (!ok) return { block: true, reason: "Blocked" };
      }
    }
    // Heredoc bodies stripped before pattern matching to prevent false-positives.
    // A heredoc can embed documentation text (e.g. ssh/rm -rf examples) that
    // should NOT be treated as actual shell commands.
    const cmdSafe = stripHeredocBodies(cmd);

    if (/\b(ssh|scp|sshpass)\b/.test(cmdSafe)) {
      // Word-boundaried file ops (avoid matching cpu/thermal/firmware/used/adapter in diagnostic text)
      const destructiveFileOps = /\brm\b|\bsed\b\s+-i|\bcp\b|\bmv\b|\btruncate\b|\breboot\b|\bshutdown\b|\bpoweroff\b/.test(cmd);
      // Service/package/process managers: flag MUTATING subcommands only — read-only status/logs/list/show stay free
      const serviceMutation = /\b(systemctl|service)\s+(start|stop|restart|reload|enable|disable|mask)\b/.test(cmd);
      const pm2Mutation = /\bpm2\s+(restart|stop|delete|reload|kill|start|scale|flush)\b/.test(cmd);
      const aptMutation = /\bapt(-get)?\s+(install|remove|purge|upgrade|dist-upgrade|autoremove)\b/.test(cmd);
      const isDestructive = destructiveFileOps || serviceMutation || pm2Mutation || aptMutation;
      if (isDestructive) {
        const ok = await ctx.ui.confirm("GUARDRAIL", `Destructive SSH/SCP operation detected. Allow?`);
        if (!ok) return { block: true, reason: "Blocked" };
      }
    }
    if (/npm\s+publish/.test(cmd)) {
      return { block: true, reason: "Blocked" };
    }
    if (/apt(-get)?\s+(remove|purge)/.test(cmd)) {
      const ok = await ctx.ui.confirm("GUARDRAIL", `apt remove/purge detected. Proceed?`);
      if (!ok) return { block: true, reason: "Blocked" };
    }
  });
}
