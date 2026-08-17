#!/usr/bin/env node
import * as fs from "node:fs";
import * as path from "node:path";
import * as process from "node:process";

export interface NormalizedMetrics {
    runId: string;
    agent: string;
    model: string;
    acceptanceStatus: string;
    durationMs: number;
    turns: number;
    toolCount: number;
    inputTokens: number;
    outputTokens: number;
    cacheTokens: number; // typically cacheRead
    cost: number;
}

function toFiniteNumber(val: unknown): number {
    const num = Number(val);
    return Number.isFinite(num) ? num : 0;
}

export function parseTelemetryFile(filePath: string, content: string): { record: NormalizedMetrics, priority: number }[] {
    const results: { record: NormalizedMetrics, priority: number }[] = [];
    const name = path.basename(filePath);

    if (name.endsWith("_meta.json")) {
        try {
            const data = JSON.parse(content) as Record<string, unknown>;
            if (data && data.runId) {
                const modelObj = data.model as Record<string, unknown>;
                const acceptance = data.acceptance as Record<string, unknown>;
                const usage = data.usage as Record<string, unknown>;
                results.push({
                    record: {
                        runId: String(data.runId),
                        agent: String(data.agent || "unknown"),
                        model: typeof data.model === "string" ? data.model : (modelObj?.name ? String(modelObj.name) : "unknown"),
                        acceptanceStatus: acceptance?.status ? String(acceptance.status) : "unknown",
                        durationMs: toFiniteNumber(data.durationMs),
                        turns: toFiniteNumber(usage?.turns ?? data.turnCount ?? data.turns),
                        toolCount: toFiniteNumber(data.toolCount),
                        inputTokens: toFiniteNumber(usage?.input),
                        outputTokens: toFiniteNumber(usage?.output),
                        cacheTokens: toFiniteNumber(usage?.cacheRead),
                        cost: toFiniteNumber(usage?.cost),
                    },
                    priority: 0
                });
            }
        } catch (e: unknown) {
            if (e instanceof Error) console.error(`Error parsing ${filePath}: ${e.message}`);
        }
    } else if (name === "status.json") {
        try {
            const data = JSON.parse(content) as Record<string, unknown>;
            if (data && Array.isArray(data.steps)) {
                for (const step of data.steps) {
                    if (step && typeof step === "object" && (step.status === "completed" || step.state === "completed") && step.runId) {
                        const modelObj = step.model as Record<string, unknown>;
                        results.push({
                            record: {
                                runId: String(step.runId),
                                agent: String(step.agent || "unknown"),
                                model: typeof step.model === "string" ? step.model : (modelObj?.name ? String(modelObj.name) : "unknown"),
                                acceptanceStatus: "unknown",
                                durationMs: toFiniteNumber(step.durationMs),
                                turns: toFiniteNumber(step.turnCount ?? step.turns),
                                toolCount: toFiniteNumber(step.toolCount),
                                inputTokens: 0,
                                outputTokens: 0,
                                cacheTokens: 0,
                                cost: 0,
                            },
                            priority: 1
                        });
                    }
                }
            }
        } catch (e: unknown) {
            if (e instanceof Error) console.error(`Error parsing ${filePath}: ${e.message}`);
        }
    } else if (name === "events.jsonl") {
        const lines = content.split("\n");
        let lineNum = 1;
        for (const line of lines) {
            if (!line.trim()) {
                lineNum++;
                continue;
            }
            try {
                const data = JSON.parse(line) as Record<string, unknown>;
                
                // Also handle the envelope trace format: { trace: [...] }
                if (data && Array.isArray(data.trace)) {
                    for (const t of data.trace) {
                        if (t && typeof t === "object" && (t.state === "completed" || t.status === "completed") && t.runId) {
                            const modelObj = t.model as Record<string, unknown>;
                            results.push({
                                record: {
                                    runId: String(t.runId),
                                    agent: String(t.agent || "unknown"),
                                    model: typeof t.model === "string" ? t.model : (modelObj?.name ? String(modelObj.name) : "unknown"),
                                    acceptanceStatus: "unknown",
                                    durationMs: toFiniteNumber(t.durationMs),
                                    turns: toFiniteNumber(t.turnCount ?? t.turns),
                                    toolCount: toFiniteNumber(t.toolCount),
                                    inputTokens: 0,
                                    outputTokens: 0,
                                    cacheTokens: 0,
                                    cost: 0,
                                },
                                priority: 2
                            });
                        }
                    }
                } else if (data && (data.state === "completed" || data.status === "completed") && data.runId) {
                    const modelObj = data.model as Record<string, unknown>;
                    results.push({
                        record: {
                            runId: String(data.runId),
                            agent: String(data.agent || "unknown"),
                            model: typeof data.model === "string" ? data.model : (modelObj?.name ? String(modelObj.name) : "unknown"),
                            acceptanceStatus: "unknown",
                            durationMs: toFiniteNumber(data.durationMs),
                            turns: toFiniteNumber(data.turnCount ?? data.turns),
                            toolCount: toFiniteNumber(data.toolCount),
                            inputTokens: 0,
                            outputTokens: 0,
                            cacheTokens: 0,
                            cost: 0,
                        },
                        priority: 2
                    });
                }
            } catch (e: unknown) {
                if (e instanceof Error) console.error(`Error parsing ${filePath}:${lineNum}: ${e.message}`);
            }
            lineNum++;
        }
    }

    return results;
}

export function findTelemetryFiles(targetPath: string): string[] {
    const files: string[] = [];
    try {
        const stat = fs.statSync(targetPath);
        if (stat.isFile()) {
            const name = path.basename(targetPath);
            if (name.endsWith("_meta.json") || name === "status.json" || name === "events.jsonl") {
                files.push(targetPath);
            }
        } else if (stat.isDirectory()) {
            const entries = fs.readdirSync(targetPath).sort();
            for (const entry of entries) {
                files.push(...findTelemetryFiles(path.join(targetPath, entry)));
            }
        }
    } catch (e: unknown) {
        if (e instanceof Error) console.error(`Error accessing ${targetPath}: ${e.message}`);
    }
    return files;
}

function percentile(arr: number[], p: number): number {
    if (arr.length === 0) return 0;
    const sorted = [...arr].sort((a, b) => a - b);
    const index = (p / 100) * (sorted.length - 1);
    const lower = Math.floor(index);
    const upper = Math.ceil(index);
    if (lower === upper) return sorted[lower];
    const weight = index - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

export function aggregateMetrics(records: { record: NormalizedMetrics, priority: number }[]) {
    const deduplicated = new Map<string, { record: NormalizedMetrics, priority: number }>();
    
    const getScore = (r: NormalizedMetrics) => 
        r.durationMs + r.turns + r.toolCount + r.inputTokens + r.outputTokens + r.cacheTokens + r.cost;
        
    const getLexical = (r: NormalizedMetrics) => 
        JSON.stringify(Object.entries(r).sort((a, b) => a[0].localeCompare(b[0])));

    for (const r of records) {
        const existing = deduplicated.get(r.record.runId);
        if (!existing || r.priority < existing.priority) {
            deduplicated.set(r.record.runId, r);
        } else if (r.priority === existing.priority) {
            const scoreNew = getScore(r.record);
            const scoreOld = getScore(existing.record);
            if (scoreNew > scoreOld) {
                deduplicated.set(r.record.runId, r);
            } else if (scoreNew === scoreOld) {
                const lexNew = getLexical(r.record);
                const lexOld = getLexical(existing.record);
                if (lexNew > lexOld) {
                    deduplicated.set(r.record.runId, r);
                }
            }
        }
    }
    const finalRecords = Array.from(deduplicated.values()).map(r => r.record);

    finalRecords.sort((a, b) => a.runId.localeCompare(b.runId));

    const computeStats = (items: NormalizedMetrics[]) => {
        const durations = items.map(i => i.durationMs);
        const turns = items.map(i => i.turns);
        const tools = items.map(i => i.toolCount);
        const tokens = items.map(i => i.inputTokens + i.outputTokens + i.cacheTokens);
        const costs = items.map(i => i.cost);

        return {
            count: items.length,
            p50: {
                cost: percentile(costs, 50),
                durationMs: percentile(durations, 50),
                tokens: percentile(tokens, 50),
                tools: percentile(tools, 50),
                turns: percentile(turns, 50),
            },
            p95: {
                cost: percentile(costs, 95),
                durationMs: percentile(durations, 95),
                tokens: percentile(tokens, 95),
                tools: percentile(tools, 95),
                turns: percentile(turns, 95),
            },
            totals: {
                cost: costs.reduce((a, b) => a + b, 0),
                durationMs: durations.reduce((a, b) => a + b, 0),
                tokens: tokens.reduce((a, b) => a + b, 0),
                tools: tools.reduce((a, b) => a + b, 0),
                turns: turns.reduce((a, b) => a + b, 0),
            }
        };
    };

    const overall = computeStats(finalRecords);
    
    const byAgent = new Map<string, NormalizedMetrics[]>();
    for (const r of finalRecords) {
        const list = byAgent.get(r.agent) || [];
        list.push(r);
        byAgent.set(r.agent, list);
    }

    const perAgent: Record<string, ReturnType<typeof computeStats>> = {};
    const sortedAgents = Array.from(byAgent.keys()).sort();
    for (const agent of sortedAgents) {
        perAgent[agent] = computeStats(byAgent.get(agent)!);
    }

    return {
        overall,
        perAgent,
        sampleCount: finalRecords.length
    };
}

// CLI Execution
if (import.meta.url === `file://${process.argv[1]}`) {
    const paths = process.argv.slice(2);
    if (paths.length === 0) {
        console.error("Usage: orchestration-metrics.ts <path1> [path2...]");
        process.exit(1);
    }

    const files = paths.flatMap(p => findTelemetryFiles(p));
    const records: { record: NormalizedMetrics, priority: number }[] = [];
    
    for (const f of files) {
        try {
            const content = fs.readFileSync(f, "utf-8");
            const parsed = parseTelemetryFile(f, content);
            if (parsed.length > 0) {
                records.push(...parsed);
            } else {
                console.error(`Skipped unreadable or corrupt record: ${f}`);
            }
        } catch (e: unknown) {
            if (e instanceof Error) console.error(`Error reading ${f}: ${e.message}`);
        }
    }

    if (records.length === 0) {
        console.error("No valid records found.");
        process.exit(1);
    }

    const aggregated = aggregateMetrics(records);
    console.log(JSON.stringify(aggregated, null, 2));
}
