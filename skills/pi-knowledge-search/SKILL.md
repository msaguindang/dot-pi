---
name: pi-knowledge-search
description: "Search atomic knowledge notes in Obsidian, agent context, and agent standards via ripgrep to fulfill Layer 3 memory retrieval."
---
# pi-knowledge-search

A search tool for querying the user's Obsidian vault and internal agent knowledge base. 
Uses ripgrep for fast, context-aware searching across `~/Dropbox/Obsidian/`, `~/.agents/context/`, and `~/.agents/standards/`.

## Usage
Invoke the `search.sh` script to find information, docs, or past notes relevant to the current task. The tool returns file paths and snippets.

```bash
~/.pi/agent/skills/pi-knowledge-search/scripts/search.sh "your search query"
```
