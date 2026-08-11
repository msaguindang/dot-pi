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
 *
 * Mid-turn abort race (2026-08-03 fix): the diagnostic logging added
 * 2026-07-22 (context-guardian-diag entries, session player-gitops-4.1) did
 * its job — one week of logs recorded 27 reason:"manual" compactions, every
 * one of them our OWN triggerCompaction() firing from message_end while a
 * turn was still in progress. Per the AgentSession.compact() trace above
 * (~line 1373: _disconnectFromAgent() → await this.abort() → compact), every
 * one of those 27 calls ran this.abort() against a live turn — killing
 * whatever the in-flight turn was still doing, every time, then relying on
 * the session_compact auto-continue below to paper over it by resuming from
 * a (possibly stale) summary. Firing from message_end was the root cause:
 * that event fires for every message inside a turn, not just at turn
 * boundaries (see the in-flight tool call race comment above), so "context
 * crossed the proactive ratio" could be, and repeatedly was, detected
 * mid-turn.
 *
 * Confirmed upstream shipped and reverted this exact pattern. Installed
 * CHANGELOG.md, line 4813, under `## [0.17.0] - 2025-12-09`: "Simplified
 * compaction flow: Removed proactive compaction (aborting mid-turn when
 * threshold approached). Compaction now triggers in two cases only: (1)
 * overflow error from LLM, which compacts and auto-retries, or (2) threshold
 * crossed after a successful turn, which compacts without retry." That's
 * precisely the bug this extension reintroduced from the outside — via
 * ctx.compact(), which upstream's own removal never touched (it only
 * changed pi's own internal auto-compaction, not the extension API). No
 * newer upstream release restores or replaces the pattern — 0.83.0 (the
 * active installed copy, see the runtime check below) is current, so there
 * is no upstream fix to adopt instead of fixing this file directly.
 * Upstream's own bundled example, examples/extensions/trigger-compact.ts
 * (same installed copy referenced throughout this file), fires its
 * threshold check from turn_end, never message_end — matching the
 * changelog's "after a successful turn" rule.
 *
 * Runtime checked: `node --version` on this machine resolves v24.18.0
 * (`which node` → ~/.nvm/versions/node/v24.18.0/bin/node), whose installed
 * @earendil-works/pi-coding-agent is 0.83.0 — the version every line number
 * in this file is cited against (v24.14.0 carries 0.80.3, v22.21.1 carries
 * 0.78.0 — neither is the active runtime, so neither was used for citations).
 *
 * Fix part 1 — fire at turn_end, not message_end: message_end's edge-detect
 * is unchanged; crossing the threshold now only sets a closure flag,
 * compactionDue = true, instead of calling triggerCompaction() directly. A
 * new turn_end handler does the actual firing: `if (compactionDue &&
 * pendingToolCallIds.size === 0) { compactionDue = false;
 * triggerCompaction(ctx); }`. Verified turn_end's shape and timing before
 * writing this: dist/core/extensions/types.d.ts line 555-560 —
 * `TurnEndEvent { type: "turn_end"; turnIndex: number; message: AgentMessage;
 * toolResults: ToolResultMessage[]; }`, doc comment "Fired at the end of
 * each turn"; and docs/extensions.md line 574-576, "Fired for each turn (one
 * LLM response + tool calls)." The docs/extensions.md event-order diagram
 * (lines 294-311) places turn_end strictly inside the per-turn block,
 * before agent_end/agent_settled — i.e. after that turn's tool_result/
 * tool_execution_end have already fired (confirmed via
 * AgentSession._emitExtensionEvent, dist/core/agent-session.js ~line
 * 443-451: turn_end is forwarded carrying that turn's already-resolved
 * toolResults). So the only thing ctx.compact()'s abort() can still cost,
 * firing here, is the next turn's LLM call, which hadn't started yet —
 * exactly the case the auto-continue below already exists to cover, and
 * nothing this turn already did is at risk.
 *
 * The pendingToolCallIds guard stays inside triggerCompaction() too (belt-
 * and-suspenders — same guard, same rationale as the original comment on
 * it, unchanged). If it defers there, it re-sets compactionDue = true
 * (turn_end already cleared it before calling in), so the very next
 * turn_end retries. onError (including the "Compaction cancelled" veto
 * case) re-arms compactionDue = true the same way, since that attempt
 * didn't actually happen; onComplete leaves it false, since a real
 * compaction did happen and previousRatio's own natural drop is what
 * re-arms detection of the next real crossing. This retires the
 * previousRatio = 0 trick that both triggerCompaction()'s old guard and the
 * session_before_compact veto used to force a re-arm: that trick was a
 * workaround for message_end being the only place that ever retried a
 * deferred compaction. Now that compactionDue/turn_end own retrying,
 * session_before_compact's veto (which exists for callers we don't
 * control — manual /compact, any other extension's compact()) no longer
 * needs to touch either variable — if it ever did veto one of OUR OWN
 * attempts (the rare race the original comment already called out as
 * unlikely, since we guard upstream of ctx.compact() first),
 * triggerCompaction()'s own onError already re-arms compactionDue from that
 * same "Compaction cancelled" error.
 *
 * Fix part 2 — gate the auto-continue on a run actually being active: firing
 * at turn boundaries means a guardian-triggered compaction can now land on
 * the LAST turn of an already-finished response (no more tool calls
 * queued), where sendUserMessage's synthetic "continue" would prod a
 * genuinely idle agent into re-doing or inventing work instead of resuming
 * real progress. Needed a "was a run actually in progress" signal at
 * session_compact time. Checked which lifecycle event means "won't run
 * again on its own": dist/core/extensions/types.d.ts line 545-547,
 * AgentSettledEvent, "Fired after an agent run has fully settled and no
 * automatic retry, compaction, or queued continuation will run";
 * docs/extensions.md line 560, "`agent_start` fires when a low-level agent
 * run begins. `agent_end` fires when that run ends, but Pi may still
 * auto-retry, auto-compact and retry, or continue with queued follow-up
 * messages. Use `agent_settled` for status integrations that need to know
 * Pi will not continue running automatically." So runActive is tracked
 * agent_start → true, agent_settled → false — deliberately not agent_end.
 *
 * A live runActive read at session_compact time is NOT enough by itself,
 * though — traced dist/core/agent-session.js for both reasons that can
 * reach session_compact:
 *   - reason: "threshold"/"overflow" (_runAutoCompaction, ~line 1591,
 *     called from _checkCompaction from _handlePostAgentRun, ~line
 *     758-782) runs inside _runAgentPrompt's try block (~line 744-756),
 *     strictly BEFORE its finally calls _emitAgentSettled (~line 755).
 *     runActive is still genuinely true here — a live read is correct and
 *     sufficient.
 *   - reason: "manual" (compact(), ~line 1367) calls `await this.abort()`
 *     (~line 1369) before session_compact is ever emitted (~line 1441), and
 *     abort() (~line 1165-1169) calls waitForIdle(), which blocks until
 *     _emitAgentSettled has already flipped runActive false (~line
 *     305-323). So for THIS reason, by the time session_compact fires,
 *     runActive reads false unconditionally — regardless of whether a turn
 *     was genuinely active a moment earlier. That's true whether the
 *     manual compaction was our own (now fired from turn_end, always
 *     mid-run at the moment we call it) or a real user /compact (which, if
 *     issued while genuinely idle, had runActive already false before
 *     abort() ran anyway — abort()-on-an-idle-session is a no-op per
 *     waitForIdle()'s `if (this.isIdle) return;`, ~line 1171). A live read
 *     can't tell these two "manual" cases apart; it's degenerate (always
 *     false) exactly on the path that matters most: our own trigger.
 *
 * So the gate is `ourCompactionInFlight || runActive`. ourCompactionInFlight
 * is set true the instant triggerCompaction() decides to actually call
 * ctx.compact() — strictly before that call's own internal abort() has a
 * chance to run, so it's a snapshot of the true pre-abort state, taken by
 * the one caller (us) who's actually in a position to take it — and cleared
 * false in onComplete, onError, and the outer synchronous catch, so it can
 * never get stuck true past our own attempt's resolution. Because
 * triggerCompaction() is now only ever invoked from turn_end (mid-run by
 * definition), ourCompactionInFlight being true always correctly means a
 * run was active a moment before we (deliberately) aborted it — sidestepping
 * the abort-ordering problem entirely for our own case instead of trying to
 * out-race it. For every other "manual" case (a foreign /compact, another
 * extension's compact()) there is no hook that fires before that caller's
 * own abort() runs, so there's no reliable signal available at all;
 * runActive there reads false the same as the genuinely-idle case, which
 * means we simply don't auto-continue for compactions we didn't trigger
 * ourselves — an acceptable default, since a human present enough to type
 * /compact by hand can just as easily type "continue" if they want to.
 *
 * Diagnostic logging removed: the 2026-07-22 diag() helper and its call
 * sites (message_end no longer even has a triggerCompaction() call site to
 * log around) have served their purpose — the race they were added to
 * confirm is exactly the one this fix addresses. Nothing about the guard
 * logic itself changed as a result of removing them (they were purely
 * additive, per their own original comments).
 *
 * 2026-08-04 addendum — redundant double-compaction when pi's own
 * compaction lands first: compactionDue was only ever cleared in turn_end,
 * right before calling triggerCompaction(). If the guardian was deferred
 * (pending tool calls) while context kept climbing past the harness's own
 * reactive threshold, pi's internal auto-compaction could fire and shrink
 * context on its own — but compactionDue stayed true, so the next turn_end
 * fired a second, unnecessary compaction on already-fresh context. Fixed by
 * clearing compactionDue unconditionally at the top of session_compact,
 * before the willRetry/runActive gates: any completed compaction, regardless
 * of reason or who triggered it, satisfies the need the flag represents.
 * Harness-internal compaction now also disarms the guardian's pending
 * trigger, same as our own.
 *
 * 2026-08-11 addendum — compaction-count status badge: mined evidence from a
 * prior session showed 35 compactions correlated with that session becoming
 * effectively unrecoverable — the agent kept losing the thread and the
 * session needed a fresh start via /skill:session-distiller +
 * /skill:takeover. An automated threshold-notification for this was
 * considered and deliberately NOT built — "how many is too many" is a
 * judgment call that depends on the task, not a constant worth hardcoding.
 * Instead, this adds a persistent, glanceable ♻️ count to the status bar (same
 * ctx.ui.setStatus mechanism the other badges in this harness use) so the
 * user can notice the trend themselves and act on it before things degrade.
 * The counter increments for EVERY compaction that actually lands this
 * session — this extension's own proactive trigger, the harness's own
 * reactive/threshold/overflow compaction, and any manual /compact — so the
 * increment sits at the very top of the session_compact handler below,
 * before the willRetry/ourCompactionInFlight-or-runActive gates that only
 * decide whether to auto-continue, not whether a compaction happened. Shown
 * only from the first compaction onward (suppressed at 0) — a fresh session
 * has nothing to show yet, and an always-present "♻️ 0" would just be bar
 * clutter with no signal.
 *
 * 2026-08-11 addendum #2 — badge resets to 0 on reload, the exact case it
 * exists to flag: compactionCount is module-scope (`let compactionCount = 0`
 * below), and extensions get reloaded live when their files change (confirmed
 * directly today — editing this file mid-session updated the TUI without a
 * full restart). A reload re-runs this module's top level, resetting
 * compactionCount back to 0 — so a long-running session that gets reloaded
 * mid-flight loses its true count until the next NEW compaction, undercounting
 * a long session exactly when the badge matters most.
 *
 * session_start DOES fire on a live reload — confirmed two ways: (1)
 * types.d.ts SessionStartEvent.reason (~line 418 of the installed package's
 * dist/core/extensions/types.d.ts) is `"startup" | "reload" | "new" |
 * "resume" | "fork"`, "reload" included; (2) dist/core/agent-session.js,
 * AgentSession.reload() (~line 2052), literally emits
 * `this._extensionRunner.emit({ type: "session_start", reason: "reload" })`
 * (~line 2072) as part of the same reload path that just re-ran this module.
 * So a new session_start handler, seeding compactionCount there, actually
 * fires on the reload this bug is about.
 *
 * Seeding source — ctx.sessionManager, not a hand-resolved file path:
 * ExtensionContext.sessionManager (types.d.ts ~line 219) is typed
 * ReadonlySessionManager, a Pick of SessionManager (session-manager.d.ts
 * ~line 140) that includes getEntries() and getSessionFile(). Deliberately
 * used getEntries() directly instead of reading getSessionFile()'s path off
 * disk: traced AgentSession.reload() (agent-session.js ~line 2037,
 * `new ExtensionRunner(..., this.sessionManager, ...)`) — reload() passes the
 * SAME live `this.sessionManager` instance into the new ExtensionRunner, it is
 * never recreated on reload. That sidesteps the "which file is actually THIS
 * session" ambiguity a disk-based mtime/glob lookup would have (multiple
 * sessions can be open at once) entirely — there's no file path resolution
 * step at all, just an in-memory, already-known-current handle. getEntries()
 * (session-manager.d.ts ~line 281, "Get all session entries... The session is
 * append-only") returns every entry ever appended this session, including
 * CompactionEntry ones — confirmed appendCompaction() (session-manager.js
 * ~line 803) constructs `{ type: "compaction", ... }` and stores it via the
 * same _appendEntry() every other entry type goes through, so it's included
 * in getEntries()'s result like any other entry. Filtering that array for
 * `type === "compaction"` and taking .length is the seed count.
 *
 * Session_start's own reason field is not otherwise used: "new"/"resume"/
 * "fork" all correctly have zero or their own already-correct prior entries
 * (getEntries() reflects whichever session is actually loaded regardless of
 * reason), and "startup" (first-ever load) also just reads real entries (0
 * for a fresh session — badge suppression at 0 is unchanged, see the addendum
 * above). So the handler doesn't branch on reason at all; it re-derives from
 * ground truth every time it fires, which is correct for every reason
 * including repeated reloads in one session (each reload's larger transcript
 * naturally produces a larger, correct count — no double-counting, since it's
 * a recomputed length, not an increment).
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

// Module-scope: a running total of every compaction that has landed in THIS
// SESSION. See the 2026-08-11 header addendum above for why it counts all
// compactions, not just this extension's own trigger. Starts at 0 here for a
// truly fresh module load; the session_start handler below re-seeds it from
// the session's own transcript on every fire (including "reload"), so this
// initial value only ever matters for the brief window before that handler
// first runs.
let compactionCount = 0;

export default function (pi: ExtensionAPI): void {
	// Edge-detect the threshold crossing (same idiom as the harness's own
	// trigger-compact.ts example): ask once per upward crossing, not on every
	// message_end while already above it. After a successful compaction,
	// usage drops well below threshold, so this naturally re-arms itself for
	// the next time context climbs back up.
	let previousRatio: number | null = null;

	// Set true when message_end detects an upward threshold crossing, cleared
	// once turn_end actually attempts a compaction. See the 2026-08-03 header
	// section (fix part 1) for why firing itself is deferred to turn_end
	// instead of happening right there in message_end.
	let compactionDue = false;

	// Tracks whether a low-level agent run is currently active. See the
	// 2026-08-03 header section (fix part 2) for the agent_settled citation
	// and why that event, not agent_end, is the "won't run again on its own"
	// signal this needs.
	let runActive = false;

	// True from the instant triggerCompaction() decides to call ctx.compact()
	// until that attempt resolves (onComplete/onError) or throws
	// synchronously. See the 2026-08-03 header section (fix part 2) for why
	// this, not a live runActive read, is the only reliable "was a run
	// active" signal available once session_compact actually fires for our
	// own compaction attempts.
	let ourCompactionInFlight = false;

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

	// Shared with the session_start seeding handler below (2026-08-11 addendum
	// #2) so a reload that re-seeds a nonzero count re-renders the badge
	// immediately, instead of leaving it stale/absent until the next new
	// compaction. Suppressed at 0 either way — see the original 2026-08-11
	// addendum for why an always-present "♻️ 0" is just clutter.
	const renderCompactionBadge = (ctx: ExtensionContext) => {
		if (!ctx.hasUI || compactionCount === 0) return;
		try {
			const theme = ctx.ui.theme;
			const text = theme?.fg
				? theme.fg("muted", "compactions: ") + theme.fg("text", `♻️ ${compactionCount}`)
				: `♻️ compactions: ${compactionCount}`;
			ctx.ui.setStatus("compaction-count", text);
		} catch {
			// ctx.ui.theme can throw before initTheme (same guard the ponytail
			// extension's syncStatus uses) — the badge just skips this update
			// rather than crash the compaction flow (or session start) over it.
		}
	};

	const triggerCompaction = (ctx: ExtensionContext) => {
		// Primary guard (see header comment for the trace): check BEFORE calling
		// ctx.compact() at all. session_before_compact fires too late — inside
		// AgentSession.compact(), after _disconnectFromAgent()/abort() already
		// ran — to protect anything for our own trigger. Skipping the call here
		// means those two never execute on our behalf while a call is pending.
		if (pendingToolCallIds.size > 0) {
			if (ctx.hasUI) {
				ctx.ui.notify(
					`[context-guardian] Deferring compaction — ${pendingToolCallIds.size} tool call(s) still in flight. Will retry once they finish.`,
					"info",
				);
			}
			// turn_end already cleared compactionDue before calling in here —
			// this attempt didn't happen, so re-set it so the next turn_end
			// retries. Replaces the old previousRatio = 0 re-arm trick — see
			// the 2026-08-03 header section (fix part 1).
			compactionDue = true;
			return;
		}

		if (ctx.hasUI) {
			ctx.ui.notify(
				"[context-guardian] Context usage crossed the proactive threshold — triggering compaction now, ahead of the harness's reactive threshold.",
				"info",
			);
		}
		// Snapshot "a run is active" before compact()'s own internal abort()
		// gets a chance to flip it false. See the 2026-08-03 header section
		// (fix part 2) for why this has to happen here, not read later.
		ourCompactionInFlight = true;
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
					ourCompactionInFlight = false;
					if (ctx.hasUI) ctx.ui.notify("[context-guardian] Proactive compaction completed.", "info");
				},
				onError: (error) => {
					// Same safety-net as onComplete — covers both a genuine failure
					// and the "Compaction cancelled" case below.
					pendingToolCallIds.clear();
					ourCompactionInFlight = false;
					// This attempt didn't happen either — re-arm so the next
					// turn_end retries.
					compactionDue = true;

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
			ourCompactionInFlight = false;
			compactionDue = true;
			const msg = err instanceof Error ? err.message : String(err);
			if (ctx.hasUI) {
				ctx.ui.notify(`[context-guardian] Could not trigger compaction (${msg}). Run /compact manually.`, "warning");
			}
		}
	};

	pi.on("session_start", (_event, ctx) => {
		// Re-seed compactionCount from this session's own transcript on every
		// fire — including reason: "reload", which is exactly the case the
		// 2026-08-11 addendum #2 (header) is fixing. See that addendum for the
		// full trace on why ctx.sessionManager.getEntries() (not a hand-resolved
		// file path) is the right source, and why session_start genuinely fires
		// on a live extension reload. Fails soft to 0 — never let a seeding
		// problem block session start.
		try {
			compactionCount = ctx.sessionManager.getEntries().filter((entry) => entry.type === "compaction").length;
		} catch {
			compactionCount = 0;
		}
		renderCompactionBadge(ctx);
	});

	pi.on("agent_start", () => {
		runActive = true;
	});

	pi.on("agent_settled", () => {
		runActive = false;
	});

	pi.on("tool_call", (event) => {
		pendingToolCallIds.add(event.toolCallId);
	});

	pi.on("tool_execution_end", (event) => {
		pendingToolCallIds.delete(event.toolCallId);
	});

	pi.on("session_before_compact", (_event, ctx) => {
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

		// No compactionDue/previousRatio bookkeeping needed here anymore (see
		// the 2026-08-03 header section, fix part 1) — this veto exists for
		// callers we don't control, and doesn't own the retry state for our own
		// scheduling. If it ever does veto one of OUR OWN attempts instead (the
		// rare race the comment above already calls out as unlikely, since we
		// guard upstream of ctx.compact() first), triggerCompaction()'s own
		// onError re-arms compactionDue from that same "Compaction cancelled"
		// error.
		return { cancel: true };
	});

	pi.on("session_compact", (event, ctx) => {
		// Count every landed compaction, before any gate below — see the
		// 2026-08-11 header addendum. Sits ahead of the willRetry/runActive
		// gates deliberately: those decide whether to auto-continue, not
		// whether a compaction happened, and this counter tracks the latter.
		compactionCount += 1;
		renderCompactionBadge(ctx);

		// Disarm unconditionally, before any gate below: ANY compaction that
		// actually lands — ours, the harness's own reactive/threshold or
		// overflow compaction, manual /compact, another extension's — means
		// context usage genuinely dropped, satisfying whatever need set
		// compactionDue true. If we left it set here, a compaction we didn't
		// initiate (e.g. pi's own threshold compaction firing while we were
		// deferred behind pending tool calls) would still leave compactionDue
		// true, and the very next turn_end would fire a second, redundant
		// compaction on the freshly-compacted context — wasted tokens and a
		// summary-of-a-summary. previousRatio doesn't need the same treatment:
		// it self-corrects on its own from the next message_end's usage read.
		compactionDue = false;

		// See header comment for the full trace. willRetry: true means the
		// harness's own overflow recovery already resumes the turn — acting here
		// too would double-continue. Only act when it did NOT auto-retry.
		if (event.willRetry) return;

		// Gate on a run actually having been active — see the 2026-08-03 header
		// section (fix part 2) for the full abort-ordering trace on why this is
		// `ourCompactionInFlight || runActive` and not a bare runActive read.
		if (!ourCompactionInFlight && !runActive) return;

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

	pi.on("turn_end", (_event, ctx) => {
		// Fires at the end of each turn, after that turn's tool calls have
		// already resolved — see the 2026-08-03 header section (fix part 1)
		// for the citations backing this timing.
		if (!compactionDue) return;
		if (pendingToolCallIds.size > 0) return;
		compactionDue = false;
		triggerCompaction(ctx);
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

		// Don't trigger compaction from here — see the 2026-08-03 header
		// section (fix part 1). message_end fires mid-turn, and ctx.compact()
		// aborts the in-flight turn; just flag that we're due and let turn_end
		// below fire it once this turn's work is actually done.
		compactionDue = true;
	});
}
