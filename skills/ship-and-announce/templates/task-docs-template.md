# Task: ship docs update — {{FIX_ID}}

Self-contained task for the DOCS worker of a ship-and-announce run.
Everything you need is in this file. Do not assume any prior conversation.

## Inputs

- Server version: `{{SERVER_VERSION}}`
- UI version: `{{UI_VERSION}}`
- Fix summary: {{FIX_SUMMARY}}
- Deploy date: `{{DEPLOY_DATE}}`
- fleet-gitops repo: `{{FLEET_GITOPS_DIR}}`
- Obsidian target dir: `{{OBSIDIAN_DIR}}`
- Confluence: space `{{CONFLUENCE_SPACE}}`, parent page id `{{CONFLUENCE_PARENT_ID}}`
  (existing page id to update: `{{CONFLUENCE_PAGE_ID}}` — if `none`, create a new page)

## Knowledge-Store Boundary (binding)

Per `/home/codeweaver/.agents/standards/knowledge-store-boundary.md`:
- **Git (fleet-gitops)** owns deployment truth: the release record.
- **Obsidian** owns durable rationale: why, root cause, decisions. **No live
  status snapshots** — add a "Where to Find Current State" pointer linking to
  the `release.yaml` instead.
- **Confluence** is derived release notes for stakeholders, not a source of
  truth.
- Never state the same fact in two stores; link to its home.

## Scope Fence

- **Mutate only**: the fleet-gitops repo (new release record files + commit,
  NO push unless the repo's convention says otherwise — record what you did),
  one new Obsidian note under the target dir, and the one Confluence page.
- **Do not touch** player-server/player-ui repos, Plane, or Teams. Other
  workers own those.
- **Write only one file outside those stores**: your result file (below).

## Steps

1. **fleet-gitops release record** in `{{FLEET_GITOPS_DIR}}`: create the
   release directory for server {{SERVER_VERSION}} following the existing
   releases' layout, containing:
   - `release.yaml` — versions, deploy date `{{DEPLOY_DATE}}`, fix summary,
     commit references. Must be valid YAML (check with a YAML parser or
     `python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))"`).
   - `rollback.md` — concrete rollback command/steps.
   - `verification.md` — how the fix was verified on the QA device.
   Commit with a conventional message. Record the commit hash.
2. **Obsidian rationale note**: create
   `{{OBSIDIAN_DIR}}/{{DEPLOY_DATE}} - Release Notes - player-server {{SERVER_VERSION}}.md`
   with YAML frontmatter including `date: {{DEPLOY_DATE}}`. Content: rationale,
   root cause, decisions — plus a pointer section linking to the fleet-gitops
   `release.yaml`. No status snapshots.
3. **Confluence release notes** via the confluence-publisher skill — do NOT
   hand-roll Confluence API calls:
   - Draft the release-notes markdown to `/tmp/ship-docs-{{FIX_ID}}-confluence.md`
     (what shipped, how to update, rollback plan).
   - If `{{CONFLUENCE_PAGE_ID}}` is not `none`, update:
     `~/.pi/agent/skills/confluence-publisher/scripts/publish.sh --title "<title>" --file /tmp/ship-docs-{{FIX_ID}}-confluence.md --page-id {{CONFLUENCE_PAGE_ID}}`
   - Otherwise create under the parent:
     `~/.pi/agent/skills/confluence-publisher/scripts/publish.sh --title "Release Notes - player-server {{SERVER_VERSION}}" --file /tmp/ship-docs-{{FIX_ID}}-confluence.md --space {{CONFLUENCE_SPACE}} --parent-id {{CONFLUENCE_PARENT_ID}}`
   - The parent page id `{{CONFLUENCE_PARENT_ID}}` was supplied by the
     orchestrator; if the API rejects it, report `status: partial` — do not
     guess a different parent.
4. Write the result file.

## Output artifact

Write `{{RESULT_FILE}}` in exactly this shape:

```
# ship-docs result: {{FIX_ID}}
status: success|partial|failed
fleet_gitops_commit: <hash or none>
release_record: <absolute dir path>
obsidian_path: <absolute file path>
confluence_url: <url or none>
confluence_edit: created|updated|failed

## Details
<what happened, any warnings>
```

## Acceptance Criteria

1. Release directory exists in fleet-gitops with `release.yaml`, `rollback.md`,
   `verification.md`.
2. `release.yaml` parses as valid YAML.
3. fleet-gitops commit created; hash recorded in the result file.
4. Obsidian note exists at the path recorded, with frontmatter containing
   `date: {{DEPLOY_DATE}}`.
5. Obsidian note contains rationale and a pointer to `release.yaml`; contains
   no live status snapshot.
6. Confluence page created or updated via confluence-publisher; URL recorded.
7. Confluence page renders without broken markup (publish.sh exited 0).
8. No file written outside fleet-gitops, the Obsidian dir, `/tmp/ship-docs-{{FIX_ID}}-*`,
   and the result file.
9. Result file exists at `{{RESULT_FILE}}` with a parseable `status:` line.
