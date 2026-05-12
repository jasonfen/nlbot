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
# **Conditional --continue (F38, fenbot00 walk 2026-05-12):** on a *truly*
# fresh box (post-OAuth walk, zero prior conversation history), `claude
# --continue` exits rc=1 with "No conversation found to continue" instantly.
# The while-loop wrapper would then respawn into the same wall, so each
# claude-code.service restart crashloops indefinitely until a human types
# something into the pane to create a session. The fix is to check for
# session files inside $HOME/.claude/projects/ and only pass --continue
# when at least one exists. The check is inside the loop body so a
# brand-new box converges naturally: first iteration runs plain `claude`
# (creates a session as soon as a user prompts), subsequent iterations
# pick up --continue.
#
# Wrap the claude invocation in a while-loop with exponential backoff so
# the tmux session survives a clean exit of `claude` itself. The systemd
# unit's Restart=on-failure can't recover an exit-0 because exit-0 isn't
# a failure. Caught on nlbot0 walk (sidechat msg 2728, F21).
#
# Backoff: 5s → 10s → 20s → 40s → 80s → 160s → 300s (capped). Prevents a
# tight loop on persistent failure (bad OAuth state, missing binary mid-
# upgrade) while still recovering quickly from a one-shot exit.
export CLAUDE_BIN
# `set -m` enables job control inside the wrapper. Without it, a
# non-interactive `bash -c` invocation runs every child in the SAME
# process group as bash itself — so when claude runs as a child, bash
# stays the pgroup leader and `tmux pane_current_command` reports
# `bash`, not `claude`. inject-prompt.sh's pane selector filters for
# `pane_current_command == claude`, which then never matches and every
# cron fire defers indefinitely (F29 regression of F21, caught on
# nlbot0 sidechat msg 2759). With `set -m`, each command in the loop
# becomes its own pgroup leader → claude is the leader during its run
# → tmux reports `claude` → injector finds the pane.
tmux new-session -d -s claude -c <VAULT> /bin/bash -c '
  set -m
  delay=5
  max_delay=300
  while :; do
    flags=(--permission-mode bypassPermissions)
    # Add --continue only when there is a real session to resume IN THIS
    # cwd. Project dirs under ~/.claude/projects/ encode the cwd into
    # the directory name by replacing every / with -, so
    # /home/foo/bar/vault becomes -home-foo-bar-vault. The first F38
    # cut (eceb580) checked for any *.jsonl anywhere under projects/,
    # which let an OAuth-time session from cwd=~ pass the gate while
    # the systemd-launched claude (cwd=<VAULT>) was looking in a
    # different project dir; --continue then exited rc=1 with "No
    # conversation found to continue" and the bot crashlooped exactly
    # the same way the original F38 bug did, just one layer deeper.
    # Caught on fenbot01 walk 2026-05-12. The scoped check below
    # matches the actual project dir claude itself would open. (Avoid
    # apostrophes anywhere in this whole bash -c body — single-quoted
    # to the outer shell, any literal apostrophe terminates it early.)
    proj_dir="$HOME/.claude/projects/$(printf %s "$PWD" | tr / -)"
    if [ -d "$proj_dir" ] && \
       find "$proj_dir" -name "*.jsonl" -print -quit 2>/dev/null | grep -q .; then
      flags+=(--continue)
    fi
    "$CLAUDE_BIN" "${flags[@]}"
    rc=$?
    echo "[start-claude] claude exited rc=$rc; restarting in ${delay}s" >&2
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$max_delay" ] && delay=$max_delay
  done
'
# Set pane title to bot name — watcher scripts use this to target the right pane
tmux select-pane -t claude:0.0 -T "<BOT_NAME>"
