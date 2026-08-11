---
name: plane-tasks
description: Fetch, filter, and update Plane work items (issues) from the terminal or within a pi session. Use when the user asks about tasks, tickets, what to work on next, or wants to update task status in Plane.
---

# plane-tasks

Provides tools for interacting with Plane API to manage tasks for NTV projects.

## Setup
1. Create `~/.config/plane/env` based on `~/.config/plane/env.example`.
2. Ensure `curl` and `jq` are installed.

## Usage
- List my active issues: `/skill:plane-tasks scripts/plane-issues.sh --project <project_id>`
- List ALL work items in a project, any assignee/state, with resolved state names (not UUIDs): `/skill:plane-tasks scripts/plane-list.sh --project <project_id> [--output json|table]`
- Update task: `/skill:plane-tasks scripts/plane-update.sh <issue_sequence_id> <project_id> <new_state_name>`

## MCP Configuration (for Claude Desktop / pi)
```json
{
  "mcpServers": {
    "plane": {
      "command": "uvx",
      "args": ["plane-mcp-server", "stdio"],
      "env": {
        "PLANE_API_KEY": "YOUR_KEY",
        "PLANE_WORKSPACE_SLUG": "YOUR_SLUG",
        "PLANE_BASE_URL": "https://api.plane.so"
      }
    }
  }
}
```
