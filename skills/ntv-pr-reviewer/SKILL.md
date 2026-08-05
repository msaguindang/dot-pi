---
name: ntv-pr-reviewer
description: Parallel 6-agent PR review for NTV repositories (requires commit hash or branch name).
allowed-tools: [bash, read, subagent]
disable-model-invocation: true
---

# ntv-pr-reviewer Skill

This skill automates a 2-round, 6-agent parallel review process to validate PRs against NTV engineering standards.

## Usage
`/skill:ntv-pr-reviewer <commit-hash-or-branch>`

## Workflow
1. **Scout Step**: Run `~/.pi/agent/skills/ntv-pr-reviewer/scripts/extract-diff.sh <input>` to generate the diff.
2. **Context Step**: Read `~/.agents/standards/code-style.md` to get the `{{STANDARDS}}`.
3. **Parallel Round 1**: Dispatch 3 `reviewer` agents in parallel, providing diff and standards.
4. **Parallel Round 2**: Dispatch 3 `reviewer` agents in parallel, providing diff and standards.
5. **Consolidation**: Dispatch 1 `worker` agent to consolidate all 6 outputs into a single report using `~/.pi/agent/skills/ntv-pr-reviewer/prompts/consolidate.md`.

## Report Format
The Consolidation step produces the final report, gated by a Verdict (Verified / Needs Fix) per `prompts/consolidate.md`.

On a **Verified** verdict, the report's literal last line must always be:

> Merging is a human action performed via the GitHub UI. This agent never merges or approves a PR — review ends at the report.

## Implementation Details
- Ensure all 3 Round 1 agents are finished before dispatching Round 2.
- Ensure all Round 2 agents are finished before dispatching the worker.
- If diff extraction fails, abort immediately.
- When instructing the consolidation worker (step 5), include the mandatory closing line from **Report Format** above.
