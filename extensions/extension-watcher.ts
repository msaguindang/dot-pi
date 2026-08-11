/**
 * Extension Watcher
 *
 * Records extension file mtimes at session_start.
 * Warns immediately after any Edit/Write to an extension file.
 * Provides check_extension_freshness tool for explicit staleness audit.
 *
 * Prevents "Chain cancelled" errors caused by stale cached extensions
 * during long orchestrator sessions.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

interface ExtensionState {
	file: string;
	mtimeAtStart: number;
}

const extensionStates: ExtensionState[] = [];
const staleExtensions = new Set<string>();
let sessionStartMs = 0;

function getExtensionsDir(): string {
	return path.join(os.homedir(), ".pi", "agent", "extensions");
}

function snapshotExtensions(): void {
	extensionStates.length = 0;
	staleExtensions.clear();
	sessionStartMs = Date.now();

	const dir = getExtensionsDir();
	try {
		for (const entry of fs.readdirSync(dir)) {
			if (!entry.endsWith(".ts")) continue;
			const full = path.join(dir, entry);
			try {
				const stat = fs.statSync(full);
				extensionStates.push({ file: entry, mtimeAtStart: stat.mtimeMs });
			} catch {
				// skip unreadable
			}
		}
	} catch {
		// extensions dir not accessible
	}
}

function checkStaleness(): { stale: string[]; fresh: string[] } {
	const stale: string[] = [];
	const fresh: string[] = [];
	const dir = getExtensionsDir();

	for (const state of extensionStates) {
		const full = path.join(dir, state.file);
		try {
			const current = fs.statSync(full).mtimeMs;
			if (current > state.mtimeAtStart) {
				stale.push(state.file);
				staleExtensions.add(state.file);
			} else {
				fresh.push(state.file);
			}
		} catch {
			// file removed — treat as stale
			stale.push(`${state.file} (removed)`);
		}
	}

	return { stale, fresh };
}

export default function (pi: ExtensionAPI) {
	pi.on("session_start", async () => {
		snapshotExtensions();
	});

	pi.on("after_tool_use", async (event, ctx) => {
		if (!ctx.hasUI) return;
		if (event.tool !== "edit_file" && event.tool !== "write_file") return;

		const filePath: string = event.params?.file_path ?? event.params?.path ?? "";
		const base = path.basename(filePath);
		if (!filePath.includes(path.join(".pi", "agent", "extensions"))) return;

		staleExtensions.add(base);
		ctx.ui.notify(
			`Extension modified: ${base} — restart pi session to reload changes`,
			"warning"
		);
	});

	pi.on("session_shutdown", () => {
		extensionStates.length = 0;
		staleExtensions.clear();
	});

	pi.registerTool({
		name: "check_extension_freshness",
		label: "Check Extension Freshness",
		description:
			"Compare current extension file mtimes against session-start snapshot. Identifies stale extensions that require a session restart to reload.",
		parameters: Type.Object({}),
		execute: async (_id, _params, _signal, _update, _ctx) => {
			if (extensionStates.length === 0) {
				return {
					content: [
						{
							type: "text",
							text: "No snapshot available. Session may have started before this extension was loaded.",
						},
					],
				};
			}

			const { stale, fresh } = checkStaleness();
			const sessionAge = Math.round((Date.now() - sessionStartMs) / 1000 / 60);

			const lines: string[] = [
				`Session age: ${sessionAge}min`,
				`Extensions snapshotted: ${extensionStates.length}`,
				"",
			];

			if (stale.length > 0) {
				lines.push("⚠ STALE (modified after session start — restart required):");
				stale.forEach((f) => lines.push(`  • ${f}`));
			} else {
				lines.push("✓ All extensions fresh.");
			}

			if (fresh.length > 0) {
				lines.push("");
				lines.push(`✓ Fresh (${fresh.length}): ${fresh.join(", ")}`);
			}

			return { content: [{ type: "text", text: lines.join("\n") }] };
		},
	});
}
