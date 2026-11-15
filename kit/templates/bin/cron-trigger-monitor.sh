#!/bin/bash
# Cron trigger delivery — the non-injecting, idle-gated wake path for crons.
#
# Runs as a session-scoped background task: Bash run_in_background with
# CRON_MONITOR_EXIT_ON_TRIGGER=1 (see .claude/commands/start.md), or the Monitor tool. Polls .cron-triggers/ every few
# seconds; for each trigger file it emits a "CRON <name> <ctx>" line to stdout
# ONLY when the main session is idle, then removes the trigger. If the session
# is busy (Claude processing, or ${HUMAN_NAME} typing) it leaves the trigger in place
# and retries next cycle — that single behavior gives idle-gate + queue-and-
# retry-at-next-idle. It NEVER injects keystrokes; the emitted stdout line
# reaches the main session as a notification.
#
# The main session routes each "CRON <name>" notification to the matching runner
# subagent — see processes/cron-wake-path.md.
set -uo pipefail

VAULT=${VAULT_DIR}
TRIGGER_DIR="$VAULT/.cron-triggers"
LOCK="$VAULT/.cron-trigger-monitor.lock"
POLL="${CRON_TRIGGER_POLL:-5}"

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "cron-trigger-monitor: another instance already running — exiting" >&2
  exit 0
fi
mkdir -p "$TRIGGER_DIR"

# Is the main Claude session idle? (spinner static AND cursor not moving)
# Reused from inject-prompt.sh's busy-detection. Returns 0 = idle, 1 = busy.
session_idle() {
  local pane t1 t2 c1 c2
  tmux has-session -t claude 2>/dev/null || return 1
  # If claude is started through a wrapper script, the pane's current command is
  # the `bash` parent, not `claude`. Accept a pane
  # whose foreground command is claude OR whose shell has a claude child. (Matching
  # only pane_current_command=claude silently held every trigger for 36 h.)
  local id cmd ppid
  while read -r id cmd ppid; do
    if [ "$cmd" = claude ] || pgrep -x -P "$ppid" claude >/dev/null 2>&1; then pane=$id; break; fi
  done < <(tmux list-panes -t claude -F '#{pane_id} #{pane_current_command} #{pane_pid}')
  [ -z "$pane" ] && return 1
  t1=$(tmux display-message -p -t "$pane" '#{pane_title}'); sleep 0.4
  t2=$(tmux display-message -p -t "$pane" '#{pane_title}')
  [ "$t1" != "$t2" ] && return 1        # spinner animating -> Claude busy
  c1=$(tmux display-message -p -t "$pane" '#{cursor_x}'); sleep 0.2
  c2=$(tmux display-message -p -t "$pane" '#{cursor_x}')
  [ "$c1" != "$c2" ] && return 1        # cursor moving -> ${HUMAN_NAME} typing
  return 0
}

# CRON_MONITOR_EXIT_ON_TRIGGER=1 (2026-10-07): exit after a pass that emitted
# any triggers, so the monitor can run under Bash run_in_background (one
# completion notice per batch, re-armed by the agent) instead of a Monitor
# that expires every 30 minutes.
while true; do
  emitted=0
  for f in "$TRIGGER_DIR"/*;  do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in .*) continue ;; esac   # skip .tmp partial writes
    if session_idle; then
      ctx=$(cat "$f" 2>/dev/null | tr '\n' ' ')
      rm -f "$f"
      echo "CRON ${name}${ctx:+ ${ctx% }}"
      emitted=1
    fi
    # busy -> leave the trigger, retry next cycle (idle-gate + queue)
  done
  [ "${CRON_MONITOR_EXIT_ON_TRIGGER:-0}" = 1 ] && [ "$emitted" = 1 ] && exit 0
  sleep "$POLL"
done
