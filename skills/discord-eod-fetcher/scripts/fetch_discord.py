#!/usr/bin/env python3
"""
Discord EOD Fetcher — redesigned for automated 3x-daily runs.

Changes from v1:
  - state.json caches guild_id, thread IDs, last processed message IDs
  - Only fetches threads from last N days (snowflake cutoff), not all history
  - Incremental message fetch — only new messages since last run
  - 48h lookback: checks today + yesterday on every run
  - Fuzzy thread name matching (6 format candidates)
  - Template-aware section parsing (**Done:**, **Tomorrow:**, **Blockers:**)
  - Removed EOD keyword filter (silently dropped template posts)
  - Unknown usernames logged as warnings, not silently dropped
  - Per-run completeness report (who posted vs missing) appended to work log
  - Missing thread logged explicitly + note written to work log
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

import requests

from state import (
    load_state, save_state,
    get_cached_thread, cache_thread,
    get_last_message_id, update_last_message_id,
    set_guild_id, mark_run,
)

DISCORD_EPOCH = 1420070400000
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.path.join(SCRIPT_DIR, "state.json")
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.json")


# ── Discord snowflake helpers ─────────────────────────────────────────────────

def snowflake_from_datetime(dt: datetime) -> int:
    """Minimum Discord snowflake ID for a given datetime."""
    ms = int(dt.timestamp() * 1000) - DISCORD_EPOCH
    return ms << 22


# ── API helpers ───────────────────────────────────────────────────────────────

def api_get(token: str, url: str, params: dict | None = None, timeout: int = 15) -> Optional[dict]:
    """GET with rate-limit retry. Returns parsed JSON or None on error."""
    headers = {"Authorization": f"Bot {token}"}
    while True:
        try:
            res = requests.get(url, headers=headers, params=params, timeout=timeout)
        except requests.exceptions.RequestException as e:
            print(f"[ERROR] Request failed: {url} — {e}", file=sys.stderr)
            return None
        if res.status_code == 429:
            retry_after = res.json().get("retry_after", 5)
            print(f"[WARN] Rate limited — sleeping {retry_after}s", file=sys.stderr)
            time.sleep(float(retry_after))
            continue
        if res.status_code == 200:
            return res.json()
        print(f"[ERROR] HTTP {res.status_code} for {url}", file=sys.stderr)
        return None


# ── Guild ID ──────────────────────────────────────────────────────────────────

def fetch_guild_id(token: str, channel_id: str) -> Optional[str]:
    data = api_get(token, f"https://discord.com/api/v10/channels/{channel_id}")
    return data.get("guild_id") if data else None


# ── Thread fetching ───────────────────────────────────────────────────────────

def get_recent_threads(token: str, guild_id: str, forum_id: str,
                       lookback_days: int = 2) -> list[dict]:
    """
    Fetch only threads from the last N days using snowflake cutoff.
    Stops paginating archived threads once threads are older than the cutoff.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback_days)
    min_snowflake = str(snowflake_from_datetime(cutoff))
    base = "https://discord.com/api/v10"
    threads: list[dict] = []

    # Active threads — always fetch (may be recent)
    data = api_get(token, f"{base}/guilds/{guild_id}/threads/active")
    if data:
        threads.extend([
            t for t in data.get("threads", [])
            if str(t.get("parent_id")) == str(forum_id)
        ])

    # Archived threads — stop when we pass the cutoff
    params: dict = {"limit": 100}
    while True:
        data = api_get(token, f"{base}/channels/{forum_id}/threads/archived/public",
                       params=params)
        if not data:
            break
        batch = data.get("threads", [])
        recent = [t for t in batch if t["id"] >= min_snowflake]
        threads.extend(recent)
        if len(recent) < len(batch) or not data.get("has_more", False) or not batch:
            break  # hit cutoff or no more pages
        params["before"] = batch[-1]["thread_metadata"]["archive_timestamp"]

    return threads


# ── Thread name matching ──────────────────────────────────────────────────────

def find_thread_for_date(threads: list[dict], target_date: datetime) -> Optional[str]:
    """
    Fuzzy match — tries 6 date format candidates, case-insensitive substring match.
    """
    candidates = [
        target_date.strftime("%-d %B %Y").lower(),   # "7 May 2026"
        target_date.strftime("%d %B %Y").lower(),    # "07 May 2026"
        target_date.strftime("%B %-d, %Y").lower(),  # "May 7, 2026"
        target_date.strftime("%B %d, %Y").lower(),   # "May 07, 2026"
        target_date.strftime("%Y-%m-%d").lower(),    # "2026-05-07"
        target_date.strftime("%-m/%-d/%Y").lower(),  # "5/7/2026"
    ]
    for t in threads:
        name = t.get("name", "").lower()
        if any(c in name for c in candidates):
            return t.get("id")
    return None


# ── Message fetching ──────────────────────────────────────────────────────────

def fetch_messages(token: str, thread_id: str,
                   after_id: Optional[str] = None) -> tuple[list[dict], Optional[str]]:
    """
    Fetch messages from a thread. If after_id is set, only fetches newer messages.
    Returns (messages sorted ascending, newest_message_id).
    """
    base_url = f"https://discord.com/api/v10/channels/{thread_id}/messages"
    params: dict = {"limit": 100}
    if after_id:
        params["after"] = after_id

    messages: list[dict] = []

    while True:
        data = api_get(token, base_url, params=params)
        if not data or not isinstance(data, list):
            break
        if not data:
            break
        for msg in data:
            if msg.get("author", {}).get("bot"):
                continue
            messages.append({
                "id":        msg["id"],
                "author":    msg["author"]["username"],
                "content":   msg["content"],
                "timestamp": msg["timestamp"],
            })
        if len(data) < 100:
            break
        # Paginate: when using 'after', Discord returns in ascending order
        # so next page is after the last message
        if after_id:
            params["after"] = data[-1]["id"]
        else:
            params["before"] = data[-1]["id"]

    messages.sort(key=lambda x: x["timestamp"])
    newest_id = messages[-1]["id"] if messages else None
    return messages, newest_id


# ── Template-aware parsing ────────────────────────────────────────────────────

def parse_template_sections(content: str, section_map: dict) -> dict[str, str]:
    """
    Extract named sections from a template-formatted Discord post.
    section_map: {"**Done:**": "Done", "**Tomorrow:**": "Tomorrow", ...}
    Returns: {"Done": "content...", "Tomorrow": "content...", ...}
    """
    result: dict[str, str] = {}
    current_key: Optional[str] = None
    current_lines: list[str] = []

    for line in content.split("\n"):
        stripped = line.strip()
        matched = next((k for k in section_map if stripped.startswith(k)), None)
        if matched:
            if current_key is not None:
                text = "\n".join(current_lines).strip()
                if text:
                    result[section_map[current_key]] = text
            current_key = matched
            # Inline content after the header (e.g. "**Done:** item")
            inline = stripped[len(matched):].strip()
            current_lines = [inline] if inline else []
        elif current_key is not None:
            current_lines.append(line)

    if current_key is not None:
        text = "\n".join(current_lines).strip()
        if text:
            result[section_map[current_key]] = text

    return result


def normalise_bullets(raw: str) -> str:
    """Normalise bullet points from Discord formatting to Obsidian markdown."""
    lines = []
    for line in raw.split("\n"):
        line = line.rstrip()
        if not line:
            continue
        leading = len(line) - len(line.lstrip(" "))
        tabs = "\t" * (leading // 2)
        line = line.lstrip()
        if re.match(r"^\*\*[^*]+\*\*:?\s*$", line):
            pass  # bold header — preserve
        elif line.startswith("* ") or line == "*":
            line = "- " + line[1:].lstrip()
        elif line.startswith("-") and not line.startswith("- "):
            line = "- " + line[1:].lstrip()
        elif not line.startswith("-"):
            line = "- " + line
        lines.append(tabs + line)
    return "\n".join(lines)


# ── Obsidian injection ────────────────────────────────────────────────────────

def create_from_template(date_obj: datetime, config: dict) -> str:
    vault = os.path.expanduser(config.get("vault_path", "~/Dropbox/Obsidian"))
    tmpl = os.path.join(vault, config.get("template_path", "z. System/Templates/Work Log.md"))
    with open(tmpl, "r", encoding="utf-8") as f:
        content = f.read()
    mwf = (
        "## MWF Realignment Meeting\n- [ ] Meeting occurred\n- **Discussed**:\n- **Action Items**:\n\n"
        if date_obj.weekday() in (0, 2, 4) else ""
    )
    content = content.replace("{{created}}", date_obj.strftime("%Y-%m-%dT09:00"))
    content = content.replace("{{updated}}", date_obj.strftime("%Y-%m-%dT09:00"))
    content = content.replace("{{date:MMM DD, YYYY}}", date_obj.strftime("%b %d, %Y"))
    content = content.replace("{{mwf_meeting}}", mwf)
    return content


def inject_into_team_updates(content: str, header: str, new_text: str,
                              empty_pattern: str) -> str:
    """Inject new_text under an author header inside ## Team Updates, deduplicating."""
    team_marker = "## Team Updates"
    team_start = content.find(f"\n{team_marker}")
    if team_start != -1:
        team_start += 1
    else:
        team_start = content.find(team_marker)

    if team_start == -1:
        pre, block, post = content, f"\n{team_marker}\n\n", ""
    else:
        after = team_start + len(team_marker)
        nxt = re.search(r"\n## ", content[after:])
        if nxt:
            split = after + nxt.start()
            pre, block, post = content[:team_start], content[team_start:split], content[split:]
        else:
            pre, block, post = content[:team_start], content[team_start:], ""

    section_pat = rf"({re.escape(header)}\n.*?)(?=\n#+|\Z)"
    match = re.search(section_pat, block, flags=re.DOTALL)

    if match:
        existing = match.group(1)
        if new_text.strip() in existing:
            return content  # already injected
        placeholder_pat = rf"^{re.escape(empty_pattern)}(?:\n|\Z)"
        if re.search(placeholder_pat, existing, flags=re.MULTILINE):
            updated = re.sub(placeholder_pat, f"{new_text}\n\n", existing,
                             count=1, flags=re.MULTILINE)
        else:
            updated = f"{existing.rstrip()}\n{new_text}\n\n"
        block = block[:match.start(1)] + updated + block[match.end(1):]
    else:
        block = block.rstrip("\n") + f"\n\n{header}\n{new_text}\n\n"

    return pre + block + post


def save_to_obsidian(date_obj: datetime, messages: list[dict], config: dict) -> set[str]:
    """
    Process messages and inject into Obsidian work log.
    Returns set of display names that successfully posted.
    """
    vault = os.path.expanduser(config.get("vault_path", "~/Dropbox/Obsidian"))
    output_folder = config.get("output_folder", "2. Areas/01 Work/Work Logs")
    username_map: dict[str, str] = config.get("username_mapping", {})
    template_sections: dict[str, str] = config.get("template_sections", {})
    author_header_pat = config.get("author_header_pattern", "### {author}")
    empty_placeholder = config.get("empty_placeholder_pattern", r"- ")

    date_str = date_obj.strftime("%Y-%m-%d")
    file_path = os.path.join(vault, output_folder, f"{date_str} - Work Log.md")
    os.makedirs(os.path.dirname(file_path), exist_ok=True)

    # Group messages by display name
    author_content: dict[str, list[str]] = {}
    for msg in messages:
        username = msg["author"]
        if username not in username_map:
            print(f"[WARN] Unknown username '{username}' — add to config.json username_mapping",
                  file=sys.stderr)
            continue
        display = username_map[username]
        raw = msg["content"].strip()
        if not raw:
            continue

        # Template-aware parsing if sections configured and present in post
        if template_sections and any(k in raw for k in template_sections):
            sections = parse_template_sections(raw, template_sections)
            if sections:
                parts = []
                for section_name, section_content in sections.items():
                    normalised = normalise_bullets(section_content)
                    if normalised:
                        parts.append(f"**{section_name}:**\n{normalised}")
                formatted = "\n\n".join(parts)
            else:
                formatted = normalise_bullets(raw)
        else:
            formatted = normalise_bullets(raw)

        if formatted:
            author_content.setdefault(display, []).append(formatted)

    # Create file from template if missing
    if not os.path.exists(file_path):
        print(f"[INFO] Creating {file_path} from template", file=sys.stderr)
        try:
            text = create_from_template(date_obj, config)
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(text)
        except FileNotFoundError as e:
            print(f"[ERROR] Template not found: {e}", file=sys.stderr)
            return set()

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    posted: set[str] = set()
    for display, msgs in author_content.items():
        header = author_header_pat.format(author=display)
        combined = "\n\n".join(msgs)
        content = inject_into_team_updates(content, header, combined, empty_placeholder)
        posted.add(display)

    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[INFO] Updated: {file_path}", file=sys.stderr)
    return posted


def write_missing_thread_note(date_obj: datetime, config: dict) -> None:
    """Append a note that no Discord thread was created for this date."""
    vault = os.path.expanduser(config.get("vault_path", "~/Dropbox/Obsidian"))
    output_folder = config.get("output_folder", "2. Areas/01 Work/Work Logs")
    date_str = date_obj.strftime("%Y-%m-%d")
    file_path = os.path.join(vault, output_folder, f"{date_str} - Work Log.md")

    if not os.path.exists(file_path):
        return  # don't create a log just for a missing thread note

    note = f"\n> ⚠️ No Discord EOD thread found for {date_str}\n"
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()
    if note.strip() not in content:
        with open(file_path, "a", encoding="utf-8") as f:
            f.write(note)


def write_completeness_report(date_obj: datetime, posted: set[str],
                              config: dict) -> None:
    """Append an EOD Status block showing who posted and who's missing."""
    all_members = set(config.get("username_mapping", {}).values())
    missing = all_members - posted
    vault = os.path.expanduser(config.get("vault_path", "~/Dropbox/Obsidian"))
    output_folder = config.get("output_folder", "2. Areas/01 Work/Work Logs")
    date_str = date_obj.strftime("%Y-%m-%d")
    file_path = os.path.join(vault, output_folder, f"{date_str} - Work Log.md")

    if not os.path.exists(file_path):
        return

    ts = datetime.now().strftime("%H:%M")
    block = (
        f"\n## EOD Status ({ts})\n"
        f"- ✅ Posted: {', '.join(sorted(posted)) or 'none'}\n"
        f"- ⏳ Missing: {', '.join(sorted(missing)) or 'none'}\n"
    )

    with open(file_path, "a", encoding="utf-8") as f:
        f.write(block)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch Discord EOD updates into Obsidian.")
    parser.add_argument("--channel", default=None, help="Discord Forum channel ID (falls back to channel_id in config.json)")
    parser.add_argument("--lookback-days", type=int, default=2,
                        help="Number of days to look back (default: 2)")
    parser.add_argument("--config", default=CONFIG_PATH)
    parser.add_argument("--state",  default=STATE_PATH)
    args = parser.parse_args()

    with open(args.config, "r") as f:
        config = json.load(f)

    channel_id = args.channel or config.get("channel_id")
    if not channel_id:
        print("[ERROR] --channel not set and channel_id missing from config.json", file=sys.stderr)
        sys.exit(1)

    bot_token = os.environ.get("DISCORD_BOT_TOKEN") or config.get("discord_bot_token", "")
    if bot_token.startswith("Bot "):
        bot_token = bot_token[4:]
    if not bot_token:
        print("[ERROR] DISCORD_BOT_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    state = load_state(args.state)

    # Resolve guild_id — cached after first run
    guild_id = state.get("guild_id")
    if not guild_id:
        guild_id = fetch_guild_id(bot_token, channel_id)
        if not guild_id:
            print("[ERROR] Could not resolve guild_id", file=sys.stderr)
            sys.exit(1)
        set_guild_id(state, guild_id)

    # Fetch recent threads once for the whole run
    threads = get_recent_threads(bot_token, guild_id, channel_id, args.lookback_days)

    # Process each date in the lookback window
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    dates = [today - timedelta(days=i) for i in range(args.lookback_days)]

    for date_obj in dates:
        if date_obj.weekday() >= 5:  # skip weekends
            continue

        date_str = date_obj.strftime("%Y-%m-%d")
        is_cached, cached_thread_id = get_cached_thread(state, date_str)

        # Only skip if we have a confirmed thread ID cached.
        # Never permanently cache "no thread" — thread may be created later in the day.
        if is_cached and cached_thread_id is not None:
            thread_id = cached_thread_id
        else:
            thread_id = find_thread_for_date(threads, date_obj)

        if not thread_id:
            print(f"[WARN] {date_str}: no thread found — may be created later", file=sys.stderr)
            write_missing_thread_note(date_obj, config)
            continue  # don't cache None — retry on next run

        # Cache the confirmed thread ID for future runs
        cache_thread(state, date_str, thread_id)

        # Fetch only new messages since last run
        after_id = get_last_message_id(state, thread_id)
        msgs, newest_id = fetch_messages(bot_token, thread_id, after_id=after_id)

        if not msgs:
            print(f"[INFO] {date_str}: no new messages", file=sys.stderr)
            write_completeness_report(date_obj, set(), config)
            continue

        print(f"[INFO] {date_str}: {len(msgs)} new message(s)", file=sys.stderr)
        posted = save_to_obsidian(date_obj, msgs, config)

        if newest_id:
            update_last_message_id(state, thread_id, newest_id)

        write_completeness_report(date_obj, posted, config)

    mark_run(state)
    save_state(args.state, state)


if __name__ == "__main__":
    main()
