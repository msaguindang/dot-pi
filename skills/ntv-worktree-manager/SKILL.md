---
name: ntv-worktree-manager
description: Orchestrate synchronized NTV worktrees across api-v1, dashboard-v1, player-server, and player-ui.
---

# NTV worktree manager

Read `APPEND_SYSTEM.md` for route selection and `~/.agents/standards/orchestration-policy.md`
for shared safeguards. This skill owns only NTV worktree setup; it does not choose the risk
tier or duplicate delegation/review rules.

Use this skill before starting an NTV ticket, feature, or bug (the narrow REV path is exempt).
Ask for ticket ID, description, type (`feat`, `fix`, `hotfix`, `test`), and selected repos.
Construct `[type]/[ID]-[description]`, verify `NTV_DIR`, fetch origin, and invoke
`scripts/manage_worktrees.sh`. Never overwrite an existing worktree without explicit
confirmation. State baseline, branch, order, conflict points, and push/merge boundary before
creating an integration worktree.

Worktrees are created under `$NTV_DIR/<repo>/.worktrees/<branch>`. Verify every path and
report created directories and next steps. Deployment/device safeguards remain in the Pi
adapter and the shared policy, not here.
