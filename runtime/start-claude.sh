#!/bin/bash
# Guard: exit silently if the claude tmux session already exists
if tmux has-session -t claude 2>/dev/null; then
    exit 0
fi

export LANG=C.utf8
export PATH="$HOME/.local/bin:$PATH"

# Start Claude in a detached tmux session.
# Use --continue (auto-selects most recent session, no interactive picker)
# instead of --resume main (which can hit the Ink TUI picker if session list
# is ambiguous — the picker doesn't respond to tmux send-keys, blocking
# unattended startup). See decisions.md 2026-04-03 lockup.
tmux new-session -d -s claude -c <VAULT> $HOME/.local/bin/claude --permission-mode bypassPermissions --continue
# Set pane title to bot hostname — watcher scripts use this to target the right pane
tmux select-pane -t claude:0.0 -T "natebot"
