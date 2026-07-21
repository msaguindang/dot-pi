# Task: draft Teams announcement — {{FIX_ID}}

Self-contained task for the ANNOUNCEMENT worker of a ship-and-announce run.
Everything you need is in this file. Do not assume any prior conversation.

## HARD RULE

**This is a DRAFT for a human to post. Do NOT send it.** No Teams/Graph API
calls, no webhooks, no email bridges, no MCP messaging tools. Your only output
is the result file.

## Inputs

- Server version: `{{SERVER_VERSION}}`
- UI version: `{{UI_VERSION}}`
- Fix summary: {{FIX_SUMMARY}}
- Deploy date: `{{DEPLOY_DATE}}`
- BUILD_ID: `{{BUILD_ID}}`
- Deploy command template (fleet pattern): device receives a socket signal,
  then `wget` from `s3://ncompasstv-prod-player-apps/secure-rc/<BUILD_ID>/`
  (absolute URL) and runs the update script via `bash`.
- Rollback plan: `{{ROLLBACK_PLAN}}`
- Merge commit hash: read from `/tmp/ship-source-{{FIX_ID}}-result.md`
  (`merge_commit:` line) if it exists yet; otherwise write `<pending merge>`.

## Format

Follow the internal-comms skill for tone and structure — read
`/home/codeweaver/.pi/agent/skills/internal-comms/SKILL.md` and its
`examples/general-comms.md` before drafting. Two-audience format:

1. **Exec summary** (1–2 short paragraphs, plain language): what was broken,
   what is fixed, user/customer impact, when it rolled out. No jargon, no
   hashes.
2. **Technical detail**: versions, merge commit hash, BUILD_ID, deploy command
   (absolute URL), verification steps performed on the QA device, rollback
   command.

## Scope Fence

- **Write only one file**: your result file (below). No external calls of any
  kind — this is a pure text-generation task.
- **Do not touch** git repos, Plane, Confluence, Obsidian.

## Output artifact

Write `{{RESULT_FILE}}` in exactly this shape:

```
# ship-announce result: {{FIX_ID}}
status: success|partial|failed
posted: no

## Teams Draft
<the full Teams-ready markdown message, copy-paste ready>

## Details
<any caveats, e.g. merge hash pending>
```

`posted:` is ALWAYS `no` — a human posts the message.

## Acceptance Criteria

1. Result file contains a `## Teams Draft` section with the complete message.
2. Message has two clearly separated sections: exec summary, then technical
   detail.
3. Exec summary is plain language, 1–2 paragraphs, no commit hashes or
   commands.
4. Technical detail includes versions, commit hash (or `<pending merge>`),
   BUILD_ID `{{BUILD_ID}}`, deploy command with absolute URL, and the
   rollback command.
5. Markdown is valid for Teams: no unclosed code fences, no broken links.
6. `posted: no` appears in the header; no send/post attempt was made.
7. No external API call, webhook, or messaging tool was invoked.
8. Result file exists at `{{RESULT_FILE}}` with a parseable `status:` line.
