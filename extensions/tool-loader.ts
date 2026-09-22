import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const LOADER_NAME = "search_tools";
const DEFAULT_ACTIVE_TOOLS = [
    "read",
    "write",
    "edit",
    "bash",
    "safe_bash",
    "ctx_execute",
    "ctx_execute_file",
    "ctx_search",
    LOADER_NAME,
];
const MAX_MATCHES = 5;

// Delegation is opt-in: ordinary mentions of agents/reviews must not change the
// tool surface, while explicit routing requests must work without relying on a
// model-initiated search_tools call.
function requestsDelegation(prompt: string): boolean {
    const text = prompt.toLowerCase();
    return /\bindependent\s+(?:post-mutation\s+)?review\b/.test(text) ||
        /\bdispatch\s+(?:a\s+|an\s+|the\s+)?(?:fresh\s+)?(?:worker|reviewer|oracle)\b/.test(text) ||
        /\b(?:delegate|route|send)\s+(?:this|that|the\s+task|the\s+work)?\s*(?:to\s+)?(?:a\s+)?(?:worker|reviewer|oracle|subagent)\b/.test(text) ||
        /\buse\s+(?:the\s+)?subagent\b/.test(text);
}

type SkillEntry = { name: string; description: string; location: string };
let skillCatalog: SkillEntry[] = [];

function textField(xml: string, tag: string): string {
    return (xml.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, "i"))?.[1] ?? "")
        .replace(/<[^>]+>/g, "").trim();
}

function captureSkillCatalog(prompt: string): string {
    const catalog = prompt.match(/<available_skills\b[^>]*>[\s\S]*?<\/available_skills>/i)?.[0];
    if (!catalog) {
        skillCatalog = [];
        return prompt;
    }
    skillCatalog = [...catalog.matchAll(/<skill\b[^>]*>[\s\S]*?<\/skill>/gi)]
        .map((match) => match[0])
        .map((xml) => ({ name: textField(xml, "name"), description: textField(xml, "description"), location: textField(xml, "location") }))
        .filter((skill) => skill.name);
    return prompt.replace(catalog, catalog.replace(/<description\b[^>]*>[\s\S]*?<\/description>/gi, ""));
}

export default function (pi: ExtensionAPI): void {
    pi.on("before_agent_start", async (event) => {
        const systemPrompt = captureSkillCatalog(event.systemPrompt);
        if (requestsDelegation(event.systemPrompt)) {
            const available = new Set(pi.getAllTools().map((tool) => tool.name));
            if (available.has("subagent") && !pi.getActiveTools().includes("subagent")) {
                pi.setActiveTools([...pi.getActiveTools(), "subagent"]);
            }
        }
        return { systemPrompt };
    });
    pi.registerTool({
        name: LOADER_NAME,
        label: "Search Tools",
        description: "Search for and activate registered tools relevant to a task.",
        promptSnippet: "Search for additional tools when the active tools cannot perform the task",
        parameters: Type.Object({
            query: Type.String({ description: "Capability or task to search for" }),
        }),
        async execute(_toolCallId, params) {
            const terms = params.query.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
            const active = pi.getActiveTools();
            const candidates = pi.getAllTools()
                .filter((tool) => tool.name !== LOADER_NAME && !active.includes(tool.name))
                .map((tool) => {
                    const aliases = tool.name === "subagent" ? " delegate delegation" : "";
                    const fields = [tool.name, tool.description, aliases].filter(Boolean).join(" ").toLowerCase();
                    const score = terms.reduce((total, term) => total + (fields.includes(term) ? 1 : 0), 0);
                    return { kind: "tool" as const, tool, score };
                });
            const skillCandidates = skillCatalog.map((skill) => {
                const fields = [skill.name, skill.description, skill.location].join(" ").toLowerCase();
                const score = terms.reduce((total, term) => total + (fields.includes(term) ? 1 : 0), 0);
                return { kind: "skill" as const, skill, score };
            });
            const candidatesWithMatches = [...candidates, ...skillCandidates].filter(({ score }) => score > 0);
            const highestScore = Math.max(0, ...candidatesWithMatches.map(({ score }) => score));
            const best = candidatesWithMatches
                .filter(({ score }) => score === highestScore)
                .sort((a, b) => (a.kind === "tool" ? a.tool.name : a.skill.name).localeCompare(b.kind === "tool" ? b.tool.name : b.skill.name))
                .slice(0, MAX_MATCHES);
            const matches = best.map((candidate) => candidate.kind === "tool" ? candidate.tool.name : candidate.skill.name);
            const skillMatches = best.filter((candidate): candidate is typeof skillCandidates[number] => candidate.kind === "skill").map(({ skill }) => skill);
            const added = best.filter((candidate): candidate is typeof candidates[number] => candidate.kind === "tool")
                .map(({ tool }) => tool.name).filter((name) => !active.includes(name));
            if (added.length > 0) pi.setActiveTools([...new Set([...active, ...added])]);

            const sections: string[] = [];
            if (added.length > 0) sections.push(`Loaded tools: ${added.join(", ")}`);
            if (skillMatches.length > 0) {
                sections.push(`Matching skills: ${skillMatches.map((skill) => `${skill.name} — ${skill.description} (${skill.location})`).join("; ")}`);
            }
            if (sections.length === 0) {
                sections.push(matches.length > 0
                    ? `Matching tools already active: ${matches.join(", ")}`
                    : `No tools found for: ${params.query}`);
            }
            const text = sections.join("; ");
            return {
                content: [{ type: "text", text }],
                details: { matches, added, skills: skillMatches },
            };
        },
    });

    pi.on("session_start", () => {
        const available = new Set(pi.getAllTools().map((tool) => tool.name));
        pi.setActiveTools(DEFAULT_ACTIVE_TOOLS.filter((name) => available.has(name)));
    });
}
