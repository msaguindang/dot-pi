---
name: rpi-doctor
description: An intelligent, context-aware diagnostic tool for Raspberry Pi and local network devices. Automatically translates vague symptoms ("laggy", "player-server broken") into targeted SSH commands (pm2 status, top, etc.). Resolves device aliases to IPs using the local inventory. Also runs a read-only composite probe bundle — use when the user says "rpi-probe <ip>", "probe the device", "probe <device>", "check device state", "verify the deployment", or asks for a post-update health check.
---

# RPI Doctor

An interactive, context-aware skill for managing, diagnosing, and resolving issues on local network devices (primarily Raspberry Pis running NTV services).

## Architecture
- **Inventory:** Resolves friendly device names (e.g., `test-pi`) to IP addresses using the bundled `device-inventory.json` file in the skill directory.
- **Context-Aware Triage:** Understands the *intent* of your query and selects the correct diagnostic commands.
- **On-Demand Execution:** Uses native `ssh` via a bundled bash script with strict timeouts. It does not leave zombie processes running in the background.

---

## When to use this skill
- When the user asks to "check the remote device" or "check [device-name]".
- When the user reports a symptom on a local device (e.g., "test-pi is laggy", "player-server is throwing errors on <device-ip>").
- When the user wants to list, add, or remove devices from their known inventory.
- When the user says "rpi-probe <ip/device>", "probe the device", "check device state", or wants deployment verification / a post-update health check (use the `probe` category).

---

## Diagnostic Contexts (How the AI should interpret symptoms)

When the user asks you to check a device, analyze their input to determine the *Category* of the problem, then pass that category to the diagnostic script.

1.  **Category: `app` (Specific Service Issues)**
    *   *Trigger:* User mentions a specific application (e.g., "player-server", "dashboard", "api") or a software crash.
    *   *Execution:* The script will check `pm2 status` and pull the last 50 lines of logs for the specified app.
    *   *Agent Action:* Run `scripts/diagnose.sh <device> app <app-name>`
2.  **Category: `health` (System/Hardware Issues)**
    *   *Trigger:* User mentions hardware symptoms (e.g., "laggy", "frozen", "slow", "out of space").
    *   *Execution:* The script will check CPU load (`top`), RAM (`free`), disk space (`df`), and uptime.
    *   *Agent Action:* Run `scripts/diagnose.sh <device> health`
3.  **Category: `general` (Vague Checks)**
    *   *Trigger:* User just says "check test-pi".
    *   *Execution:* A lightweight combination of uptime and top-level PM2 status.
    *   *Agent Action:* Run `scripts/diagnose.sh <device> general`
4.  **Category: `probe` (Composite Read-Only Probe)**
    *   *Trigger:* User says "rpi-probe 192.168.1.89", "probe the device", "check device state", "verify the deployment", or wants a post-update health check / stuck-device diagnostic.
    *   *Execution:* Runs the full read-only bundle in one SSH session: pm2 list, deploy log listing + newest tail, deployment manifest, installed server/UI versions, pm2 logs (last 30, no stream), crontab, system time/NTP. Zero mutations on the device; safe to repeat.
    *   *Agent Action:* Run `scripts/probe.sh <device> [--format json|text|csv]` (or equivalently `scripts/diagnose.sh <device> probe [format]`)
    *   *Output:* Report written to `/tmp/probe-<host>-<timestamp>.txt` (or `.json`/`.csv`), with a Summary section: health GOOD/WARNING/CRITICAL, error counts, and a recommendation. A 4-line summary is printed to stdout. Exit 1 only on SSH connection failure.
    *   *Note:* Device paths default to `/tmp/ntv-deploy-logs`, `/home/pi/deployment-manifest.json`, `/home/pi/player-server/package.json`, `/var/www/html/ui/package.json` — override with `RPI_DEPLOY_LOG_DIR`, `RPI_MANIFEST`, `RPI_SERVER_PKG`, `RPI_UI_PKG` env vars if a device differs.
5.  **Category: `custom` (Explicit Commands)**
    *   *Trigger:* User explicitly says "run `ls -la` on test-pi".
    *   *Agent Action:* Run `scripts/diagnose.sh <device> custom "ls -la"`

---

## Connection Handling Workflow

If the execution of `scripts/diagnose.sh` fails with a timeout or connection refused error (e.g., `Connection timed out`), you must pause and ask the user:
> "I couldn't reach `[device-name]`. Its IP might have changed or it might be offline. Would you like to:"
> 1. Update its IP address in the inventory.
> 2. Try scanning the network (if applicable tools are available).
> 3. Provide a different device to check.

If the user chooses to update the inventory, use your `edit` or `write` tools to update the skill's bundled `skills/rpi-doctor/device-inventory.json`.

---

## Managing the Inventory
If the user asks to "list devices", read the skill's bundled `skills/rpi-doctor/device-inventory.json` and present the contents cleanly. If they ask to add a device, prompt them for the `name`, `host` (IP), and `user` (defaulting to key-based auth), then update the JSON file.

## Bundled Resources
- `scripts/diagnose.sh` (The secure SSH executor with timeouts and context-aware command selection)
- `scripts/probe.sh` (Read-only composite probe bundle — deployment verification and device health snapshot)
