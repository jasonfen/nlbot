#!/bin/bash
# Non-injecting cron trigger — replaces inject-prompt.sh's keystroke paste.
#
# Runs the per-cron gate; if there's real work, drops a trigger file that
# cron-trigger-monitor.sh delivers to the main session as a NOTIFICATION (never
# a tmux paste). Idle-gating and queue/retry live in the monitor, not here — so
# this script is deliberately tiny and never touches tmux.
#
# Usage (from crontab): cron-wake.sh <cron-name>
#   A gate at cron-prompts/gates/<name>.sh is run if present; its stdout becomes
#   the trigger's context. No gate = the cron always has work (nightly/morning
#   jobs) and fires every time.
#
# Kill switch: create cron-prompts/.cron-wake-paused to freeze all cron wakes.
set -uo pipefail

VAULT=${VAULT_DIR}
CRON_DIR="$VAULT/cron-prompts"
TRIGGER_DIR="$VAULT/.cron-triggers"
KILL_SWITCH="$CRON_DIR/.cron-wake-paused"
LOG="$CRON_DIR/inject.log"

name="${1:-}"
[ -z "$name" ] && { echo "usage: $0 <cron-name>" >&2; exit 1; }
log() { echo "$(date '+%F %T') cron-wake $*" >> "$LOG"; }

[ -f "$KILL_SWITCH" ] && { log "PAUSED — skipping $name"; exit 0; }
mkdir -p "$TRIGGER_DIR"

GATE="$CRON_DIR/gates/$name.sh"
ctx=""
if [ -x "$GATE" ]; then
  ctx=$("$GATE"); rc=$?
  if [ "$rc" -eq 10 ]; then log "GATE noop $name"; exit 0; fi
  if [ "$rc" -ne 0 ]; then log "GATE error $name rc=$rc"; exit 0; fi
fi

# One pending trigger per cron (filename = cron name). Atomic write so the
# monitor never reads a half-written file. Overwriting a still-pending trigger
# just refreshes its context — no backlog storm on a long-busy stretch.
printf '%s' "$ctx" > "$TRIGGER_DIR/.$name.tmp" && mv "$TRIGGER_DIR/.$name.tmp" "$TRIGGER_DIR/$name"
log "TRIGGER $name${ctx:+ ($ctx)}"
