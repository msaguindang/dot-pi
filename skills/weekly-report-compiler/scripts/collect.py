#!/usr/bin/env python3
"""
Collects work log files for the current week and outputs metadata as JSON.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path


def load_config() -> dict:
    config_path = Path(__file__).parent / "config.json"
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_week_bounds(weeks_ago: int = 0) -> tuple[datetime, datetime]:
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    today -= timedelta(weeks=weeks_ago)
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=4)
    return week_start, week_end


def iso_week_label(date: datetime) -> str:
    return date.strftime("%G-W%V")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weeks-ago", type=int, default=0, help="Number of weeks to look back")
    args = parser.parse_args()

    config = load_config()
    vault_path = Path(config["vault_path"]).expanduser().resolve()
    logs_dir = vault_path / config["work_logs_folder"]
    reports_dir = vault_path / config["reports_folder"]

    week_start, week_end = get_week_bounds(args.weeks_ago)
    friday = week_end
    report_filename = f"{friday.strftime('%Y-%m-%d')} - Weekly Report.md"
    report_path = reports_dir / report_filename
    report_exists = report_path.exists()

    work_logs = []
    current = week_start
    while current <= week_end:
        log_filename = f"{current.strftime('%Y-%m-%d')} - Work Log.md"
        log_path = logs_dir / log_filename
        if log_path.exists():
            content = log_path.read_text(encoding="utf-8")
            work_logs.append({
                "date": current.strftime("%Y-%m-%d"),
                "path": str(log_path),
                "content": content,
            })
        current += timedelta(days=1)

    output = {
        "week_start": week_start.strftime("%Y-%m-%d"),
        "week_end": week_end.strftime("%Y-%m-%d"),
        "week_label": iso_week_label(week_start),
        "report_date": friday.strftime("%Y-%m-%d"),
        "report_filename": report_filename,
        "report_path": str(report_path),
        "report_exists": report_exists,
        "work_logs": work_logs,
    }

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
