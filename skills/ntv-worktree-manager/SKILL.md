---
name: ntv-worktree-manager
description: Orchestrate git worktree creation, synchronization, and setup across the NTV ecosystem (api-v1, dashboard-v1, player-server, player-ui). Use whenever the user starts work on a new ticket, story, or bug.
---

# NTV Worktree Manager

A skill for managing synchronized git worktrees across the four core NTV repositories. Worktrees are created **inside** each repo at `<repo>/.worktrees/<branch>` — git-native and automatically gitignored.

## When to use this skill
- Starting a new ticket (`feat`, `fix`, `hotfix`, `test`). (Do NOT use for `REV` fast path; any ticket disqualifies REV, refer to orchestration-policy).
- Setting up a new worktree for a specific task.
- Ensuring repositories are fetched and initialized after creating a worktree.

---

## Workflow: Create/Sync Worktrees for a Ticket

This workflow uses `NTV_DIR` from the environment (must be exported — the script exits with an error if unset).

1.  **Ask for Details**: Prompt the user for:
    - **Ticket ID** (e.g., `456`)
    - **Description** (e.g., `fix-auth-bug`)
    - **Type** (e.g., `feat`, `fix`, `hotfix`)
    - **Selected Repos** (Which of `api`, `dash`, `server`, `ui` need the worktree?)
2.  **Construct Branch Name**: Formulate the standard branch: `[type]/[ID]-[Description]` (e.g., `fix/456-fix-auth-bug`).
3.  **Execute**: Invoke `scripts/manage_worktrees.sh` with the ticket details.
4.  **Report**: Summarize the created directories and next steps.

### Resulting structure

```
$NTV_DIR/
├── api-v1/
│   └── .worktrees/
│       └── fix/456-fix-auth-bug/      ← worktree
├── dashboard-v1/
│   └── .worktrees/
│       └── fix/456-fix-auth-bug/
├── player-server/
│   └── .worktrees/
│       └── fix/456-fix-auth-bug/
└── player-ui/
    └── .worktrees/
        └── fix/456-fix-auth-bug/
```

`.worktrees/` is gitignored by default (git adds it to `.git/info/exclude` automatically for worktrees).

---

## Safety Guidelines
- **NEVER** overwrite an existing worktree directory without explicit user confirmation.
- **ALWAYS** perform a `git fetch origin` before creating a new worktree to ensure the base branch is up-to-date.
- **VERIFY** `NTV_DIR` is set and all paths resolve before executing.
- **USE** the provided `manage_worktrees.sh` script to maintain consistency.
- **STATE THE PLAN FIRST** — before creating an integration worktree/branch, or cherry-picking/merging any approved commits into it, state the concrete plan unprompted: baseline commit, branch name, cherry-pick/merge order, known conflict points, and the push/merge boundary (what gets pushed/merged and when). Get explicit approval before executing. This is a default step, not something to wait to be asked for.

## Bundled Resources
- `scripts/manage_worktrees.sh` — executes all git operations
