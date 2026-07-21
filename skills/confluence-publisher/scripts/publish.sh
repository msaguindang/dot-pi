#!/usr/bin/env bash

set -euo pipefail

# --- secrets: load from Infisical (agent root: ~/.pi/agent) ---
INFISICAL_ROOT="$HOME/.pi/agent"
if command -v infisical &>/dev/null && [[ -f "$INFISICAL_ROOT/.infisical.json" ]]; then
    eval "$(infisical export --format=dotenv-export --silent --path / 2>/dev/null)" || true
fi

# Enforce required secrets
: "${CONFLUENCE_DOMAIN:?CONFLUENCE_DOMAIN not set. Ensure Infisical is authenticated.}"
: "${CONFLUENCE_EMAIL:?CONFLUENCE_EMAIL not set. Ensure Infisical is authenticated.}"
: "${CONFLUENCE_API_TOKEN:?CONFLUENCE_API_TOKEN not set. Ensure Infisical is authenticated.}"

# --- defaults ---
SPACE_KEY="NCTV"
PARENT_ID="2588673"
TITLE=""
MD_FILE=""
PAGE_ID=""   # If set, UPDATE (PUT) an existing page instead of CREATE (POST)

# --- argument parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --title)     TITLE="$2";     shift 2 ;;
        --file)      MD_FILE="$2";   shift 2 ;;
        --space)     SPACE_KEY="$2"; shift 2 ;;
        --parent-id) PARENT_ID="$2"; shift 2 ;;
        --page-id)   PAGE_ID="$2";   shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: publish.sh --title <title> --file <markdown_file> [--space <key>] [--parent-id <id>] [--page-id <id>]" >&2
            exit 1
            ;;
    esac
done

# --- validate required arguments ---
if [[ -z "$TITLE" ]]; then
    echo "Error: --title is required." >&2
    exit 1
fi
if [[ -z "$MD_FILE" ]]; then
    echo "Error: --file is required." >&2
    exit 1
fi
if [[ ! -f "$MD_FILE" ]]; then
    echo "Error: file not found: $MD_FILE" >&2
    exit 1
fi

# --- check dependencies ---
for dep in curl jq node; do
    if ! command -v "$dep" &>/dev/null; then
        echo "Error: required dependency not found: $dep" >&2
        exit 1
    fi
done

# --- locate md-to-html.js relative to this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD_TO_HTML="$SCRIPT_DIR/md-to-html.js"
if [[ ! -f "$MD_TO_HTML" ]]; then
    echo "Error: md-to-html.js not found at $MD_TO_HTML" >&2
    exit 1
fi

# --- convert markdown to HTML (strips YAML frontmatter, handles GFM anchors) ---
echo "Converting markdown to HTML..." >&2
HTML=$(node "$MD_TO_HTML" "$MD_FILE" 2>&1)
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    echo "Error: md-to-html.js failed (exit $EXIT_CODE):" >&2
    echo "$HTML" >&2
    exit 1
fi
if [[ -z "$HTML" ]]; then
    echo "Error: markdown conversion produced empty output." >&2
    exit 1
fi

# --- CREATE (POST) vs UPDATE (PUT) ---
if [[ -z "$PAGE_ID" ]]; then
    # --- CREATE: build JSON payload ---
    PAYLOAD=$(jq -n \
        --arg title     "$TITLE" \
        --arg space     "$SPACE_KEY" \
        --arg parent_id "$PARENT_ID" \
        --arg html      "$HTML" \
        '{
            type: "page",
            title: $title,
            space: { key: $space },
            ancestors: [{ id: $parent_id }],
            body: {
                storage: {
                    value: $html,
                    representation: "storage"
                }
            }
        }')

    ENDPOINT="${CONFLUENCE_DOMAIN}/wiki/rest/api/content"
    echo "Publishing NEW page to Confluence space ${SPACE_KEY}..." >&2

    RESPONSE=$(curl -fsSL \
        -X POST \
        -u "${CONFLUENCE_EMAIL}:${CONFLUENCE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$ENDPOINT" 2>&1) || {
            echo "Error: Confluence API request failed." >&2
            echo "$RESPONSE" >&2
            exit 1
        }

    # --- extract and print the page URL ---
    CREATED_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
    PAGE_TITLE=$(echo "$RESPONSE" | jq -r '.title // empty')

    if [[ -z "$CREATED_ID" ]]; then
        echo "Error: page creation response did not include a page ID." >&2
        echo "$RESPONSE" | jq '.' >&2
        exit 1
    fi

    PAGE_URL="${CONFLUENCE_DOMAIN}/wiki/spaces/${SPACE_KEY}/pages/${CREATED_ID}"
    echo "✓ Page created: ${PAGE_TITLE}"
    echo "  URL: ${PAGE_URL}"

else
    # --- UPDATE: fetch current version first ---
    echo "Fetching current version of page ${PAGE_ID}..." >&2

    CURRENT=$(curl -fsSL \
        -u "${CONFLUENCE_EMAIL}:${CONFLUENCE_API_TOKEN}" \
        -H "Accept: application/json" \
        "${CONFLUENCE_DOMAIN}/wiki/rest/api/content/${PAGE_ID}?expand=version,ancestors,space" 2>&1) || {
            echo "Error: failed to fetch page ${PAGE_ID}." >&2
            echo "$CURRENT" >&2
            exit 1
        }

    CURRENT_VERSION=$(echo "$CURRENT" | jq -r '.version.number // empty')
    if [[ -z "$CURRENT_VERSION" ]]; then
        echo "Error: could not read current version for page ${PAGE_ID}." >&2
        echo "$CURRENT" | jq '.' >&2
        exit 1
    fi

    NEXT_VERSION=$(( CURRENT_VERSION + 1 ))
    echo "Current version: ${CURRENT_VERSION} → updating to version ${NEXT_VERSION}" >&2

    # Fetch space key and ancestors from the existing page if not overridden
    FETCHED_SPACE=$(echo "$CURRENT" | jq -r '.space.key // empty')
    EFFECTIVE_SPACE="${FETCHED_SPACE:-$SPACE_KEY}"

    # Build ancestor list from current page (preserve parent)
    ANCESTOR_ID=$(echo "$CURRENT" | jq -r '.ancestors[-1].id // empty')

    PAYLOAD=$(jq -n \
        --arg id        "$PAGE_ID" \
        --arg title     "$TITLE" \
        --arg space     "$EFFECTIVE_SPACE" \
        --arg ancestor  "${ANCESTOR_ID:-$PARENT_ID}" \
        --argjson ver   "$NEXT_VERSION" \
        --arg html      "$HTML" \
        '{
            id: $id,
            type: "page",
            title: $title,
            space: { key: $space },
            ancestors: [{ id: $ancestor }],
            version: { number: $ver },
            body: {
                storage: {
                    value: $html,
                    representation: "storage"
                }
            }
        }')

    ENDPOINT="${CONFLUENCE_DOMAIN}/wiki/rest/api/content/${PAGE_ID}"
    echo "Updating page ${PAGE_ID} in Confluence space ${EFFECTIVE_SPACE}..." >&2

    RESPONSE=$(curl -fsSL \
        -X PUT \
        -u "${CONFLUENCE_EMAIL}:${CONFLUENCE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$ENDPOINT" 2>&1) || {
            echo "Error: Confluence API update request failed." >&2
            echo "$RESPONSE" >&2
            exit 1
        }

    UPDATED_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
    PAGE_TITLE=$(echo "$RESPONSE" | jq -r '.title // empty')
    UPDATED_VERSION=$(echo "$RESPONSE" | jq -r '.version.number // empty')

    if [[ -z "$UPDATED_ID" ]]; then
        echo "Error: update response did not include a page ID." >&2
        echo "$RESPONSE" | jq '.' >&2
        exit 1
    fi

    PAGE_URL="${CONFLUENCE_DOMAIN}/wiki/spaces/${EFFECTIVE_SPACE}/pages/${UPDATED_ID}"
    echo "✓ Page updated: ${PAGE_TITLE} (version ${UPDATED_VERSION})"
    echo "  URL: ${PAGE_URL}"
fi
