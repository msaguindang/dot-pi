import { test } from "node:test";
import * as assert from "node:assert";
import { compileWorkflow } from "../extensions/compile-workflow.ts";

const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;

async function executeScript(script: string, runsMock: any) {
    const fn = new AsyncFunction("runs", script);
    return await fn(runsMock);
}

test("R0 compiles a read-only scout", async () => {
    const res = compileWorkflow({ task: "Look around", riskTier: "R0" });
    assert.strictEqual(res.tier, "R0");
    assert.strictEqual(res.requiresAuthorization, false);
    
    let called = false;
    const runsMock = {
        run: async (key: string, opts: any) => {
            assert.strictEqual(key, "scout");
            assert.strictEqual(opts.agent, "scout");
            assert.strictEqual(opts.task, "Look around");
            assert.strictEqual(opts.cwd, undefined);
            called = true;
            return { output: "ok" };
        }
    };
    await executeScript(res.workflowScript, runsMock);
    assert.ok(called);
});

test("R1 compiles a worker with checked acceptance", async () => {
    const res = compileWorkflow({ task: "Do work", riskTier: "R1" });
    assert.strictEqual(res.tier, "R1");
    
    let called = false;
    const runsMock = {
        run: async (key: string, opts: any) => {
            assert.strictEqual(key, "worker");
            assert.strictEqual(opts.agent, "worker");
            assert.strictEqual(opts.task, "Do work");
            assert.strictEqual(opts.acceptance, "checked");
            called = true;
            return { output: "ok" };
        }
    };
    await executeScript(res.workflowScript, runsMock);
    assert.ok(called);
});

test("R2 compiles worker then fresh reviewer", async () => {
    const res = compileWorkflow({ task: "Do risky work", riskTier: "R2", contracts: ["/tmp/contract.md"] });
    assert.strictEqual(res.tier, "R2");
    
    const calls: {key: string, opts: any}[] = [];
    const runsMock = {
        run: async (key: string, opts: any) => {
            calls.push({key, opts});
            return { output: "worker_output_mock" };
        }
    };
    await executeScript(res.workflowScript, runsMock);
    
    assert.strictEqual(calls.length, 2);
    assert.strictEqual(calls[0].key, "worker");
    assert.strictEqual(calls[0].opts.acceptance, "checked");
    assert.strictEqual(calls[1].key, "reviewer");
    assert.strictEqual(calls[1].opts.context, "fresh");
    assert.ok(calls[1].opts.task.includes("/tmp/contract.md"));
    assert.ok(calls[1].opts.task.includes("worker_output_mock"));
});

test("R3 requires contracts and hostVerifyCommands", async () => {
    assert.throws(() => compileWorkflow({ task: "Nuke everything", riskTier: "R3" }), /R3 requires contracts/);
    assert.throws(() => compileWorkflow({ task: "Nuke everything", riskTier: "R3", contracts: ["/tmp/c"] }), /R3 requires host verification/);
    
    const res = compileWorkflow({
        task: "Nuke safely",
        riskTier: "R3",
        contracts: ["/tmp/contract.md"],
        hostVerifyCommands: ["echo 'safe'"]
    });
    assert.strictEqual(res.tier, "R3");
    assert.strictEqual(res.requiresAuthorization, true);
    
    let called = false;
    const runsMock = {
        run: async (key: string, opts: any) => {
            assert.strictEqual(key, "oracle");
            assert.ok(opts.task.includes("Nuke safely"));
            assert.ok(opts.task.includes("/tmp/contract.md"));
            assert.ok(opts.task.includes("echo 'safe'"));
            called = true;
            return { output: "ok" };
        }
    };
    await executeScript(res.workflowScript, runsMock);
    assert.ok(called);
});

test("rejects relative cwd and puts absolute cwd in launchOptions", () => {
    assert.throws(() => compileWorkflow({ task: "Task", riskTier: "R0", cwd: "relative/path" }), /absolute path/);
    
    const res = compileWorkflow({ task: "Task", riskTier: "R0", cwd: "/absolute/path" });
    assert.deepStrictEqual(res.launchOptions, { cwd: "/absolute/path" });
    // Workflow script shouldn't contain the cwd
    assert.ok(!res.workflowScript.includes("/absolute/path"));
});

test("escapes strings safely and produces valid syntax", async () => {
    const maliciousTask = "task\" \n ${inject} \\ ' `";
    const res = compileWorkflow({ task: maliciousTask, riskTier: "R1" });
    
    let called = false;
    const runsMock = {
        run: async (key: string, opts: any) => {
            assert.strictEqual(opts.task, maliciousTask);
            called = true;
        }
    };
    
    // The executeScript uses eval/Function parsing, so if it parses and runs successfully, 
    // it handles newlines, quotes, backticks, backslashes, etc., properly.
    await executeScript(res.workflowScript, runsMock);
    assert.ok(called);
});

test("rejects empty tasks, contracts, host verification", () => {
    assert.throws(() => compileWorkflow({ task: "", riskTier: "R0" }), /task must be a non-empty string/);
    assert.throws(() => compileWorkflow({ task: "  ", riskTier: "R0" }), /task must be a non-empty string/);
    
    assert.throws(() => compileWorkflow({ task: "t", riskTier: "INVALID" as any }), /Unsupported risk tier/);

    assert.throws(() => compileWorkflow({ task: "t", riskTier: "R2", contracts: [""] }), /contracts must be an array of non-empty strings/);
    assert.throws(() => compileWorkflow({ task: "t", riskTier: "R2", contracts: ["  "] }), /contracts must be an array of non-empty strings/);
    
    assert.throws(() => compileWorkflow({ task: "t", riskTier: "R3", contracts: ["c"], hostVerifyCommands: [""] }), /hostVerifyCommands must be an array of non-empty strings/);
});

test("R2 requires contracts", () => {
    assert.throws(() => compileWorkflow({ task: "t", riskTier: "R2" }), /R2 requires contracts/);
    assert.throws(() => compileWorkflow({ task: "t", riskTier: "R2", contracts: [] }), /R2 requires contracts/);
});
