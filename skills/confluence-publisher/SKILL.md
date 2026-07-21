---
name: confluence-publisher
description: Publish a local markdown file as a new Confluence page under a specified space and parent. Use when asked to publish documentation, notes, or reports to Confluence.
---

# confluence-publisher

Converts a local markdown file to HTML and creates a new page in Confluence via the REST API v1.

## Environment Variables

| Variable | Description |
|---|---|
| `CONFLUENCE_DOMAIN` | Base URL, e.g. `https://n-compass.atlassian.net` |
| `CONFLUENCE_EMAIL` | Atlassian account email used for Basic Auth |
| `CONFLUENCE_API_TOKEN` | Atlassian API token (generate at id.atlassian.com) |

All three are stored in Infisical at path `/` and auto-loaded by the script.

## Setup

1. Ensure `curl`, `jq`, and `node` are installed.
2. Ensure `infisical` is authenticated (`infisical login` or `INFISICAL_TOKEN` in env).
3. Install skill npm dependencies once: `cd ~/.pi/agent/skills/confluence-publisher && npm install`
4. The script auto-exports secrets from Infisical before running; no manual sourcing needed.

## Usage

```bash
~/.pi/agent/skills/confluence-publisher/scripts/publish.sh \
  --title "My Page Title" \
  --file /path/to/file.md \
  [--space NCTV] \
  [--parent-id 2588673] \
  [--page-id <existing-page-id>]
```

### Arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--title` | Yes | — | Title of the Confluence page |
| `--file` | Yes | — | Path to the markdown file to publish |
| `--space` | No | `NCTV` | Confluence space key |
| `--parent-id` | No | `2588673` | ID of the parent page (Raspberry Pi Player) |
| `--page-id` | No | — | ID of an existing page to **update** (PUT). Omit to **create** (POST). |

### Example — Create a new page

```bash
~/.pi/agent/skills/confluence-publisher/scripts/publish.sh \
  --title "Player Server Release Notes v2.9.45" \
  --file /tmp/release-notes.md
```

On success the script prints the URL of the newly created page.

### Example — Update an existing page

```bash
~/.pi/agent/skills/confluence-publisher/scripts/publish.sh \
  --title "Release Notes - player-server 2.10.0 + player-ui 3.0.50" \
  --file /tmp/release-notes.md \
  --page-id 1557823491
```

On success the script prints the URL and the new version number.

## Notes

- Markdown is converted to HTML via `scripts/md-to-html.js`, which uses `gray-matter` to strip YAML frontmatter and `marked` + `marked-gfm-heading-id` for consistent GFM anchor IDs.
- HTML is escaped for JSON using `jq` — no manual escaping required.
- Secrets are never printed; only the final page URL is output on success.
- Errors from `curl` or Confluence API are printed to stderr and the script exits non-zero.
- When creating (no `--page-id`): if a page with the same title already exists under the same parent, Confluence will return a 400 error. Rename the page or archive the existing one first.
- When updating (`--page-id` supplied): the script fetches the current version, increments it, and issues a PUT. Space key and parent ancestor are inferred from the existing page.
