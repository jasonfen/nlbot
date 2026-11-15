Arm ${BOT_NAME}'s wake path. Fires at boot (via the `bin/start-claude.sh` nudge) or run
manually to bring the notification listener back up after a restart.

**Why this command exists:** the listener is a session-scoped background process (Bash
`run_in_background`). It dies on restart and can only be re-armed by an *agent turn*
(a hook can't start a background task). At boot the session resumes idle, so
`bin/start-claude.sh` sends one `/start` nudge to trigger this turn. The subagents
(`soul-loop-runner`, `secretary`, …) are NOT long-running processes. They're spawned
on demand when the listener emits a notification, so arming the listener is all
that's needed.

**Step 1 — clear any stale poller.** A poller that survived from a dead session
holds its flock lock and silently swallows the wake path (its stdout reaches no
session), so a fresh arm would just flock-exit behind it. Kill first:

```bash
pkill -f 'cron-trigger-monitor\.sh' 2>/dev/null; sleep 1; true
```

**Step 2 — arm the cron-trigger poller** (Bash tool, `run_in_background: true`):
- command: `CRON_MONITOR_EXIT_ON_TRIGGER=1 exec bash ${VAULT_DIR}/bin/cron-trigger-monitor.sh`
- description: `Cron trigger poller (exits on trigger)`

> **Background-shell wake path.** The poller runs until it has something to report,
> then **exits**. Its completion notice is the wake-up: read the task's output file
> for the `CRON <name> …` lines, route each per `processes/cron-wake-path.md`, then
> **re-arm the poller with the same single call and no prose**. One re-arm per batch.
> The trade-off: a trigger that lands mid-turn waits for the next tool boundary.
> The older Monitor-tool arming (`timeout_ms: 1800000`, re-arm on every 30-minute
> expiry) still works as a fallback.

**Step 3 — confirm** it is live:

```bash
pgrep -af 'cron-trigger-monitor'
```

**Step 4 — orient.** `/start` almost always lands on a fresh context (boot,
restart, `/clear`), and the `SessionStart` hook's "Orient before anything else"
still applies. This command does not replace it. Run `bash
${VAULT_DIR}/bin/orient.sh`, Read the whole bundle file it names, then work
the CLAUDE.md re-anchor checklist from step 2. Orientation is not "other work".

Then stop. Beyond arming and orienting, don't start other work. On a
`CRON <name>` line, route per `processes/cron-wake-path.md`.
