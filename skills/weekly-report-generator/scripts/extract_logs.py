import sys
import re
from pathlib import Path
from datetime import datetime

def extract_sections(content):
    """Extracts Dev Log and Team Updates from a work log."""
    dev_log = ""
    team_updates = ""
    
    # Extract Dev Log
    dev_match = re.search(r'## Dev Log\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if dev_match:
        dev_log = dev_match.group(1).strip()
        # Remove the placeholder text
        dev_log = dev_log.replace("*Drop PR links, quick notes, or blockers here. Keep short. No full sentences needed.*", "").strip()

    # Extract Team Updates
    team_match = re.search(r'## Team Updates\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if team_match:
        team_updates = team_match.group(1).strip()

    return dev_log, team_updates

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 extract_logs.py <YYYY-Www> <VAULT_PATH>")
        sys.exit(1)

    target_week = sys.argv[1]
    vault_path = Path(sys.argv[2]).expanduser().resolve()
    work_logs_dir = vault_path / "2. Areas/01 Work/01 Operations/Work Logs"

    if not work_logs_dir.exists():
        print(f"Error: Directory not found at {work_logs_dir}")
        sys.exit(1)

    print(f"--- EXTRACTING LOGS FOR WEEK {target_week} ---")
    
    found_logs = False
    for filepath in sorted(work_logs_dir.glob("*.md")):
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
            
        if f"week: {target_week}" in content:
            found_logs = True
            date_str = filepath.name.replace(" - Work Log.md", "")
            dev_log, team_updates = extract_sections(content)
            
            if dev_log or team_updates:
                print(f"\n{'='*40}")
                print(f"DATE: {date_str}")
                print(f"{'='*40}")
                
                if dev_log:
                    print("\n[MY DEV LOG]")
                    print(dev_log)
                    
                if team_updates:
                    print("\n[TEAM UPDATES]")
                    print(team_updates)

    if not found_logs:
        print(f"No logs found for week {target_week}.")

if __name__ == "__main__":
    main()
