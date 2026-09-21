---
name: discord-eod-fetcher
description: Fetches End-of-Day (EOD) updates from the NTV360 Discord forum channel and injects them into Obsidian daily work logs. Runs automatically via systemd timer (9am, 2pm, 6pm). Handles late posts via 48h lookback, missing threads, and template-aware section parsing. Author name is pulled live from Discord (nickname/global name) — no manual username mapping. Use this skill to manually trigger a fetch or check fetch status.
---

# Discord EOD Fetcher

Automatically fetches NTV360 team EOD updates from Discord and injects them into Obsidian work logs. Runs 3x daily via systemd timer on foundry.

## Automated Schedule
- **9:00 AM** — morning catchup (catches yesterday's late posts)
- **2:00 PM** — midday (captures anyone who posted during the day)
- **6:00 PM** — end of day (final collection)

Check timer status:
```bash
systemctl --user status discord-eod.timer
journalctl --user -u discord-eod.service --since today
```

## Manual Trigger

To run manually for the last 2 days:
```bash
bash ~/.pi/agent/skills/discord-eod-fetcher/scripts/run.sh
```

To run for a custom lookback:
```bash
cd ~/.pi/agent/skills/discord-eod-fetcher/scripts
eval "$(infisical export --domain http://localhost:8080 --format=dotenv-export 2>/dev/null)"
python3 fetch_discord.py --channel <CHANNEL_ID> --lookback-days 5
```

## What it handles
- **Late posts** — 48h lookback catches posts made the next day
- **Missing threads** — logs explicitly, writes a note in the work log
- **Author names** — pulled live from Discord (guild nickname → global name → username). No allowlist to maintain — anyone who posts in the channel shows up, since the channel is already team-only.
- **Template posts** — parses `Completed:`, `Tomorrow:`, `Blockers:` sections (bold or plain) into Obsidian subsections
- **Re-runs** — idempotent, deduplicates before injecting

## Configuration
- `scripts/config.json` — channel ID, vault path, template sections
- `scripts/state.json` — auto-generated, tracks last run + processed message IDs (gitignored)

## Setup (first time)
1. Ensure infisical is running: `curl -s http://localhost:8080/api/status`
2. Verify bot token is in infisical secrets
3. Enable timer: `systemctl --user enable --now discord-eod.timer`
4. Test: `systemctl --user start discord-eod.service && journalctl --user -u discord-eod.service -f`
