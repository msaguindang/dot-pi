# Discord EOD Fetcher - Setup Guide

This guide walks you through setting up the Discord bot and configuring the skill.

---

## Step 1: Create a Discord Bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **New Application** and give it a name (e.g., "EOD Fetcher")
3. Go to the **Bot** tab on the left sidebar
4. Click **Reset Token** to generate a bot token
   - **Copy and save this token securely** (you will need it later)
5. Under the **Bot Permissions**, enable:
   - `Read Messages/View Channels`
6. Go to the **OAuth2** -> **URL Generator** tab
7. Under **Scopes**, select `bot`
8. Under **Bot Permissions**, select `Read Messages/View Channels`
9. Copy the generated URL, open it in your browser, and select your server to invite the bot

---

## Step 2: Enable Message Content Intent

1. In the Discord Developer Portal, go to your bot's page
2. Go to the **Bot** tab
3. Scroll down to the **Privileged Gateway Intents** section
4. Enable **Message Content Intent**
5. Click **Save Changes**

---

## Step 3: Get Your Channel ID

1. Open Discord and enable **Developer Mode**:
   - User Settings (gear icon) -> Advanced -> Developer Mode (turn ON)
2. Right-click on the channel where EOD updates are posted
3. Click **Copy Channel ID**
4. Save this ID (you will need it for the config)

---

## Step 4: Configure the Skill

1. Open `scripts/config.json` in the skill folder
2. Replace the placeholders with your actual values:

```json
{
  "channel_id": "YOUR_CHANNEL_ID_HERE",
  "vault_path": "~/Dropbox/Obsidian",
  "template_path": "z. System/Templates/Work Log.md",
  "display_name_overrides": {
    "your_discord_username": "Display Name"
  },
  "self_username": "your_discord_username",
  "output_folder": "2. Areas/01 Work/01 Operations/Work Logs",
  "author_header_pattern": "### {author}",
  "empty_placeholder_pattern": "-\\s*",
  "empty_placeholder_text": "- "
}
```

> Author capture is name-agnostic — anyone who posts in the channel is picked up automatically (no allowlist to maintain). `display_name_overrides` is optional cosmetic relabeling only. `self_username` routes your own posts to `## My Focus` instead of `## Team Updates`.

> **Note:** The Discord bot token is injected automatically via Infisical (`localhost:8080`). Do not add it to `config.json`.

---

## Step 5: Install Python Dependencies

If you don't have the `requests` library installed:

```bash
pip install -r scripts/requirements.txt
```

---

## Customizing the Obsidian Template

By default, the script looks for headers like `### Arjay` followed by an empty bullet `- ` to inject messages.

If your Obsidian template uses a different format, you can customize the injection logic in `config.json`:

- `author_header_pattern`: The format of the heading. `{author}` is replaced by the team member's name. (Default: `### {author}`)
- `empty_placeholder_pattern`: The regex pattern for the empty placeholder the script should replace. (Default: `-\\s*`)
- `empty_placeholder_text`: The literal text used for the placeholder when auto-creating new daily logs. (Default: `- `)

For example, if your template has no bullets and uses `## Name`:
```json
{
  "author_header_pattern": "## {author}",
  "empty_placeholder_pattern": ""
}
```

---

## Usage

To fetch updates from Discord and save them to your Obsidian vault:

```bash
bash scripts/run.sh --channel <CHANNEL_ID> --start 2026-03-23 --end 2026-03-27
```

---

## Troubleshooting

### 401 Unauthorized
- Your bot token is invalid. Regenerate it in the Discord Developer Portal.

### 403 Forbidden
- The bot does not have permission to read messages.
- Check the server roles and ensure the bot role has `Read Messages` permission.

### 404 Not Found
- The channel ID is incorrect. Double-check the ID.

### 429 Rate Limited
- Wait a few seconds before retrying. The script handles this automatically with exponential backoff.
