/**
 * TUI Dry-Run Guard
 *
 * Intercepts Edit/Write calls to TUI extension files containing ANSI patterns.
 * Requires dry-run confirmation before applying changes to active extensions.
 * Provides validate_ansi_output tool to test rendering in isolation.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const ANSI_PATTERNS = [
	/\\x1b\[/,
	/\\033\[/,
	/\\u001b\[/,
	/\x1b\[/,
	/process\.stdout/,
	/\.write\(/,
	/setStatus\(/,
	/ui\.notify/,
	/ctx\.ui\./,
	/powerline/i,
	/adjutant/i,
];

const TUI_EXTENSION_FILES = [
	"adjutant-editor.ts",
	"adjutant-greeting.ts",
	"session-name-status.ts",
];

function isTuiFile(filePath: string): boolean {
	const base = path.basename(filePath);
	return TUI_EXTENSION_FILES.includes(base);
}

function hasAnsiPatterns(content: string): boolean {
	return ANSI_PATTERNS.some((p) => p.test(content));
}

export default function (pi: ExtensionAPI) {
	pi.on("before_tool_use", async (event, ctx) => {
		if (!ctx.hasUI) return;
		if (event.tool !== "edit_file" && event.tool !== "write_file") return;

		const filePath: string = event.params?.file_path ?? event.params?.path ?? "";
		if (!isTuiFile(filePath)) return;

		const newContent: string =
			event.params?.new_string ?? event.params?.content ?? "";
		if (!hasAnsiPatterns(newContent)) return;

		const ok = await ctx.ui.confirm(
			"TUI DRY-RUN GUARD",
			`Editing TUI file: ${path.basename(filePath)}\n\nThis change contains ANSI/rendering patterns.\n\nHave you validated the output with validate_ansi_output before applying?`
		);

		if (!ok) {
			event.preventDefault?.();
			ctx.ui.notify(
				"Edit blocked. Run validate_ansi_output first, then retry.",
				"warning"
			);
		}
	});

	pi.registerTool({
		name: "validate_ansi_output",
		label: "Validate ANSI Output",
		description:
			"Run a TypeScript/JavaScript snippet in isolation and capture its terminal output. Use this to verify TUI rendering before editing active extension files.",
		parameters: Type.Object({
			code: Type.String({
				description:
					"TypeScript/JavaScript code to execute. Must write output to stdout. Import node builtins freely.",
			}),
		}),
		execute: async (_id, params, _signal, _update, ctx) => {
			const { code } = params as { code: string };

			const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-tui-dryrun-"));
			const scriptPath = path.join(tmpDir, "dryrun.mjs");

			try {
				fs.writeFileSync(scriptPath, code, "utf-8");

				const output = execSync(`node "${scriptPath}"`, {
					encoding: "utf-8",
					timeout: 10_000,
					stdio: ["ignore", "pipe", "pipe"],
				});

				return {
					content: [
						{
							type: "text",
							text: `=== ANSI dry-run output ===\n${output}\n=== end ===`,
						},
					],
				};
			} catch (e: any) {
				return {
					content: [
						{
							type: "text",
							text: `Dry-run failed:\n${e.stderr ?? e.message}`,
						},
					],
				};
			} finally {
				fs.rmSync(tmpDir, { recursive: true, force: true });
			}
		},
	});
}
