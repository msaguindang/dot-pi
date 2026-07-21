# Rollback — {{RELEASE_ID}}

Reverts devices from **player-server {{SERVER_VERSION}} + player-ui {{UI_VERSION}}** back to **player-server {{PRIOR_SERVER_VERSION}} + player-ui {{PRIOR_UI_VERSION}}**.

## Rollback Command

```bash
wget -q https://ncompasstv-prod-player-apps.s3.amazonaws.com/secure-rc/{{BUILD_ID}}/rollback-bundle.sh -O - | bash
```

The script is idempotent — safe to re-run.

## Rollback Targets

| Component | From | To | Prior-stable ref (tag / commit) |
|-----------|------|----|---------------------------------|
| player-server | {{SERVER_VERSION}} | **{{PRIOR_SERVER_VERSION}}** | {{PRIOR_SERVER_REF}} |
| player-ui | {{UI_VERSION}} | **{{PRIOR_UI_VERSION}}** | {{PRIOR_UI_REF}} |

Prior-stable S3 BUILD_ID: `{{PRIOR_BUILD_ID}}`

## After Rollback

1. Update release.yaml status to `rolled-back`
2. Update `environments/production/desired-state.yaml` to pin the previous release
3. Document failure in verification.md
