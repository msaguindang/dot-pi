import { test } from "node:test";
import * as assert from "node:assert/strict";
import toolLoader from "../extensions/tool-loader.ts";

type Tool = {
    name: string;
    description?: string;
    execute?: (id: string, params: { query: string }) => Promise<any>;
};

function makeApi(names: Tool[], active: string[]) {
    const registered: Tool[] = [];
    let sessionStart: (() => void) | undefined;
    let beforeAgentStart: ((event: { systemPrompt: string }) => Promise<any>) | undefined;
    let current = [...active];
    const api = {
        registerTool(tool: Tool) { registered.push(tool); },
        on(event: string, handler: () => void) {
            if (event === "session_start") sessionStart = handler;
            if (event === "before_agent_start") beforeAgentStart = handler as any;
        },
        getAllTools() { return [...names, ...registered]; },
        getActiveTools() { return [...current]; },
        setActiveTools(next: string[]) { current = [...next]; },
    };
    toolLoader(api as any);
    return { api, registered, start: () => sessionStart?.(), before: (systemPrompt: string) => beforeAgentStart?.({ systemPrompt }), active: () => current };
}

const baseTools = [
    { name: "read" }, { name: "write" }, { name: "edit" }, { name: "bash" },
    { name: "safe_bash" }, { name: "ctx_execute" }, { name: "ctx_execute_file" },
    { name: "ctx_search" }, { name: "subagent" },
    { name: "search_emails", description: "Search Gmail messages" },
    { name: "read_email", description: "Read Gmail messages" },
    { name: "weather", description: "Look up weather" },
];

test("session_start keeps only available defaults and search_tools active", () => {
    const mock = makeApi(baseTools, ["read", "weather"]);
    mock.start();
    assert.deepEqual(mock.active(), [
        "read", "write", "edit", "bash", "safe_bash", "ctx_execute",
        "ctx_execute_file", "ctx_search", "search_tools",
    ]);
    assert.deepEqual(mock.api.getAllTools().map((tool) => tool.name), baseTools.map((tool) => tool.name).concat("search_tools"));
});

test("explicit independent review auto-activates registered subagent", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    await mock.before("Please perform an independent post-mutation review of this change.");
    assert.equal(mock.active().includes("subagent"), true);
});

test("ordinary prompt does not auto-activate subagent", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    await mock.before("Explain how independent reviews work in general.");
    assert.equal(mock.active().includes("subagent"), false);
});

test("explicit review leaves subagent unavailable when it is not registered", async () => {
    const mock = makeApi(baseTools.filter((tool) => tool.name !== "subagent"), ["read", "search_tools"]);
    await mock.before("Dispatch a fresh reviewer for an independent review.");
    assert.equal(mock.active().includes("subagent"), false);
});

test("delegation-focused search activates subagent on demand", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    const loader = mock.registered.find((tool) => tool.name === "search_tools")!;
    const result = await loader.execute!("call", { query: "delegate" });
    assert.deepEqual(result.details.matches, ["subagent"]);
    assert.deepEqual(result.details.added, ["subagent"]);
    assert.deepEqual(mock.active(), ["read", "search_tools", "subagent"]);
});

test("search_tools activates bounded Gmail matches additively", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    const loader = mock.registered.find((tool) => tool.name === "search_tools")!;
    const result = await loader.execute!("call", { query: "gmail" });
    assert.deepEqual(result.details.matches, ["read_email", "search_emails"]);
    assert.deepEqual(result.details.added, ["read_email", "search_emails"]);
    assert.deepEqual(mock.active(), ["read", "search_tools", "read_email", "search_emails"]);
});

test("search_tools activates only highest-scoring multi-term matches", async () => {
    const tools = [
        ...baseTools,
        { name: "check_extension_freshness", description: "Check extension freshness and active tool inspection" },
        { name: "active_tool_report", description: "Report active tool state" },
        { name: "tool_inspector", description: "Inspect active tools" },
        { name: "extension_list", description: "List active extensions" },
    ];
    const mock = makeApi(tools, ["read", "search_tools"]);
    const loader = mock.registered.find((tool) => tool.name === "search_tools")!;
    const result = await loader.execute!("call", { query: "extension freshness and active tool inspection" });
    assert.deepEqual(result.details.matches, ["check_extension_freshness"]);
    assert.deepEqual(result.details.added, ["check_extension_freshness"]);
    assert.deepEqual(mock.active(), ["read", "search_tools", "check_extension_freshness"]);
});

test("skill catalog descriptions are stripped while names and locations remain", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    const result = await mock.before(`<available_skills><skill><name>gmail</name><description>Search Gmail deeply</description><location>/skills/gmail</location></skill></available_skills>`);
    assert.equal(result.systemPrompt.includes("<name>gmail</name>"), true);
    assert.equal(result.systemPrompt.includes("<location>/skills/gmail</location>"), true);
    assert.equal(result.systemPrompt.includes("Search Gmail deeply"), false);
});

test("search_tools returns matching skill descriptions and locations", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    await mock.before(`<available_skills><skill><name>gmail</name><description>Search Gmail deeply</description><location>/skills/gmail</location></skill></available_skills>`);
    const loader = mock.registered.find((tool) => tool.name === "search_tools")!;
    const result = await loader.execute!("call", { query: "gmail" });
    assert.equal(result.details.skills[0].description, "Search Gmail deeply");
    assert.equal(result.details.skills[0].location, "/skills/gmail");
    assert.match(result.content[0].text, /Search Gmail deeply/);
});

test("no catalog leaves the prompt unchanged", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    const prompt = "plain system prompt";
    assert.deepEqual(await mock.before(prompt), { systemPrompt: prompt });
});

test("no-match search leaves active tools unchanged", async () => {
    const mock = makeApi(baseTools, ["read", "search_tools"]);
    const loader = mock.registered.find((tool) => tool.name === "search_tools")!;
    const result = await loader.execute!("call", { query: "quantum submarine" });
    assert.deepEqual(result.details.matches, []);
    assert.deepEqual(result.details.added, []);
    assert.deepEqual(mock.active(), ["read", "search_tools"]);
});
