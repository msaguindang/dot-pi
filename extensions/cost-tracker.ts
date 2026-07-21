/**
 * cost-tracker.ts — LLM cost tracking extension
 *
 * Hooks into agent_start / message_end / agent_end / session_shutdown to
 * accumulate per-turn token usage and flush one JSONL record per agent run
 * to ~/.pi/agent/cost-history.jsonl.
 *
 * Works in every pi process automatically (orchestrator + all subagents).
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { visibleWidth, truncateToWidth } from "@earendil-works/pi-tui";

const COST_HISTORY = join(homedir(), ".pi", "agent", "cost-history.jsonl");

// Fallback pricing table (per-token) — used only when harness cost is zero.
// Keys match model id substrings (case-insensitive).
// NOTE: every agent model pin in this harness was renamed sonnet-4-6 -> sonnet-4-5
// yesterday (display/pin rename, not a real model swap — pricing assumed unchanged).
// The key here was missed, so sonnet-4-5 usage silently fell back to $0 whenever
// harness-reported cost was zero. Renamed to match.
const FALLBACK_RATES: Record<string, { input: number; output: number; cacheRead: number; cacheWrite: number }> = {
	"claude-sonnet-4-5":      { input: 3e-6,    output: 15e-6,  cacheRead: 3e-7,   cacheWrite: 3.75e-6 },
	"claude-haiku-4-5":       { input: 1e-6,    output: 5e-6,   cacheRead: 1e-7,   cacheWrite: 1.25e-6 },
	"gemini-3.1-pro-preview": { input: 2e-6,    output: 12e-6,  cacheRead: 2e-7,   cacheWrite: 0       },
	"minimax-m2":             { input: 3e-7,    output: 1.2e-6, cacheRead: 3e-8,   cacheWrite: 0       },
	"minimax-m3":             { input: 6e-7,    output: 2.4e-6, cacheRead: 1.2e-7, cacheWrite: 0       },
};

// ── Session cost ceiling ────────────────────────────────────────────────
// Read once at process start (this covers the lifetime of one pi session —
// orchestrator or subagent — same scope as `acc` below). Not hot-reloaded
// mid-session; that's fine, these are monitoring thresholds, not billing.
interface CostCeilingConfig {
	warnThresholdUsd: number;
	hardCeilingUsd: number;
	hardCeilingRepeatUsd: number;
}

function readCostCeilingConfig(): CostCeilingConfig {
	const defaults: CostCeilingConfig = { warnThresholdUsd: 5, hardCeilingUsd: 25, hardCeilingRepeatUsd: 5 };
	try {
		const settingsPath = join(homedir(), ".pi", "agent", "settings.json");
		if (!existsSync(settingsPath)) return defaults;
		const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
		return {
			warnThresholdUsd: typeof settings.warnThresholdUsd === "number" ? settings.warnThresholdUsd : defaults.warnThresholdUsd,
			hardCeilingUsd: typeof settings.hardCeilingUsd === "number" ? settings.hardCeilingUsd : defaults.hardCeilingUsd,
			hardCeilingRepeatUsd: typeof settings.hardCeilingRepeatUsd === "number" ? settings.hardCeilingRepeatUsd : defaults.hardCeilingRepeatUsd,
		};
	} catch {
		return defaults;
	}
}

const costCeilingConfig = readCostCeilingConfig();

// Running total for THIS process's session (module-scope, persists for the
// life of the process — same lifetime `acc` would span across many
// agent_start/agent_end cycles). Deliberately does NOT merge in subagent
// costs from cost-history.jsonl (unlike the footer's sessionCost) — the
// incident this guards against was the orchestrator's OWN turn cost
// ballooning from context growth, not subagent spend. Add a jsonl merge
// here if the ceiling needs to reflect whole-tree spend instead.
let sessionCumulativeCost = 0;
let warnedSoftCeiling = false;
let hardCeilingWarnCount = 0; // how many repeat-warnings already fired past hardCeilingUsd

// Intentionally a WARNING, not a kill-switch: this harness has no documented
// "pause and ask the user" extension primitive, so the safest thing an
// extension can do on overrun is make it impossible to miss, not silently
// abort (or worse, half-abort) a running agent process.
function checkCostCeilings(ctx: ExtensionContext, totalCost: number): void {
	if (!warnedSoftCeiling && totalCost >= costCeilingConfig.warnThresholdUsd) {
		warnedSoftCeiling = true;
		ctx.ui.notify(
			`[cost-tracker] Session cost has crossed $${costCeilingConfig.warnThresholdUsd.toFixed(2)} (currently $${totalCost.toFixed(2)}).`,
			"warning",
		);
	}
	if (totalCost >= costCeilingConfig.hardCeilingUsd) {
		const overBy = totalCost - costCeilingConfig.hardCeilingUsd;
		const dueWarnCount = Math.floor(overBy / costCeilingConfig.hardCeilingRepeatUsd) + 1;
		if (dueWarnCount > hardCeilingWarnCount) {
			hardCeilingWarnCount = dueWarnCount;
			ctx.ui.notify(
				`[cost-tracker] COST CEILING EXCEEDED: session has spent $${totalCost.toFixed(2)}, over the $${costCeilingConfig.hardCeilingUsd.toFixed(2)} hard ceiling. ` +
					`This is a warning only — nothing is stopping the session automatically.`,
				"error",
			);
		}
	}
}

// Derive the parent (root) session id from a subagent's session file path.
// Subagent session files live under a directory segment of the form
// `<TIMESTAMP>Z_<PARENT_UUID>`; scan for the FIRST such segment to stay
// robust against nested-subagent depth.
function deriveParentSessionId(sessionFile: string | null | undefined): string | undefined {
	if (!sessionFile) return undefined;
	const parts = sessionFile.split(/[/\\]/);
	const seg = parts.find(p => /Z_[0-9a-f-]{36}$/.test(p));
	if (!seg) return undefined;
	return seg.replace(/^.*Z_/, "");
}

function fallbackCost(
	modelId: string,
	usage: { input: number; output: number; cacheRead: number; cacheWrite: number },
): number {
	const key = Object.keys(FALLBACK_RATES).find(k => modelId.toLowerCase().includes(k));
	if (!key) return 0;
	const r = FALLBACK_RATES[key]!;
	return usage.input * r.input
		+ usage.output * r.output
		+ usage.cacheRead * r.cacheRead
		+ usage.cacheWrite * r.cacheWrite;
}

interface Acc {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	turns: number;
	startedAt: number;
}

// Agent identity — injected by pi-subagents spawner via environment variables.
const agentName  = process.env.PI_SUBAGENT_CHILD_AGENT ?? "orchestrator";
const runId      = process.env.PI_SUBAGENT_RUN_ID      ?? undefined;
const isSubagent = process.env.PI_SUBAGENT_CHILD       === "1";

export default function (pi: ExtensionAPI): void {
	let acc: Acc | null = null;

	pi.on("session_start", (event, ctx) => {
		// Reset the cost-ceiling counters on every session_start EXCEPT "reload".
		// sessionCumulativeCost is module-scope and otherwise survives for the
		// life of the OS process — /new, /resume, and /fork rebind extensions
		// onto the SAME running process rather than restarting it (per
		// docs/extensions.md), so without this reset a fresh session inherits
		// the prior session's accumulated cost and can report the ceiling as
		// already exceeded before it has spent anything itself.
		//
		// "reload" (ctx.reload() / /reload) is excluded: it re-binds extension
		// code onto the SAME still-running session, it does not switch to a
		// different session file. The session's real spend hasn't changed, so
		// zeroing here would hide genuine ceiling-exceeded state right after a
		// routine extension reload.
		//
		// "resume" IS reset to 0, same as "new"/"fork": this accumulator only
		// ever sums usage observed in-process via message_end (see comment on
		// its declaration below — it deliberately never merges in cost from
		// session history or subagent logs, unlike the footer's sessionCost).
		// So on resume it can never accurately reflect the resumed session's
		// true historical spend either way; leaving it un-reset would just
		// carry over a different, unrelated session's cost, which is more
		// misleading than starting the count over at 0.
		if (event.reason !== "reload") {
			sessionCumulativeCost = 0;
			warnedSoftCeiling = false;
			hardCeilingWarnCount = 0;
		}

		// Only display footer in the main orchestrator, avoid flickering/overwriting in subagents
		if (isSubagent) return;

		ctx.ui.setFooter((tui, theme, footerData) => {
			const unsub = footerData.onBranchChange(() => tui.requestRender());

			return {
				dispose: unsub,
				invalidate() {},
				render(width: number): string[] {
					let sessionCost = 0;
					let turnCosts: number[] = [0];
					let currentTurnIndex = 0;

					// Derive costs strictly from the branch to support reloads and avoid double-counting
					for (const e of ctx.sessionManager.getBranch()) {
						if (e.type === "message") {
							// @ts-expect-error loosely typing for usage access
							const msg = e.message;
							if (msg.role === "user") {
								currentTurnIndex++;
								turnCosts[currentTurnIndex] = 0;
							} else if (msg.role === "assistant") {
								const cost = msg.usage?.cost?.total ?? 0;
								sessionCost += cost;
								turnCosts[currentTurnIndex] += cost;
							}
						}
					}

					// Include sub-agent costs in the total session cost
					try {
						if (existsSync(COST_HISTORY)) {
							const content = readFileSync(COST_HISTORY, "utf-8");
							const records = content.split("\n").filter(Boolean).map(line => JSON.parse(line));
							const subagentCost = records
								.filter(r => r.isSubagent && r.parentSessionId === ctx.sessionManager.getSessionId())
								.reduce((sum, r) => sum + (r.usage?.cost || 0), 0);
							sessionCost += subagentCost;
						}
					} catch (e) {}


					// If `acc` is active, we are currently generating, so the "Previous" prompt is the turn before this one.
					// If idle, it's the current turn.
					const prevCost = acc !== null ? (turnCosts[currentTurnIndex - 1] ?? 0) : (turnCosts[currentTurnIndex] ?? 0);

					// Get custom extension statuses
					const statuses = Array.from(footerData.getExtensionStatuses().values()).join(" ");
					
					const prevStr = prevCost > 0 ? `Prev: $${prevCost.toFixed(4)} | ` : "";
					const left = theme.fg("dim", `${prevStr}Session: $${sessionCost.toFixed(4)}`);
					const right = statuses ? ` ${statuses} ` : "";
					
					const pad = " ".repeat(Math.max(1, width - visibleWidth(left) - visibleWidth(right)));
					
					return [truncateToWidth(left + pad + right, width)];
				},
			};
		});
	});

	pi.on("agent_start", (_event, _ctx) => {
		acc = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, turns: 0, startedAt: Date.now() };
	});

	pi.on("message_end", (event, ctx) => {
		if (!acc) return;
		// Cast to access usage safely across all message types.
		const msg = event.message as Record<string, unknown>;
		const u = msg.usage as {
			input?: number; output?: number;
			cacheRead?: number; cacheWrite?: number;
			cost?: { total?: number };
		} | undefined;
		if (!u) return;
		acc.input      += u.input      ?? 0;
		acc.output     += u.output     ?? 0;
		acc.cacheRead  += u.cacheRead  ?? 0;
		acc.cacheWrite += u.cacheWrite ?? 0;
		acc.cost       += u.cost?.total ?? 0;
		acc.turns++;

		// Same fallback-when-zero logic as flush() below, applied per-message so
		// the ceiling check sees real cost even for providers that report $0.
		const msgCost = u.cost?.total ?? 0;
		const effectiveCost = msgCost > 0
			? msgCost
			: fallbackCost(ctx.model?.id ?? "", {
				input: u.input ?? 0,
				output: u.output ?? 0,
				cacheRead: u.cacheRead ?? 0,
				cacheWrite: u.cacheWrite ?? 0,
			});
		sessionCumulativeCost += effectiveCost;
		checkCostCeilings(ctx, sessionCumulativeCost);
	});

	const flush = (ctx: ExtensionContext, incomplete = false): void => {
		if (!acc || acc.turns === 0) { acc = null; return; }

		const modelId   = ctx.model?.id       ?? "unknown";
		const provider  = ctx.model?.provider ?? "unknown";
		const modelFull = ctx.model ? `${provider}/${modelId}` : "unknown";

		// Prefer harness-computed cost; fall back to pricing table when zero.
		const finalCost = acc.cost > 0 ? acc.cost : fallbackCost(modelId, acc);

		const record: Record<string, unknown> = {
			ts:        Math.floor(Date.now() / 1000),
			agent:     agentName,
			isSubagent,
			...(runId ? { runId } : {}),
			sessionId: ctx.sessionManager.getSessionId() ?? "unknown",
			...(isSubagent ? { parentSessionId: deriveParentSessionId(ctx.sessionManager.getSessionFile?.()) } : {}),
			model:     modelFull,
			provider,
			cwd:       ctx.cwd,
			durationMs: Date.now() - acc.startedAt,
			turns:     acc.turns,
			...(incomplete ? { incomplete: true } : {}),
			usage: {
				input:      acc.input,
				output:     acc.output,
				cacheRead:  acc.cacheRead,
				cacheWrite: acc.cacheWrite,
				cost:       Number(finalCost.toFixed(6)),
			},
		};

		try {
			mkdirSync(join(homedir(), ".pi", "agent"), { recursive: true });
			appendFileSync(COST_HISTORY, JSON.stringify(record) + "\n", "utf8");
		} catch {
			// Best-effort — never crash the session for cost logging.
		}
		acc = null;
	};

	pi.on("agent_end", (event, ctx) => {
		if (!acc) return;
		// Recompute token totals from the finalized message list.
		// message_end fires before cacheWrite/cacheRead tokens are populated on
		// the message object, so acc.cacheWrite/cacheRead are 0 from accumulation.
		// agent_end fires after all messages are finalized — correct values here.
		let input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cost = 0;
		for (const msg of event.messages) {
			const m = msg as Record<string, unknown>;
			const u = m.usage as {
				input?: number; output?: number;
				cacheRead?: number; cacheWrite?: number;
				cost?: { total?: number };
			} | undefined;
			if (!u) continue;
			input      += u.input      ?? 0;
			output     += u.output     ?? 0;
			cacheRead  += u.cacheRead  ?? 0;
			cacheWrite += u.cacheWrite ?? 0;
			cost       += u.cost?.total ?? 0;
		}
		acc.input      = input;
		acc.output     = output;
		acc.cacheRead  = cacheRead;
		acc.cacheWrite = cacheWrite;
		acc.cost       = cost;
		
		flush(ctx, false);
	});
	pi.on("session_shutdown", (_event, ctx) => { flush(ctx, true);  });
}
