/**
 * harness-audit-gate.ts — fail-fast harness invariant gate
 *
 * On session_start, runs ~/.pi/agent/harness-audit.sh (which statically asserts
 * HARNESS_INVARIANTS — model pins, delegation guards, cost observability) and
 * surfaces ANY invariant failure LOUDLY in the first second, so config drift /
 * "committed-but-not-live" is caught before an expensive session, not after.
 *
 * Non-blocking by design: a failing audit screams via ctx.ui.notify("error")
 * but NEVER prevents the session from starting. Note: the gate fires at
 * session_start only — drift introduced
 * mid-session (e.g. /model persisting to settings.json) surfaces on the NEXT
 * session, not immediately. Best-effort: a missing/erroring script logs one warning and
 * continues — the audit must never crash the session.
 *
 * Only surfaces in the main (UI) process; subagents skip to avoid noise.
 */

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const AUDIT_TIMEOUT_MS = 15_000;

const isSubagent = process.env.PI_SUBAGENT_CHILD === "1";

// Resolve the harness dir from this file's own location, falling back to the
// conventional ~/.pi/agent. Cross-platform: never hardcode an absolute /home.
function resolveHarnessDir(): string {
	try {
		// extensions/ lives directly under the harness root.
		const here = dirname(fileURLToPath(import.meta.url));
		const root = dirname(here);
		if (existsSync(join(root, "harness-audit.sh"))) return root;
	} catch {
		// import.meta / URL unavailable — fall through to homedir default.
	}
	return join(homedir(), ".pi", "agent");
}

// Strip ANSI color codes the bash script emits, for clean notify text.
function stripAnsi(s: string): string {
	// eslint-disable-next-line no-control-regex
	return s.replace(/\x1b\[[0-9;]*m/g, "");
}

interface AuditResult {
	ok: boolean;
	exitCode: number;
	output: string;
	failLines: string[];
}

function runAudit(harnessDir: string, scriptPath: string): AuditResult {
	let stdout = "";
	let exitCode = 0;

	try {
		stdout = execFileSync("bash", [scriptPath], {
			cwd: harnessDir,
			timeout: AUDIT_TIMEOUT_MS,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "pipe"],
		});
	} catch (err) {
		// Non-zero exit lands here; execFileSync attaches status + captured streams.
		const e = err as { status?: number; stdout?: string; stderr?: string };
		exitCode = typeof e.status === "number" ? e.status : 1;
		stdout = `${e.stdout ?? ""}${e.stderr ?? ""}`;
	}

	const clean = stripAnsi(stdout);
	const failLines = clean
		.split("\n")
		.filter((l: string) => /\bFAIL\b/.test(l))
		.map((l: string) => l.trim());

	return { ok: exitCode === 0, exitCode, output: clean, failLines };
}

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (_event, ctx) => {
		// Only gate in the main UI process — subagents skip to avoid noise.
		if (isSubagent) return;
		if (!ctx.hasUI) return;

		try {
			const harnessDir = resolveHarnessDir();
			const scriptPath = join(harnessDir, "harness-audit.sh");

			if (!existsSync(scriptPath)) {
				ctx.ui.notify(
					`harness-audit: script not found at ${scriptPath} — invariant gate skipped`,
					"warning",
				);
				return;
			}

			const result = runAudit(harnessDir, scriptPath);

			if (result.ok) {
				return;
			}

			// LOUD: fire a warning notification carrying the exact failing
			// invariant lines.
			const body = result.failLines.length > 0
				? result.failLines.join("\n")
				: `audit exited ${result.exitCode} (no FAIL lines parsed)`;

			ctx.ui.notify(
				`HARNESS INVARIANT FAILURE — config drift / committed-but-not-live detected:\n${body}\n` +
				`Run: bash ${scriptPath}`,
				"error",
			);
		} catch (err) {
			// Best-effort — the audit gate must NEVER crash the session.
			const msg = err instanceof Error ? err.message : String(err);
			ctx.ui.notify(`harness-audit gate error (non-fatal): ${msg}`, "warning");
		}
	});
}
