---
slug: <task-slug>
title: <brief title>
acceptance_count: <N>  # 6-17 typical
scope_fence: <riskiest-mutation>
---

## Context Files (Read FIRST — absolute paths)

<!-- Path-only checklist. Absolute paths MANDATORY. No relative references. -->
- [ ] /absolute/path/to/file1.ts
- [ ] /absolute/path/to/file2.yml

## Exact Changes

[Describe mutations with precision: line numbers, old->new, semantic intent.
Each change must be understandable without any prior conversation context.]

## Hard Scope Fence

Mutate only: [list files/functions]
Do NOT touch: [list files/boundaries]

## Acceptance Criteria

<!-- Each criterion must stand alone and be objectively checkable.
     Name the evidence type: code diff | git status | API response | file presence. -->
1. [Objectively checkable criterion — evidence type: code diff]
2. [Criterion with measurable pass/fail — evidence type: file presence]
