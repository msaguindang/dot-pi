#!/usr/bin/env bash
set -euo pipefail

# Usage: persist.sh <slug> <source_file>
# Persists research output to /tmp/pi-research/<slug>.md

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <slug> <source_file>" >&2
    exit 1
fi

SLUG="$1"
SOURCE_FILE="$2"

# Validate slug format (kebab-case, no spaces, no slashes)
if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
    echo "Error: Slug must be kebab-case (lowercase a-z, 0-9, hyphens)." >&2
    exit 1
fi

# Validate source file exists and is readable
if [ ! -f "$SOURCE_FILE" ] || [ ! -r "$SOURCE_FILE" ]; then
    echo "Error: Source file not found or not readable: $SOURCE_FILE" >&2
    exit 1
fi

# Create target directory
TARGET_DIR="/tmp/pi-research"
mkdir -p "$TARGET_DIR"

# Copy contents to target file
TARGET_FILE="$TARGET_DIR/${SLUG}.md"
cp "$SOURCE_FILE" "$TARGET_FILE"

echo "Research persisted to: $TARGET_FILE"
