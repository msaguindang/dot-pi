# Verification — {{RELEASE_ID}}

Status: pending
Device: _(fill in test device ID)_
Date: _(fill in)_

## QA Checklist

- [ ] Device boots cleanly after update (no re-init loop)
- [ ] `pm2 status` shows player-server online, restart counter stable across 2 samples 20s apart
- [ ] Installed server version matches {{SERVER_VERSION}} (`package.json` on device)
- [ ] Installed UI version matches {{UI_VERSION}} (`/var/www/html/ui/package.json`)
- [ ] UI loads in Chromium kiosk and is responsive; content rotates
- [ ] Browser console clean of errors (no 404/5xx on API calls)
- [ ] Cron jobs re-enabled after update window (crontab matches expected schedule)
- [ ] Play logs written with correct local date/time
- [ ] `sha256sum --check checksums.sha256` passes on device against fetched artifacts
- [ ] No leftover backup/temp dirs from the update script

## Evidence

_(paste command output / screenshots references here)_
