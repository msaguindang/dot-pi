#!/usr/bin/env node
/**
 * md-to-html.js
 * Strips YAML frontmatter and converts Markdown to HTML.
 *
 * Usage:
 *   node md-to-html.js <file.md>    # file argument
 *   cat file.md | node md-to-html.js  # stdin
 *
 * Output: clean HTML on stdout, errors on stderr.
 */

import { createRequire } from 'module';
import { readFileSync } from 'fs';
import { marked } from 'marked';
import { gfmHeadingId } from 'marked-gfm-heading-id';

// gray-matter is CJS — load via createRequire
const require = createRequire(import.meta.url);
const matter = require('gray-matter');

// Apply the GFM heading ID extension for consistent anchor links
marked.use(gfmHeadingId());

/**
 * Read input: file argument first, fallback to stdin.
 */
function readInput() {
    const filePath = process.argv[2];
    if (filePath) {
        try {
            return readFileSync(filePath, 'utf8');
        } catch (err) {
            console.error(`Error reading file '${filePath}': ${err.message}`);
            process.exit(1);
        }
    }

    // Read from stdin
    try {
        return readFileSync('/dev/stdin', 'utf8');
    } catch (err) {
        console.error(`Error reading stdin: ${err.message}`);
        process.exit(1);
    }
}

try {
    const raw = readInput();

    // Strip YAML frontmatter; content holds the clean markdown body
    const { content } = matter(raw);

    // Strip the first H1 if it matches the release heading pattern.
    // Confluence page title already serves as H1, so the body H1 is redundant.
    const lines = content.split('\n');
    const firstContentIdx = lines.findIndex(l => l.trim().length > 0);
    const strippedContent =
        firstContentIdx !== -1 && /^# Release:/.test(lines[firstContentIdx])
            ? lines.slice(firstContentIdx + 1).join('\n')
            : content;

    // Convert markdown to HTML
    const html = marked.parse(strippedContent);

    if (!html || html.trim().length === 0) {
        console.error('Error: markdown conversion produced empty output.');
        process.exit(1);
    }

    process.stdout.write(html);
} catch (err) {
    console.error(`Error during conversion: ${err.message}`);
    process.exit(1);
}
