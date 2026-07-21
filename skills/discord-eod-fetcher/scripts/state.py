"""
state.py — Persistent state management for discord-eod-fetcher.

Stores:
  last_run         — ISO timestamp of last successful run
  guild_id         — cached Discord guild ID (never changes)
  thread_cache     — {date_str → thread_id | null} (null = confirmed missing)
  last_message_ids — {thread_id → last processed message snowflake ID}

Uses atomic write (temp file + rename) to prevent corruption.
"""

import json
import os
import tempfile
from datetime import datetime, timezone
from typing import Optional

DEFAULT_STATE: dict = {
    "last_run": None,
    "guild_id": None,
    "thread_cache": {},
    "last_message_ids": {},
}


def load_state(state_path: str) -> dict:
    """Load state from disk. Returns safe defaults on missing or corrupt file."""
    if not os.path.exists(state_path):
        return DEFAULT_STATE.copy()
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        # Ensure all expected keys exist (forward-compat with new fields)
        for key, default in DEFAULT_STATE.items():
            data.setdefault(key, default)
        return data
    except (json.JSONDecodeError, OSError):
        return DEFAULT_STATE.copy()


def save_state(state_path: str, state: dict) -> None:
    """Atomically write state to disk via temp file + rename."""
    dir_path = os.path.dirname(state_path) or "."
    os.makedirs(dir_path, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, default=str)
        os.replace(tmp_path, state_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def get_cached_thread(state: dict, date_str: str) -> tuple[bool, Optional[str]]:
    """
    Returns (is_cached, thread_id).
    is_cached=True + thread_id=None  → confirmed no thread for this date
    is_cached=True + thread_id=str   → known thread ID
    is_cached=False                  → not yet checked, fetch from API
    """
    cache = state.get("thread_cache", {})
    if date_str not in cache:
        return False, None
    return True, cache[date_str]  # may be None (confirmed missing)


def cache_thread(state: dict, date_str: str, thread_id: Optional[str]) -> None:
    """Store thread_id for date (None = confirmed no thread)."""
    state.setdefault("thread_cache", {})[date_str] = thread_id


def get_last_message_id(state: dict, thread_id: str) -> Optional[str]:
    """Return the last processed message snowflake ID for a thread."""
    return state.get("last_message_ids", {}).get(thread_id)


def update_last_message_id(state: dict, thread_id: str, message_id: str) -> None:
    """Record the newest processed message ID for a thread."""
    state.setdefault("last_message_ids", {})[thread_id] = message_id


def set_guild_id(state: dict, guild_id: str) -> None:
    state["guild_id"] = guild_id


def mark_run(state: dict) -> None:
    state["last_run"] = datetime.now(timezone.utc).isoformat()
