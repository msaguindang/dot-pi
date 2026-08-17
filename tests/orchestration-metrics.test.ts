import { test } from "node:test";
import * as assert from "node:assert";
import { parseTelemetryFile, aggregateMetrics, findTelemetryFiles } from "../scripts/orchestration-metrics.ts";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execSync } from "node:child_process";

test("parseTelemetryFile parses _meta.json", () => {
    const validJson = JSON.stringify({
        runId: "123",
        agent: "worker",
        model: "claude",
        acceptance: { status: "attested" },
        durationMs: 1000,
        usage: { turns: 5, input: 10, output: 20, cacheRead: 30, cost: 0.1 },
        toolCount: 2
    });
    const parsed = parseTelemetryFile("test_meta.json", validJson);
    assert.strictEqual(parsed.length, 1);
    assert.strictEqual(parsed[0].priority, 0);
    assert.deepStrictEqual(parsed[0].record, {
        runId: "123",
        agent: "worker",
        model: "claude",
        acceptanceStatus: "attested",
        durationMs: 1000,
        turns: 5,
        toolCount: 2,
        inputTokens: 10,
        outputTokens: 20,
        cacheTokens: 30,
        cost: 0.1
    });
});

test("parseTelemetryFile parses status.json", () => {
    const validJson = JSON.stringify({
        runId: "envelope",
        steps: [
            { runId: "child1", status: "completed", agent: "worker", durationMs: 500, turnCount: 2, toolCount: 1, model: "m1" },
            { runId: "child2", status: "started" } // ignored
        ]
    });
    const parsed = parseTelemetryFile("status.json", validJson);
    assert.strictEqual(parsed.length, 1);
    assert.strictEqual(parsed[0].priority, 1);
    assert.strictEqual(parsed[0].record.runId, "child1");
    assert.strictEqual(parsed[0].record.durationMs, 500);
});

test("parseTelemetryFile parses events.jsonl and reports corrupt lines to stderr", () => {
    const origError = console.error;
    let errorLog = "";
    console.error = (msg) => { errorLog += msg + "\n"; };

    const validJsonl = `{"event":"foo"}
invalid
{"state":"completed","runId":"child-event","agent":"scout","durationMs":150,"turns":3,"toolCount":5,"model":"m2"}
{"state":"started"}`;
    const parsed = parseTelemetryFile("events.jsonl", validJsonl);
    console.error = origError;

    assert.strictEqual(parsed.length, 1);
    assert.strictEqual(parsed[0].priority, 2);
    assert.strictEqual(parsed[0].record.runId, "child-event");
    assert.strictEqual(parsed[0].record.turns, 3);
    assert.match(errorLog, /Error parsing events.jsonl:2/);
});

test("parseTelemetryFile skips corrupt files silently", () => {
    const origError = console.error;
    let errorCalled = false;
    console.error = () => { errorCalled = true; };
    const parsed = parseTelemetryFile("test_meta.json", "invalid json");
    console.error = origError;
    assert.strictEqual(parsed.length, 0);
    assert.ok(errorCalled);
});

test("aggregateMetrics deduplicates deterministically with source precedence", () => {
    const records = [
        { record: { runId: "1", agent: "worker", model: "m", acceptanceStatus: "a", durationMs: 100, turns: 1, toolCount: 1, inputTokens: 10, outputTokens: 10, cacheTokens: 10, cost: 1 }, priority: 2 },
        { record: { runId: "1", agent: "worker", model: "m", acceptanceStatus: "a", durationMs: 999, turns: 9, toolCount: 9, inputTokens: 90, outputTokens: 90, cacheTokens: 90, cost: 9 }, priority: 0 },
        { record: { runId: "2", agent: "reviewer", model: "m", acceptanceStatus: "a", durationMs: 300, turns: 3, toolCount: 3, inputTokens: 30, outputTokens: 30, cacheTokens: 30, cost: 3 }, priority: 1 },
    ];
    
    const aggregated = aggregateMetrics(records);
    
    assert.strictEqual(aggregated.sampleCount, 2);
    
    // priority 0 should win for runId 1
    assert.strictEqual(aggregated.overall.totals.tokens, 270 + 90);
    
    // sorting: p50 duration (300 and 999) -> 649.5
    assert.strictEqual(aggregated.overall.p50.durationMs, 649.5);
});

test("aggregateMetrics equal-priority duplicates are input-order independent", () => {
    const recordA = { record: { runId: "tie", agent: "A", model: "m", acceptanceStatus: "a", durationMs: 100, turns: 1, toolCount: 1, inputTokens: 10, outputTokens: 10, cacheTokens: 10, cost: 1 }, priority: 2 };
    const recordB = { record: { runId: "tie", agent: "B", model: "m", acceptanceStatus: "a", durationMs: 200, turns: 2, toolCount: 2, inputTokens: 20, outputTokens: 20, cacheTokens: 20, cost: 2 }, priority: 2 };
    // B has higher score (higher values)

    const agg1 = aggregateMetrics([recordA, recordB]);
    const agg2 = aggregateMetrics([recordB, recordA]);

    assert.strictEqual(agg1.sampleCount, 1);
    assert.strictEqual(agg2.sampleCount, 1);
    // Should both be B
    assert.strictEqual(agg1.overall.totals.durationMs, 200);
    assert.strictEqual(agg2.overall.totals.durationMs, 200);

    const tie1 = { record: { runId: "lex", agent: "X", model: "m", acceptanceStatus: "a", durationMs: 10, turns: 1, toolCount: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, cost: 0 }, priority: 2 };
    const tie2 = { record: { runId: "lex", agent: "Y", model: "m", acceptanceStatus: "a", durationMs: 10, turns: 1, toolCount: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, cost: 0 }, priority: 2 };
    // Same score, X < Y in JSON string (agent "X" vs "Y")
    // Wait, lexNew > lexOld will pick Y over X, let's verify both orders give the same result

    const agg3 = aggregateMetrics([tie1, tie2]);
    const agg4 = aggregateMetrics([tie2, tie1]);

    assert.strictEqual(agg3.sampleCount, 1);
    assert.deepStrictEqual(agg3.perAgent, agg4.perAgent);
    assert.strictEqual(Object.keys(agg3.perAgent)[0], "Y");
});

test("CLI handles mixed input, duplicate precedence, and invalid records", () => {
    const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), "metrics-test-"));
    try {
        fs.mkdirSync(path.join(tmpdir, "a"));
        fs.mkdirSync(path.join(tmpdir, "b"));
        
        fs.writeFileSync(path.join(tmpdir, "a", "1_meta.json"), JSON.stringify({
            runId: "id1", agent: "w1", durationMs: 100, usage: { cost: 1 }
        }));
        fs.writeFileSync(path.join(tmpdir, "a", "status.json"), JSON.stringify({
            steps: [{ runId: "id1", status: "completed", agent: "w1", durationMs: 999 }]
        }));
        fs.writeFileSync(path.join(tmpdir, "b", "events.jsonl"), `{"state":"completed","runId":"id2","agent":"w2","durationMs":200}\n`);
        fs.writeFileSync(path.join(tmpdir, "b", "corrupt_meta.json"), `invalid`);
        
        const scriptPath = path.resolve(import.meta.dirname, "../scripts/orchestration-metrics.ts");
        const out = execSync(`node --experimental-strip-types "${scriptPath}" "${tmpdir}"`, { encoding: "utf-8" });
        const res = JSON.parse(out);
        
        assert.strictEqual(res.sampleCount, 2);
        assert.strictEqual(res.overall.totals.durationMs, 300); // 100 (meta priority 0) + 200 (event priority 2)
        assert.strictEqual(res.perAgent["w1"].totals.durationMs, 100);
        
        // p95
        assert.strictEqual(res.overall.p95.durationMs, 195);

    } finally {
        fs.rmSync(tmpdir, { recursive: true, force: true });
    }
});

test("CLI exits 1 on no valid records", () => {
    const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), "metrics-test-empty-"));
    try {
        fs.writeFileSync(path.join(tmpdir, "empty_meta.json"), `{"foo":"bar"}`);
        const scriptPath = path.resolve(import.meta.dirname, "../scripts/orchestration-metrics.ts");
        assert.throws(() => {
            execSync(`node --experimental-strip-types "${scriptPath}" "${tmpdir}"`, { stdio: "ignore" });
        });
    } finally {
        fs.rmSync(tmpdir, { recursive: true, force: true });
    }
});
