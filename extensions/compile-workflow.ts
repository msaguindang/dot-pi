import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// The schema is structurally compatible with JSONSchema
export const CompileWorkflowParams = {
    type: "object" as const,
    additionalProperties: false,
    properties: {
        task: { type: "string" as const, minLength: 1 },
        riskTier: { enum: ["R0", "R1", "R2", "R3"] as const },
        cwd: { type: "string" as const },
        contracts: {
            type: "array" as const,
            items: { type: "string" as const, minLength: 1 }
        },
        hostVerifyCommands: {
            type: "array" as const,
            items: { type: "string" as const, minLength: 1 }
        }
    },
    required: ["task", "riskTier"]
};

export interface CompileWorkflowInput {
    task: string;
    riskTier: "R0" | "R1" | "R2" | "R3";
    cwd?: string;
    contracts?: string[];
    hostVerifyCommands?: string[];
}

export interface CompileWorkflowOutput {
    tier: "R0" | "R1" | "R2" | "R3";
    workflowScript: string;
    requiresAuthorization: boolean;
    assumptions: string[];
    launchOptions?: {
        cwd?: string;
    };
}

export function compileWorkflow(input: CompileWorkflowInput): CompileWorkflowOutput {
    const { task, riskTier, cwd, contracts, hostVerifyCommands } = input;

    if (!task || typeof task !== "string" || task.trim().length === 0) {
        throw new Error("task must be a non-empty string");
    }
    if (!["R0", "R1", "R2", "R3"].includes(riskTier)) {
        throw new Error(`Unsupported risk tier: ${riskTier}`);
    }
    if (cwd && !path.isAbsolute(cwd)) {
        throw new Error("cwd must be an absolute path");
    }
    if (contracts) {
        if (!Array.isArray(contracts) || contracts.some(c => typeof c !== "string" || c.trim().length === 0)) {
            throw new Error("contracts must be an array of non-empty strings");
        }
    }
    if (hostVerifyCommands) {
        if (!Array.isArray(hostVerifyCommands) || hostVerifyCommands.some(c => typeof c !== "string" || c.trim().length === 0)) {
            throw new Error("hostVerifyCommands must be an array of non-empty strings");
        }
    }

    if (riskTier === "R2" || riskTier === "R3") {
        if (!contracts || contracts.length === 0) {
            throw new Error(`${riskTier} requires contracts`);
        }
    }
    if (riskTier === "R3") {
        if (!hostVerifyCommands || hostVerifyCommands.length === 0) {
            throw new Error("R3 requires host verification commands");
        }
    }

    let workflowScript = "";
    let requiresAuthorization = false;
    const assumptions: string[] = [];

    if (riskTier === "R0") {
        assumptions.push("R0: Read-only scout child");
        workflowScript = `
const task = ${JSON.stringify(task)};
return runs.run("scout", { agent: "scout", task });
`.trim();
    } else if (riskTier === "R1") {
        assumptions.push("R1: Checked worker child");
        workflowScript = `
const task = ${JSON.stringify(task)};
return runs.run("worker", { agent: "worker", task, acceptance: "checked" });
`.trim();
    } else if (riskTier === "R2") {
        assumptions.push("R2: Worker followed by fresh reviewer");
        workflowScript = `
const task = ${JSON.stringify(task)};
const contracts = ${JSON.stringify(contracts)};
const worker = await runs.run("worker", { agent: "worker", task, acceptance: "checked" });
const reviewTask = [
  "Review the following output and ensure it meets acceptance criteria.",
  "Contracts:",
  ...contracts,
  "",
  "Worker Output:",
  worker.output
].join("\\n");
return runs.run("reviewer", { agent: "reviewer", task: reviewTask, context: "fresh" });
`.trim();
    } else if (riskTier === "R3") {
        requiresAuthorization = true;
        assumptions.push("R3: Preflight oracle check only. Requires manual authorization for worker execution.");
        workflowScript = `
const task = ${JSON.stringify(task)};
const contracts = ${JSON.stringify(contracts)};
const verifyCmds = ${JSON.stringify(hostVerifyCommands)};
const oracleTask = [
  task,
  "",
  "Contracts:",
  ...contracts,
  "",
  "Host Verification:",
  ...verifyCmds
].join("\\n");
return runs.run("oracle", { agent: "oracle", task: oracleTask });
`.trim();
    }

    const output: CompileWorkflowOutput = {
        tier: riskTier,
        workflowScript,
        requiresAuthorization,
        assumptions,
    };
    
    if (cwd) {
        output.launchOptions = { cwd };
    }

    return output;
}

export default function compileWorkflowExtension(pi: ExtensionAPI): void {
    pi.registerTool({
        name: "compile_workflow",
        label: "Compile Workflow",
        description: "Compiles a standardized orchestration workflow for a specific risk tier (R0-R3). Returns a compiled workflowScript. It does not execute the workflow.",
        parameters: CompileWorkflowParams,
        execute: async (_id, params) => {
            try {
                const output = compileWorkflow(params as CompileWorkflowInput);
                return {
                    content: [{ type: "text", text: JSON.stringify(output, null, 2) }],
                    details: { output },
                };
            } catch (error: unknown) {
                const msg = error instanceof Error ? error.message : String(error);
                return {
                    content: [{ type: "text", text: `Error compiling workflow: ${msg}` }],
                    isError: true,
                };
            }
        },
    });
}
