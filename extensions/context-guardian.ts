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
 *
 * In-flight tool call race (2026-07-20 incident): message_end fires for
 * intermediate messages mid-turn, not just at natural turn boundaries
 * (docs/extensions.md: "message_start and message_end fire for user,
 * assistant, and toolResult messages"). That means our proactive
 * triggerCompaction() can run while a tool call from the SAME turn is still
 * executing and hasn't produced a tool_result yet. In a real session this
 * fired ~2 minutes after the orchestrator issued an async subagent dispatch
 * (a long-running worker tool call) — before that call's result was ever
 * recorded. On-disk inspection confirmed zero trace of the dispatch ever
 * existed (no run directory, no artifacts, no background process spawned):
 * the call was orphaned mid-flight by compaction, not merely lost after
 * completing. The generated summary was also stale by several turns and
 * never mentioned the in-flight dispatch, so on resume the orchestrator had
 * no way to detect anything had gone wrong and silently re-dispatched an
 * identical duplicate job. The harness's own compaction docs
 * (docs/compaction.md: "Never cut at tool results (they must stay with
 * their tool call)") only protect an existing call/result pair from being
 * split across the summary boundary — they do nothing for a call that
 * hasn't produced a result yet at the moment compaction runs.
 *
 * Fix, take 1 (broken — kept here as the incident record, corrected below):
 * track pending tool calls (added on tool_call, removed on
 * tool_execution_end — see the pendingToolCallIds comment below for why
 * tool_execution_end and not tool_result), and veto the compaction attempt
 * via session_before_compact while calls are still pending.
 *
 * That veto fires too late for our own ctx.compact() calls. Traced directly
 * in the installed package's dist/core/agent-session.js, AgentSession.compact()
 * (~line 1373) does, in this order: _disconnectFromAgent() (unsubscribes the
 * extension-event forwarder) → await this.abort() (aborts the in-flight tool
 * call/turn) → only THEN emits session_before_compact. By the time our veto
 * runs, the in-flight call has already been torn down — the guard prevents
 * nothing. Worse, because the event forwarder is disconnected before abort()
 * unwinds, the aborted call's tool_execution_end never reaches this
 * extension, so its entry in pendingToolCallIds is never removed. Once
 * leaked, pendingToolCallIds.size is never 0 again for the rest of the
 * process, silently vetoing every future compaction attempt — including the
 * user's own manual /compact (confirmed it routes through this same
 * compact() method, reason: "manual").
 *
 * (Separately confirmed fine, not part of the bug: the harness's own
 * reactive/threshold auto-compaction runs via a different method,
 * _runAutoCompaction from _handlePostAgentRun, strictly after agent_end —
 * i.e. after that turn's tool calls have already resolved. pendingToolCallIds
 * is genuinely empty by the time session_before_compact fires on that path,
 * so it isn't affected by the ordering bug above.)
 *
 * Fix, corrected: the only reliable guard for our OWN compaction is upstream
 * of ctx.compact() entirely — checked inside triggerCompaction() before it
 * ever calls ctx.compact(), so _disconnectFromAgent()/abort() never run from
 * our trigger while calls are pending. The session_before_compact handler
 * stays as a cheap, harmless secondary check — it still protects the paths
 * we don't control (manual /compact, any other extension's compact() call),
 * it's just not sufficient on its own for ours. See the previousRatio reset,
 * now duplicated at both the triggerCompaction skip site (primary) and the
 * session_before_compact veto (secondary), for how a deferred attempt gets
 * retried from whichever site actually deferred it. A pendingToolCallIds
 * leak is also now a non-issue either way: the compaction onComplete/onError
 * callbacks unconditionally .clear() it — see those callbacks for why that's
 * safe.
 *
 * Auto-continue after a non-retried compaction (2026-07-21, direct user
 * report): after compaction fires mid-task, the agent's turn just ends and
 * the session sits idle — the user has to type "continue" by hand every
 * time, even though customInstructions above already steers the summary to
 * spell out the in-progress task and its next step specifically so the agent
 * COULD resume on its own. Confirmed via docs/extensions.md's
 * session_compact section (the installed, active copy at
 * .nvm/versions/node/v24.18.0/.../pi-coding-agent/docs/extensions.md — other
 * nvm versions and backup dirs on this machine have stale copies of this same
 * file, so this path was checked explicitly): the event's `willRetry` field
 * is "whether the aborted turn is retried after compaction (overflow
 * recovery)" — only reason: "overflow" with willRetry: true is auto-retried
 * by the harness itself. reason: "manual" (both our own triggerCompaction()
 * above and the user's own /compact) and reason: "threshold" (the harness's
 * own proactive check) leave the turn ended with nothing driving a
 * continuation — and so does the non-retried reason: "overflow" case
 * (willRetry: false, when the assistant answer already completed). So the
 * session_compact hook below fires whenever `!event.willRetry`, regardless of
 * reason, synthesizing the "continue" the user would otherwise type by hand.
 *
 * deliverAs, not triggerTurn: confirmed via the installed package's
 * dist/core/extensions/types.d.ts (ExtensionAPI.sendUserMessage, ~line 903)
 * and dist/core/agent-session.d.ts (AgentSession.sendUserMessage, ~line 396)
 * that sendUserMessage's only option is `deliverAs?: "steer" | "followUp"` —
 * there is no `triggerTurn` option on this call (that's a
 * sendMessage/sendCustomMessage-only option, confirmed in the same two
 * files) and none is needed: sendUserMessage's own doc comment says it
 * "Always triggers a turn", unconditionally.
 *
 * Why "followUp" unconditionally, not gated on ctx.isIdle(): traced
 * dist/core/agent-session.js because prompt()'s `if (this.isStreaming)`
 * branch (~line 834) throws "Agent is already processing..." when
 * streamingBehavior isn't given, and the session is NOT reliably idle when
 * session_compact fires:
 *   - reason: "threshold" (and the non-retried "overflow" case) run through
 *     _runAutoCompaction() (~line 1593), called from _checkCompaction() from
 *     _handlePostAgentRun() (~line 764) — still inside _runAgentPrompt's
 *     `while (await this._handlePostAgentRun())` loop (~line 754).
 *     _isAgentRunActive only flips false in _emitAgentSettled() (~line 310),
 *     called from _runAgentPrompt's `finally`, AFTER that loop exits — so
 *     isStreaming is still true when session_compact fires here, and a bare
 *     sendUserMessage() with no deliverAs would throw. Good news:
 *     _runAutoCompaction's own post-compaction step (~line 1712) does
 *     `return this.agent.hasQueuedMessages()`, which feeds straight back
 *     into the while loop above — a followUp queued from our handler is
 *     picked up and continued immediately, in the same call stack, without
 *     the session ever going idle.
 *   - reason: "manual" runs through compact() (~line 1373), which calls
 *     `await this.abort()` (~line 1375) BEFORE our session_compact emit
 *     (~line 1443), and abort() (~line 1171) awaits waitForIdle(), which
 *     blocks until _emitAgentSettled() has already flipped _isAgentRunActive
 *     false. So isStreaming is guaranteed false by the time session_compact
 *     fires on this path — deliverAs is simply ignored (prompt()'s
 *     `if (this.isStreaming)` gate never enters) and sendUserMessage's plain
 *     not-streaming path sends immediately and triggers a new turn.
 * "followUp" is correct and safe on both paths, so it's used unconditionally.
 *
 * Event ordering vs. reconnection — checked, and the premise doesn't apply
 * here: _disconnectFromAgent()/_reconnectToAgent() (see the in-flight tool
 * call fix above) only subscribe/unsubscribe this.agent's OWN event stream
 * (this.agent.subscribe, ~line 553-557), which forwards tool_call/
 * tool_execution_end/etc. session_compact is emitted via a direct
 * this._extensionRunner.emit() call from inside compact()/
 * _runAutoCompaction() itself (~line 1443, ~line 1686) — a different object,
 * unaffected by that subscribe/unsubscribe state entirely. There is no
 * "disconnected extension events" window to wait out here (unlike the
 * tool_execution_end forwarding the prior fix, above, had to account for);
 * the only thing that actually gates sendUserMessage's behavior is
 * isStreaming, traced above.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DEFAULT_COMPACTION_SETTINGS } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// TEMPORARY DIAGNOSTIC LOGGING — remove once the race is confirmed/fixed. Added 2026-07-22.
// Investigating: a second, real "manual"-reason compaction veto observed twice
// shortly after the upstream guard in triggerCompaction() already deferred a
// first attempt. Logs are appended via pi.appendEntry() (confirmed real API:
// ExtensionAPI.appendEntry<T = unknown>(customType: string, data?: T): void —
// docs/extensions.md "### pi.appendEntry(customType, data?)", and
// dist/core/extensions/types.d.ts line 911, `appendEntry` is on ExtensionAPI
// only, NOT on ExtensionContext — there is no ctx.appendEntry) so entries land
// in the session's .jsonl file (unlike ctx.ui.notify, which is TUI-ephemeral
// and never written to the transcript). Purely additive — no guard/logic
// behavior below is changed by this diagnostic code.
// Retrieve later with:
//   grep '"source":"context-guardian-diag"' ~/.pi/agent/sessions/--data-dev-work-ntv-player-server--/*.jsonl

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
	// TEMPORARY DIAGNOSTIC LOGGING — remove once the race is confirmed/fixed. Added 2026-07-22.
	// appendEntry lives on `pi` (ExtensionAPI), not `ctx` (ExtensionContext) — see
	// the file-header note above for the confirmed signature/citation. Swallow
	// any error so a diagnostic-logging failure can never affect real behavior.
	const diag = (event: Record<string, unknown>) => {
		try {
			pi.appendEntry("context-guardian-diag", {
				source: "context-guardian-diag",
				timestamp: new Date().toISOString(),
				...event,
			});
		} catch {}
	};

	// Edge-detect the threshold crossing (same idiom as the harness's own
	// trigger-compact.ts example): ask once per upward crossing, not on every
	// message_end while already above it. After a successful compaction,
	// usage drops well below threshold, so this naturally re-arms itself for
	// the next time context climbs back up.
	let previousRatio: number | null = null;

	// Pending tool call tracker for the session_before_compact guard below.
	//
	// Added on tool_call, removed on tool_execution_end — NOT tool_result.
	// tool_result covers both the normal-completion and thrown-tool-error
	// paths (docs/extensions.md "Signaling errors": a thrown execute() error
	// is caught and reported via tool_result with isError: true — same
	// event, no separate error event), so it looked like the right removal
	// site at first. But tracing the actual dispatch path in the installed
	// package (node_modules/@earendil-works/pi-agent-core/dist/agent-loop.js)
	// showed tool_result is skipped entirely when a call is blocked by a
	// tool_call handler, fails argument validation, targets an unknown tool,
	// or is aborted before it starts executing — those all resolve through
	// an "immediate" path that never calls afterToolCall (the tool_result
	// hook). tool_execution_end fires unconditionally on every path (see
	// executeToolCallsSequential/Parallel in agent-loop.js), so it's the only
	// hook guaranteed to pair 1:1 with tool_call and never leak an entry.
	const pendingToolCallIds = new Set<string>();

	// TEMPORARY DIAGNOSTIC LOGGING — see file header. currentRatio/proactiveRatio
	// aren't otherwise in scope inside triggerCompaction() (only message_end
	// computes them) — these two vars just carry them across for the diag log
	// below, purely additive, not read by any real guard/logic.
	let currentRatioForDiag: number | undefined;
	let proactiveRatioForDiag: number | undefined;

	const triggerCompaction = (ctx: ExtensionContext) => {
		// TEMPORARY DIAGNOSTIC LOGGING — see file header. Log before the guard check.
		diag({
			event: "trigger_attempt",
			pendingSize: pendingToolCallIds.size,
			currentRatio: currentRatioForDiag,
			proactiveRatio: proactiveRatioForDiag,
		});

		// Primary guard (see header comment for the trace): check BEFORE calling
		// ctx.compact() at all. session_before_compact fires too late — inside
		// AgentSession.compact(), after _disconnectFromAgent()/abort() already
		// ran — to protect anything for our own trigger. Skipping the call here
		// means those two never execute on our behalf while a call is pending.
		if (pendingToolCallIds.size > 0) {
			// TEMPORARY DIAGNOSTIC LOGGING — see file header.
			diag({ event: "deferred_upstream", pendingSize: pendingToolCallIds.size });

			if (ctx.hasUI) {
				ctx.ui.notify(
					`[context-guardian] Deferring compaction — ${pendingToolCallIds.size} tool call(s) still in flight. Will retry once they finish.`,
					"info",
				);
			}
			// Same reset as the session_before_compact veto below, and for the
			// same reason: this attempt didn't happen, so currentRatio is still
			// above proactiveRatio, but previousRatio was already set to that same
			// value on this message_end tick. Left alone, the edge-detect in
			// message_end (previousRatio <= proactiveRatio && currentRatio >
			// proactiveRatio) would never see an upward crossing again and this
			// deferral would never be retried. Forcing it back to 0 makes the
			// next tick look like a fresh crossing.
			previousRatio = 0;
			return;
		}

		// TEMPORARY DIAGNOSTIC LOGGING — see file header. Control reached past the
		// upstream guard — pendingSize should be 0 here.
		diag({ event: "compact_called", pendingSize: pendingToolCallIds.size });

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
					// Safety-net (see header comment): whatever was pending before
					// compaction resolved is now stale/moot either way — the turn was
					// just rebuilt from a summary, so a call that finished normally
					// already got its tool_result before this fired, and a call that
					// got aborted out from under us will simply re-add itself via a
					// fresh tool_call event if it retries/continues. Clearing here
					// means a single missed tool_execution_end (e.g. from an abort
					// racing the disconnect, per the header trace) can never
					// permanently wedge this extension into vetoing every future
					// compaction.
					pendingToolCallIds.clear();
					if (ctx.hasUI) ctx.ui.notify("[context-guardian] Proactive compaction completed.", "info");
				},
				onError: (error) => {
					// TEMPORARY DIAGNOSTIC LOGGING — see file header. Logged BEFORE the
					// "Compaction cancelled" suppression below, so this fires
					// regardless of whether that suppression later returns early.
					diag({ event: "manual_compact_error", message: error.message });

					// Same safety-net as onComplete — covers both a genuine failure
					// and the "Compaction cancelled" case below.
					pendingToolCallIds.clear();

					// "Compaction cancelled" is the exact message the harness throws
					// when a session_before_compact handler returns { cancel: true }
					// (dist/core/agent-session.js). With the upstream guard above,
					// our own trigger no longer reaches ctx.compact() while calls are
					// pending, so this case is now mostly vacated for us — it'd mean
					// some OTHER handler (or a race where a call became pending
					// between our check and the call) vetoed it. Either way, don't
					// scare the user with "run /compact manually" for an expected,
					// low-key deferral.
					if (error.message === "Compaction cancelled") return;

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

	pi.on("tool_call", (event) => {
		pendingToolCallIds.add(event.toolCallId);
		// TEMPORARY DIAGNOSTIC LOGGING — see file header.
		diag({
			event: "pending_add",
			toolCallId: event.toolCallId,
			toolName: event.toolName,
			pendingSize: pendingToolCallIds.size,
		});
	});

	pi.on("tool_execution_end", (event) => {
		pendingToolCallIds.delete(event.toolCallId);
		// TEMPORARY DIAGNOSTIC LOGGING — see file header.
		diag({
			event: "pending_remove",
			toolCallId: event.toolCallId,
			pendingSize: pendingToolCallIds.size,
		});
	});

	pi.on("session_before_compact", (_event, ctx) => {
		// TEMPORARY DIAGNOSTIC LOGGING — see file header. Logged at entry, before
		// this handler's own early-return/veto decision below.
		diag({
			event: "session_before_compact_check",
			pendingSize: pendingToolCallIds.size,
			willVeto: pendingToolCallIds.size > 0,
		});

		// Secondary/defense-in-depth only. This fires AFTER AgentSession.compact()
		// has already called _disconnectFromAgent()/abort() (see header comment
		// trace), so for our OWN ctx.compact() calls it's too late to prevent
		// anything — that path is now guarded upstream in triggerCompaction()
		// before ctx.compact() is ever called, so in practice this handler
		// shouldn't see pending calls from our own trigger. What it still
		// usefully covers: manual /compact and any other extension's
		// compact() call, which route through the same AgentSession.compact()
		// but don't go through our upstream check.
		if (pendingToolCallIds.size === 0) return;

		// Veto: a tool call (e.g. an async subagent dispatch) hasn't finished
		// yet. Compacting now risks the exact incident this extension exists to
		// prevent — the summary goes stale mid-dispatch, the in-flight call
		// never gets a result recorded, and on resume the agent has no way to
		// tell it silently lost that work and re-dispatches a duplicate.
		if (ctx.hasUI) {
			ctx.ui.notify(
				`[context-guardian] Deferring compaction — ${pendingToolCallIds.size} tool call(s) still in flight. Will retry once they finish.`,
				"info",
			);
		}

		// This compaction attempt did not happen, so context usage is still at
		// (or above) currentRatio from the last message_end tick — but
		// previousRatio was already set to that same value there, and the
		// edge-detect below only fires on an UPWARD crossing (previousRatio <=
		// proactiveRatio && currentRatio > proactiveRatio). Left alone,
		// previousRatio would stay pinned above proactiveRatio forever and the
		// threshold would never "cross" again, so a deferred compaction would
		// never be retried even though it's still needed. Force previousRatio
		// back below the threshold so the next message_end tick treats current
		// usage as a fresh crossing and re-attempts — this deliberately does
		// NOT touch the edge-detection logic itself, it just un-sticks it for
		// this one case.
		previousRatio = 0;

		return { cancel: true };
	});

	pi.on("session_compact", (event, ctx) => {
		// TEMPORARY DIAGNOSTIC LOGGING — see file header. reason/willRetry are the
		// only relevant fields on this event (SessionCompactEvent, checked in the
		// installed types.d.ts) beyond compactionEntry/fromExtension; included
		// fromExtension too since it's cheap and tells us whether this was our
		// own trigger.
		diag({
			event: "session_compact_fired",
			reason: event.reason,
			willRetry: event.willRetry,
			fromExtension: event.fromExtension,
		});

		// See header comment for the full trace. willRetry: true means the
		// harness's own overflow recovery already resumes the turn — acting here
		// too would double-continue. Only act when it did NOT auto-retry.
		if (event.willRetry) return;

		if (ctx.hasUI) {
			ctx.ui.notify(
				"[context-guardian] Compaction did not auto-retry — synthesizing a continuation so the task resumes without a manual \"continue\".",
				"info",
			);
		}

		// deliverAs: "followUp" unconditionally (not gated on ctx.isIdle()) — see
		// header comment for why the session isn't reliably idle here, and why
		// "followUp" is safe and correct either way. No triggerTurn: not a valid
		// option on sendUserMessage, and none is needed — it always triggers a
		// turn on its own (see header comment).
		pi.sendUserMessage(
			"Compaction just ran mid-task and the turn was not auto-retried. Continue the task from exactly where the compaction summary left off, using the next step it recorded — do not re-derive context from scratch.",
			{ deliverAs: "followUp" },
		);
	});

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

		// TEMPORARY DIAGNOSTIC LOGGING — see file header. Stash for the
		// trigger_attempt log inside triggerCompaction() (not otherwise in scope
		// there); purely additive, not consumed by any real guard/logic.
		currentRatioForDiag = currentRatio;
		proactiveRatioForDiag = proactiveRatio;

		triggerCompaction(ctx);
	});
}
