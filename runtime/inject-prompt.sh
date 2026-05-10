#!/bin/bash
# Inject a prompt file into the running the bot Claude tmux session.
# Usage: inject-prompt.sh <prompt-file-basename>
# Example: inject-prompt.sh soul-loop.md
#
# Designed to be called from system cron. Behaviour:
# - Silent no-op if tmux session not running (recovery: start-claude.sh)
# - Targets the pane where pane_current_command == "claude" (ignores shell panes)
# - Defers paste if Claude is mid-response or user is mid-typing
# - Defers go into a retry queue and are re-attempted on every subsequent fire
# - Only ONE paste happens per fire — if a queued item is delivered, the
#   originally-requested prompt is queued instead
# - flock prevents two simultaneous fires from double-pasting
# - Defers, retries, and drops are logged to cron-prompts/inject.log

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="$SCRIPT_DIR/queue"
LOG_FILE="$SCRIPT_DIR/inject.log"
LOCK_FILE="$SCRIPT_DIR/.inject.lock"
MAX_QUEUE_AGE=$((6 * 3600))  # 6 hours

mkdir -p "$QUEUE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

if [[ -z "$1" ]]; then
  echo "Usage: $0 <prompt-file>" >&2
  exit 1
fi

REQUESTED="$1"

# Acquire lock — silent exit if another inject is in flight
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  exit 0
fi

# --- try_inject: attempt to paste a prompt into the Claude pane.
# Returns 0 on successful paste, 1 on defer (reason logged).
try_inject() {
  local name="$1"
  local prompt_file="$SCRIPT_DIR/$name"

  if [[ ! -f "$prompt_file" ]]; then
    log "ERROR $name — prompt file not found"
    return 1
  fi

  # Silent no-op if tmux session isn't running
  if ! tmux has-session -t claude 2>/dev/null; then
    log "DEFER $name — tmux session 'claude' not running"
    return 1
  fi

  # Find the Claude pane by current command
  local pane
  pane=$(tmux list-panes -t claude -F '#{pane_id} #{pane_current_command}' \
    | awk '$2=="claude" {print $1; exit}')

  if [[ -z "$pane" ]]; then
    log "DEFER $name — no pane running 'claude' in session 'claude'"
    return 1
  fi

  # Busy check via animating title spinner. When Claude is processing, the
  # pane title shows a braille spinner glyph that animates (e.g. "⠂ Claude
  # Code" → "⠐ Claude Code"). Two snapshots ~400ms apart will differ if
  # Claude is busy. When idle, the title is static.
  #
  # Note: this does NOT catch "user typing while Claude is idle" — checking
  # for that reliably needs cursor-position math against the input box, which
  # is fragile. The spinner check covers "Claude is responding" which is the
  # more common race. If user-typing-while-idle becomes a real problem, add
  # a cursor_x check against the input box rest position.
  local t1 t2
  t1=$(tmux display-message -p -t "$pane" '#{pane_title}')
  sleep 0.4
  t2=$(tmux display-message -p -t "$pane" '#{pane_title}')

  if [[ "$t1" != "$t2" ]]; then
    log "DEFER $name — Claude busy (spinner: '$t1' → '$t2')"
    return 1
  fi

  # Safe to paste
  tmux load-buffer -b bot-cron "$prompt_file"
  tmux paste-buffer -b bot-cron -t "$pane"
  tmux delete-buffer -b bot-cron 2>/dev/null || true
  sleep 0.2
  tmux send-keys -t "$pane" Enter
  return 0
}

# --- queue management ---

queue_prompt() {
  local name="$1"
  local reason="$2"
  # Preserve original timestamp if already queued (don't reset the age clock)
  if [[ ! -f "$QUEUE_DIR/$name" ]]; then
    echo "$(date +%s) $reason" > "$QUEUE_DIR/$name"
  fi
}

drop_stale_queue_items() {
  local now=$(date +%s)
  local item qname qtime age
  for item in "$QUEUE_DIR"/*; do
    [[ -f "$item" ]] || continue
    qname=$(basename "$item")
    qtime=$(awk '{print $1}' "$item")
    age=$((now - qtime))
    if (( age > MAX_QUEUE_AGE )); then
      log "DROPPED $qname — exceeded max age (${age}s)"
      rm -f "$item"
    fi
  done
}

# --- main flow ---

drop_stale_queue_items

# Try queue items first. If any succeed, queue the requested prompt and exit.
for queued in "$QUEUE_DIR"/*; do
  [[ -f "$queued" ]] || continue
  qname=$(basename "$queued")
  qtime=$(awk '{print $1}' "$queued")
  age=$(($(date +%s) - qtime))

  if try_inject "$qname"; then
    log "RETRY $qname succeeded after ${age}s"
    rm -f "$queued"
    # Queue the originally-requested prompt so it doesn't get lost
    if [[ "$REQUESTED" != "$qname" ]]; then
      queue_prompt "$REQUESTED" "preempted by retry of $qname"
    fi
    exit 0
  fi
  # If still deferring, leave it in the queue and try the next item
done

# No queue retries succeeded. Try the originally-requested prompt.
if try_inject "$REQUESTED"; then
  # Success — if this prompt was already in the queue, clear it
  rm -f "$QUEUE_DIR/$REQUESTED"
  exit 0
fi

# Deferred — queue it
queue_prompt "$REQUESTED" "deferred from cron fire"
exit 0
