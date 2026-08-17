# Orchestration Baseline Metrics

**Timestamp:** 2026-08-17T16:50:00Z
**Command:** `node --experimental-strip-types ./scripts/orchestration-metrics.ts /home/codeweaver/.pi/agent/sessions/--data-dev-work-ntv-player-server--/subagent-artifacts`
**Source:** `/home/codeweaver/.pi/agent/sessions/--data-dev-work-ntv-player-server--/subagent-artifacts`
**Sample Count:** 24 valid runs

## Overall Statistics

| Metric | p50 | p95 | Total |
|--------|-----|-----|-------|
| Duration | 1m 20s (79,778 ms) | 5m 59s (359,459 ms) | 50m 10s (3,010,866 ms) |
| Turns | 12.5 | 39 | 389 |
| Tools | 14 | 57.8 | 472 |
| Tokens | 419,250 | 2,909,602 | 18,078,357 |
| Cost | $0.30 | $1.43 | $12.10 |

## Per-Agent p50 / p95

| Agent | Count | Duration (p50 / p95) | Turns (p50 / p95) | Tools (p50 / p95) | Cost (p50 / p95) |
|-------|-------|----------------------|-------------------|-------------------|------------------|
| oracle | 3 | 48.9s / 2m 41s | 3 / 6.6 | 4 / 5.8 | $0.21 / $0.53 |
| planner | 2 | 1m 19s / 1m 21s | 7 / 8.8 | 9 / 13.5 | $0.23 / $0.24 |
| reviewer | 10 | 1m 11s / 6m 03s | 18.5 / 45.1 | 17.5 / 44.1 | $0.32 / $1.46 |
| scout | 2 | 2m 59s / 3m 10s | 11.5 / 13.8 | 48.5 / 66.1 | $0.99 / $1.18 |
| worker | 7 | 1m 30s / 5m 41s | 15 / 39 | 14 / 48.6 | $0.30 / $1.33 |

## Budget Interpretation & Known Cases

**Known Case - `ntv-release`:** The `ntv-release` case historically took 31m40s. The p95 overall duration is currently around 6 minutes, which shows that standard tasks complete much faster. However, edge-case heavy releases or major rewrites can still skew the tail significantly.

**Reviewer Budget Ceiling Exceeded:** 
The p95 turns for the `reviewer` agent is **45.1 turns**, which exceeds the configured 20+5 completion ceiling for reviewers. 
*Interpretation:* Broad or repository-wide reviews often hit the turn limit before completion. Broad reviews need an explicit override if full coverage is expected in one pass. 
*Recommendation:* It is recommended to implement a measured follow-up (e.g., scoping reviews to changed files only or breaking them into smaller parallel passes) rather than silently increasing the global reviewer budget ceiling.

*(Note: Risk tiers are not explicitly available in the raw metadata files and are omitted from this baseline summary.)*