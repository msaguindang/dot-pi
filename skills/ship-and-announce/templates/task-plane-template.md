# Task: ship Plane ticket updates — {{FIX_ID}}

Self-contained task for the PLANE worker of a ship-and-announce run.
Everything you need is in this file. Do not assume any prior conversation.

## Inputs

- Tickets to close: `{{TICKET_IDS}}` (sequence ids, e.g. PV1-5 → 5)
- Target state: `Done` (from whatever their current state is)
- Plane project: `{{PLANE_PROJECT}}`
- Fix branch: `{{FIX_BRANCH}}` (server version {{SERVER_VERSION}})
- Fix summary: {{FIX_SUMMARY}}
- Follow-up tickets to create: {{FOLLOWUPS}}
- Merge commit hash: read it from `/tmp/ship-source-{{FIX_ID}}-result.md`
  (`merge_commit:` line) if that file exists yet; otherwise reference the
  branch `{{FIX_BRANCH}}` and note the hash was not yet available.

## Secret Handling (mandatory)

All Plane API calls go through the plane-tasks skill scripts, wrapped in
infisical, from the plane-tasks directory (infisical is cwd-sensitive):

```bash
cd /home/codeweaver/.pi/agent/skills/plane-tasks
infisical run -- scripts/plane-projects.sh                     # resolve project id
infisical run -- scripts/plane-issues.sh --project <project_id>
infisical run -- scripts/plane-update.sh <issue_seq> <project_id> Done
infisical run -- scripts/plane-create.sh --project <project_id> --title "<title>"
```

Do NOT hand-roll curl calls to the Plane API and do NOT echo secrets.

## Boundary Caveat (check before transitioning states)

Plane may be one-way synced from fleet-gitops
(`/data/dev/work/ntv/fleet-gitops/docs/plane-integration.md`). If that sync
owns these tickets' states, manual transitions get overwritten: in that case
only add the deployment comment and create follow-ups, note
`states_owned_by_sync: yes` in your result details, and skip the transitions.

## Scope Fence

- **Mutate only**: the listed Plane tickets (state, one comment) and the
  listed follow-up ticket creations in project `{{PLANE_PROJECT}}`.
- **Do not touch** any git repo, Confluence, Obsidian, Teams, or tickets not
  listed above.
- **Write only one file**: your result file (below).

## Steps

1. Resolve the project id for `{{PLANE_PROJECT}}` via `plane-projects.sh`.
2. For each ticket in `{{TICKET_IDS}}`: record its current state
   (`plane-issues.sh`), then transition to `Done` via `plane-update.sh`
   (subject to the boundary caveat above).
3. Add a deployment comment to the primary (first-listed) ticket: fix summary,
   server version {{SERVER_VERSION}}, merge commit hash (or branch name),
   deploy date {{DEPLOY_DATE}}. If plane-tasks has no comment script, use the
   Plane MCP tools documented in the plane-tasks SKILL.md — still no raw curl.
4. Create each follow-up ticket via `plane-create.sh`. If a creation fails,
   report it in the result — do not retry blindly and do not leave a
   half-created ticket unreported.
5. Write the result file.

## Output artifact

Write `{{RESULT_FILE}}` in exactly this shape:

```
# ship-plane result: {{FIX_ID}}
status: success|partial|failed
tickets_updated: <comma-separated ids or none>
tickets_created: <comma-separated ids or none>
comment_added: yes|no

## Details
<per-ticket old state -> new state, API status, any rate-limit/auth issues>
```

## Acceptance Criteria

1. Every Plane API call went through plane-tasks scripts under
   `infisical run --` from the plane-tasks directory.
2. All API calls returned HTTP 2xx (the scripts exit non-zero otherwise);
   failures are recorded per ticket in the result details.
3. Each listed ticket's state transition is logged (old → new) in the result,
   or the sync-ownership caveat is recorded instead.
4. Deployment comment added to the primary ticket (or `comment_added: no`
   with a reason).
5. Follow-up tickets created with ids recorded; no orphaned/unreported
   creation attempts.
6. No ticket outside `{{TICKET_IDS}}` and the follow-up list was modified.
7. No secret values appear in the result file.
8. Result file exists at `{{RESULT_FILE}}` with a parseable `status:` line.
