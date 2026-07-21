#!/bin/bash
# search.sh - Query Obsidian and agent context
# Usage: ./search.sh <search_term>

if [ -z "$1" ]; then
  echo "Usage: $0 <search_term>"
  exit 1
fi

SEARCH_TERM="$1"
SEARCH_PATHS="$HOME/Dropbox/Obsidian/ $HOME/.agents/context/ $HOME/.agents/standards/"

rg -i --max-columns 150 --max-columns-preview --no-heading --line-number --context 2 "$SEARCH_TERM" $SEARCH_PATHS
