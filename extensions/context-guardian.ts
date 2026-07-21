/**
 * context-guardian.ts — Proactive context compaction
 *
 * Incident: player-gitops-2 (2026-07-17) — a 27h orchestrator session let
 * context grow unbounded (never proactively compacted). The harness's own
 * auto-compaction only fires REACTIVELY, once:
 *
 *     contextTokens > contextWindow - DEFAULT_COMPACTION_SETTINGS.reserveTokens
 *
 * (reserveTokens defaults to 16384 — see the installed package's
 * dist/core/compaction/compaction.js and docs/compaction.md). In that
 * session it fired twice in 27 hours, both after most of the cost damage —
 * per-turn cost had already climbed from $0.10 to a single $3.15 turn
 * because context had grown past the point where the Anthropic prompt-cache
 * TTL survives an idle subagent `wait`, forcing full uncached resends.
 *
 * This extension checks context usage on every message_end (same event
 * cost-tracker.ts hooks) and proactively asks the harness to compact well
 * before that reactive threshold — at `contextGuardian.proactiveCompactionRatio`
 * (default 0.6) of the harness's own reactive ratio.
 *
 * ctx.compact() vs the raw compact() pure function:
 * Confirmed via the harness's own bundled example
 * (examples/extensions/trigger-compact.ts, shipped inside the installed
 * @earendil-works/pi-coding-agent package) that `ctx.compact()` on
 * ExtensionContext IS the supported, fire-and-forget way to trigger
 * compaction from an extension hook — it's the same action the interactive
 * `/compact` command uses internally (docs/extensions.md, "ctx.compact()").
 * The raw `compact()` function re-exported from `core/compaction` needs a
 * hand-built CompactionPreparation plus a Model and apiKey, and is meant to
 * be orchestrated by AgentSession itself (see dist/core/agent-session.d.ts),
 * not called cold from an extension — so this file deliberately does NOT
 * call that raw function. We only import DEFAULT_COMPACTION_SETTINGS, to
 * compute our proactive threshold relative to the harness's own reactive
 * one. Because ctx.compact() turned out to be supported (not
 * unsupported/unsafe), this is the direct-call path, not the warning
 * fallback — the onError callback below still covers the case where a given
 * compact() attempt fails (e.g. mid-turn state), degrading to a warning.
 *
 * customInstructions: proactive compaction fires mid-task, not just at a
 * natural stopping point, so the default summarizer prompt has no reason to
 * preserve which task/plan was actively running — this showed up as an
 * observed incident where compaction fired mid-way through a context-mode
 * ctx_batch_execute-driven multi-step plan and the agent lost the thread
 * afterward, stalling instead of continuing. We pass customInstructions
 * (appended, not replaceInstructions — see docs/extensions.md, ctx.compact()
 * and the same option on ctx.navigateTree()) to steer the summary toward
 * keeping the in-progress task and its next step explicit.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DEFAULT_COMPACTION_SETTINGS } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

interface GuardianConfig {
	proactiveCompactionRatio: number;
}

// Read once at process start — same pattern context-resolver.ts uses for
// settings.json (parse, guard with existsSync/try-catch, fall back to
// defaults on anything malformed).
function readConfig(): GuardianConfig {
	const defaults: GuardianConfig = { proactiveCompactionRatio: 0.6 };
	try {
		const settingsPath = join(homedir(), ".pi", "agent", "settings.json");
		if (!existsSync(settingsPath)) return defaults;
		const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
		const ratio = settings?.contextGuardian?.proactiveCompactionRatio;
		return {
			proactiveCompactionRatio: typeof ratio === "number" ? ratio : defaults.proactiveCompactionRatio,
		};
	} catch {
		return defaults;
	}
}

const config = readConfig();

export default function (pi: ExtensionAPI): void {
	// Edge-detect the threshold crossing (same idiom as the harness's own
	// trigger-compact.ts example): ask once per upward crossing, not on every
	// message_end while already above it. After a successful compaction,
	// usage drops well below threshold, so this naturally re-arms itself for
	// the next time context climbs back up.
	let previousRatio: number | null = null;

	const triggerCompaction = (ctx: ExtensionContext) => {
		if (ctx.hasUI) {
			ctx.ui.notify(
				"[context-guardian] Context usage crossed the proactive threshold — triggering compaction now, ahead of the harness's reactive threshold.",
				"info",
			);
		}
		try {
			ctx.compact({
				customInstructions:
					"This compaction was triggered mid-task, ahead of a natural stopping point. Explicitly preserve what task or plan was actively in progress, including any in-flight or just-completed tool operations tied to it (e.g. batch command results, files being modified, a step-by-step plan being executed). State the concrete next step clearly enough that the agent can resume and continue the task immediately after reading the summary, without re-deriving context from scratch.",
				onComplete: () => {
					if (ctx.hasUI) ctx.ui.notify("[context-guardian] Proactive compaction completed.", "info");
				},
				onError: (error) => {
					// ctx.compact() itself is supported (see comment above), but a
					// given attempt can still fail (e.g. compaction already running,
					// mid-turn state). Degrade to a loud, actionable warning rather
					// than silently doing nothing.
					if (ctx.hasUI) {
						ctx.ui.notify(
							`[context-guardian] Proactive compaction failed (${error.message}). Run /compact manually before costs climb further.`,
							"warning",
						);
					}
				},
			});
		} catch (err) {
			// Belt-and-suspenders: ctx.compact() is typed as a synchronous void
			// fire-and-forget call, so it shouldn't throw, but if it does, don't
			// take the session down over a proactive optimization.
			const msg = err instanceof Error ? err.message : String(err);
			if (ctx.hasUI) {
				ctx.ui.notify(`[context-guardian] Could not trigger compaction (${msg}). Run /compact manually.`, "warning");
			}
		}
	};

	pi.on("message_end", (_event, ctx) => {
		// ctx.getContextUsage() already gives us the harness's own computed
		// token count (last assistant usage + estimate for trailing messages) —
		// reusing it here avoids re-deriving it from raw session entries.
		const usage = ctx.getContextUsage();
		if (!usage || usage.tokens == null || !usage.contextWindow) return;

		// Reactive ratio = the point the harness's own auto-compaction fires at.
		const reactiveRatio = (usage.contextWindow - DEFAULT_COMPACTION_SETTINGS.reserveTokens) / usage.contextWindow;
		const proactiveRatio = reactiveRatio * config.proactiveCompactionRatio;
		const currentRatio = usage.tokens / usage.contextWindow;

		const crossedThreshold =
			previousRatio !== null && previousRatio <= proactiveRatio && currentRatio > proactiveRatio;
		previousRatio = currentRatio;
		if (!crossedThreshold) return;

		triggerCompaction(ctx);
	});
}
