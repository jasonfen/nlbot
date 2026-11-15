#!/usr/bin/env bash
# SessionStart hook: re-arm the cron trigger monitor after a restart.
# The poller is a session-scoped background task that only the running agent can
# launch, so on a fresh session we ask the agent to relaunch it. Idempotent: silent if it's already running.
# See processes/cron-wake-path.md.

if pgrep -f 'cron-trigger-monitor\.sh' >/dev/null 2>&1; then
  exit 0
fi

jq -n '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Cron wake path is not armed: cron-trigger-monitor is not running. Relaunch it now: run /start, or use the Bash tool with run_in_background:true and command `CRON_MONITOR_EXIT_ON_TRIGGER=1 exec bash ${VAULT_DIR}/bin/cron-trigger-monitor.sh`. It delivers cron triggers as notifications (idle-gated) which you route to runners per processes/cron-wake-path.md."
  }
}'
