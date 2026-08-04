/**
 * Safe Bash Tool Extension
 *
 * Registers the `safe_bash` tool required by tool-policy.md for Git, npm, apt,
 * chezmoi, and output-heavy commands. Reuses Pi's built-in bash implementation
 * via createBashTool to preserve shell spawning, truncation, timeout,
 * cancellation, and process cleanup behavior.
 *
 * The existing guardrails.ts extension applies command-gating rules to both
 * `bash` and `safe_bash`.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashTool } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
    const cwd = process.cwd();

    // Reuse Pi's built-in bash tool implementation
    const safeBashTool = createBashTool(cwd);

    // Register under the exact name `safe_bash` with descriptive metadata
    pi.registerTool({
        ...safeBashTool,
        name: "safe_bash",
        label: "Safe Bash",
        description:
            "Execute bash commands with guardrails. MUST be used for infrastructure changes (chezmoi, npm, apt, git) and any command expected to produce large output (>50KB or complex formatting). Direct invocation of high-risk commands is strictly prohibited by this wrapper.",
        execute: async (id, params, signal, onUpdate, _ctx) => {
            return safeBashTool.execute(id, params, signal, onUpdate);
        },
    });
}
