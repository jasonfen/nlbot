#!/bin/bash
# Guard: exit silently if the claude tmux session already exists
if tmux has-session -t claude 2>/dev/null; then
    exit 0
fi

export LANG=C.utf8
export LC_ALL=C.utf8
# Cover both per-user (npm install without sudo) and global-install paths
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH"

# Verify the prereqs the bot needs to self-drive Steps 5-9 of setup
# (docker group active, scoped sudo NOPASSWD entries, tailscale up, claude
# binary resolvable). Fail loud here rather than silently at Step 5.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "$SCRIPT_DIR/setup-bootstrap.sh" ]; then
  "$SCRIPT_DIR/setup-bootstrap.sh" || exit 1
fi

# Resolve the actual claude binary location. Works for `sudo npm install -g`
# (typically /usr/bin/claude or /usr/local/bin/claude) and for per-user
# `npm install --prefix ~/.local` (~/.local/bin/claude).
CLAUDE_BIN="$(command -v claude)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "claude not found in PATH ($PATH)" >&2
  exit 1
fi

# Start Claude in a detached tmux session.
#
# Use --continue (auto-selects most recent session, no interactive picker)
# instead of --resume main (which can hit the Ink TUI picker if session list
# is ambiguous — the picker doesn't respond to tmux send-keys, blocking
# unattended startup). See decisions.md 2026-04-03 lockup.
#
# Wrap the claude invocation in a while-loop with exponential backoff so
# the tmux session survives a clean exit of `claude` itself (e.g., when
# --continue finds nothing to resume on a fresh OAuth walk, claude can
# exit 0 immediately — without the wrapper, tmux closes the session
# because its only command exited, and the bot disappears until the
# operator manually restarts claude-code.service). The systemd unit's
# Restart=on-failure can't recover this because exit-0 isn't a failure.
# Caught on nlbot0 walk (sidechat msg 2728, F21).
#
# Backoff: 5s → 10s → 20s → 40s → 80s → 160s → 300s (capped). Prevents a
# tight loop on persistent failure (bad OAuth state, missing binary mid-
# upgrade) while still recovering quickly from a one-shot exit.
export CLAUDE_BIN
tmux new-session -d -s claude -c <VAULT> /bin/bash -c '
  delay=5
  max_delay=300
  while :; do
    "$CLAUDE_BIN" --permission-mode bypassPermissions --continue
    rc=$?
    echo "[start-claude] claude exited rc=$rc; restarting in ${delay}s" >&2
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$max_delay" ] && delay=$max_delay
  done
'
# Set pane title to bot name — watcher scripts use this to target the right pane
tmux select-pane -t claude:0.0 -T "<BOT_NAME>"
