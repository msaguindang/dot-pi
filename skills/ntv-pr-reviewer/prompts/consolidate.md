# Consolidation Task: PR Review Report

Consolidate the findings from 6 parallel reviewers (3 from Round 1, 3 from Round 2) into a single, structured report.

## Input Data:
{{REVIEWER_OUTPUTS}}

## Instructions:
1. **Deduplicate**: Merge identical findings into a single point.
2. **Structure**: 
   - Summary of Findings (Syntax, Logic, Backwards Incompatibility)
   - Impact Analysis (State, Performance, Maintainability, Integration)
   - Verdict (Verified / Needs Fix)
   - Deferred Minor Issues (List identified risks that don't block the PR)
   - Closing line (mandatory, verbatim, only on a **Verified** verdict — see below)
3. **Verdict**: If any reviewer found a blocker, the verdict is "Needs Fix". Otherwise, "Verified".
4. **Tone**: Direct, technical, and concise.
5. **Closing line — mandatory on Verified verdict**: the report's literal last line must be exactly:

   > Merging is a human action performed via the GitHub UI. This agent never merges or approves a PR — review ends at the report.

   Do not paraphrase it, do not omit it on a Verified verdict, do not add it on a Needs Fix verdict.

Provide the final report clearly.
