#!/bin/bash
# Guard: exit silently if the claude tmux session already exists
if tmux has-session -t claude 2>/dev/null; then
    exit 0
fi

export LANG=C.utf8
export LC_ALL=C.utf8
# Cover both per-user (npm install without sudo) and global-install paths
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH"

# Resolve the actual claude binary location. Works for `sudo npm install -g`
# (typically /usr/bin/claude or /usr/local/bin/claude) and for per-user
# `npm install --prefix ~/.local` (~/.local/bin/claude).
CLAUDE_BIN="$(command -v claude)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "claude not found in PATH ($PATH)" >&2
  exit 1
fi

# Start Claude in a detached tmux session.
# Use --continue (auto-selects most recent session, no interactive picker)
# instead of --resume main (which can hit the Ink TUI picker if session list
# is ambiguous — the picker doesn't respond to tmux send-keys, blocking
# unattended startup). See decisions.md 2026-04-03 lockup.
tmux new-session -d -s claude -c <VAULT> "$CLAUDE_BIN" --permission-mode bypassPermissions --continue
# Set pane title to bot name — watcher scripts use this to target the right pane
tmux select-pane -t claude:0.0 -T "<BOT_NAME>"
