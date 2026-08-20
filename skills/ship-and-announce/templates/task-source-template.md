# Task: ship source fix — {{FIX_ID}}

Self-contained task for the SOURCE FIX worker of a ship-and-announce run.
Everything you need is in this file. Do not assume any prior conversation.

## Inputs

- Fix branch: `{{FIX_BRANCH}}`
- Merge target: `next`
- Version bump target: `{{SERVER_VERSION}}`
- Repository: `{{REPO_DIR}}` (player-server)
- Remotes: `origin` (GitHub) and `forgejo` — both must receive the push

## Scope Fence

- **Mutate only** the repository at `{{REPO_DIR}}`: the merge commit on
  `next` and the `version` field of `package.json` (plus its lockfile
  counterpart if the repo convention requires it).
- **Do not touch** player-ui, fleet-gitops, any file unrelated to the merge,
  Plane, Confluence, Obsidian, or Teams. Other workers own those.
- **Write only one file outside the repo**: your result file (below).

## Steps

1. `cd {{REPO_DIR}}` and confirm a clean working tree (`git status --porcelain`
   empty). If dirty, stop and report `status: failed` with the reason.
2. `git fetch origin && git fetch forgejo`.
3. Confirm `{{FIX_BRANCH}}` exists: `git ls-remote origin {{FIX_BRANCH}}`.
4. `git checkout next && git pull origin next`.
5. `git merge --no-ff {{FIX_BRANCH}}` (conventional merge message referencing
   the fix branch). On conflict: abort the merge, report `status: failed`.
6. Set `"version": "{{SERVER_VERSION}}"` in `package.json`; commit as
   `chore: bump version to {{SERVER_VERSION}}` (or fold into the merge commit
   if the repo convention prefers).
7. Push `next` to **both** remotes: `git push origin next && git push forgejo next`.
8. **Branch cleanup (mandatory, do not skip):** confirm `{{FIX_BRANCH}}` is now an
   ancestor of `next` (`git merge-base --is-ancestor {{FIX_BRANCH}} next`), then
   delete it everywhere: `git branch -D {{FIX_BRANCH}}` locally, and
   `git push origin --delete {{FIX_BRANCH}} && git push forgejo --delete {{FIX_BRANCH}}`
   on both remotes. This step was historically skipped, leaving merged branches
   accumulating indefinitely — do not treat it as optional.
9. Write the result file.

## Output artifact

Write `{{RESULT_FILE}}` in exactly this shape:

```
# ship-source result: {{FIX_ID}}
status: success|partial|failed
merge_commit: <hash>
version: {{SERVER_VERSION}}
pushed_origin: yes|no
pushed_forgejo: yes|no
fix_branch_deleted: yes|no

## Details
<what happened, any warnings>
```

## Acceptance Criteria

1. Merge commit for `{{FIX_BRANCH}}` present on `next` (`git log --merges -1`).
2. Merge used `--no-ff` (commit has two parents).
3. `package.json` `version` field equals `{{SERVER_VERSION}}`.
4. `git ls-remote origin next` matches local `next` HEAD.
5. `git ls-remote forgejo next` matches local `next` HEAD.
6. No files outside the merge diff + `package.json` (+ lockfile) were modified.
7. Working tree clean at the end (`git status --porcelain` empty).
8. `{{FIX_BRANCH}}` no longer exists locally or on either remote
   (`git branch --list {{FIX_BRANCH}}`, `git ls-remote origin {{FIX_BRANCH}}`,
   `git ls-remote forgejo {{FIX_BRANCH}}` all empty).
9. Result file exists at `{{RESULT_FILE}}` with a parseable `status:` line.
