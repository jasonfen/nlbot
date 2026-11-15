#!/bin/bash
# Guard: exit silently if the claude tmux session already exists
if tmux has-session -t claude 2>/dev/null; then
    exit 0
fi

export LANG=C.utf8
export PATH="$HOME/.local/bin:$PATH"

# MCP startup budget. Default is 30s, which a COLD `uvx` environment blows:
# at the 2026-09-22 post-move boot, memorious-mcp had to fetch and install 122
# packages (grpcio 6.8MiB among them) and the client gave up at 30001ms, so the
# whole session ran with no recall/store while the server itself was healthy
# (warm starts are ~1.5s). See the mcp-logs jsonl for that boot. Per-server
# "timeout" is also set on memorious-mcp in ~/.claude.json; this covers the rest.
export MCP_TIMEOUT=120000

# Update before launch. The session runs for days and releases land every day
# or two, so without this every boot started on the previous download and the
# auto-updater fetched the next one ~13s later ("Restart to update" straight
# away; 2026-09-26 boot: launched 2.1.281, 2.1.283 landed at +13s). Bounded
# and non-fatal so a slow or failed update never blocks startup.
timeout 120 ${HOME_DIR}/.local/bin/claude update >/dev/null 2>&1 || true

# Start Claude in a detached tmux session.
# Use --continue (auto-selects most recent session, no interactive picker)
# instead of --resume main (which can hit the Ink TUI picker if session list
# is ambiguous — the picker doesn't respond to tmux send-keys, blocking
# unattended startup). See decisions.md 2026-04-03 lockup.
tmux new-session -d -s claude -c ${VAULT_DIR} ${HOME_DIR}/.local/bin/claude --permission-mode bypassPermissions --continue
# Set pane title to bot hostname — watcher scripts use this to target the right pane
tmux select-pane -t claude:0.0 -T "${BOT_NAME}"

# --- Boot nudge: arm the cron wake path without a human poke ---
# The listener (cron-trigger-monitor) runs as a session-scoped background task,
# which only an AGENT TURN can arm — a hook can't. A --continue'd
# session resumes idle and waits for input, so the listener stayed down until a
# human messaged. This sends one `/start` once the TUI is ready to trigger that
# arming turn. Backgrounded so this launcher returns promptly for systemd
# (Type=forking); only reached on a genuinely fresh session (the has-session
# guard at the top already exited otherwise). Verifies + retries so a slow TUI
# init or a dropped keystroke self-heals; gives up quietly after 3 tries.
(
  armed() { pgrep -f 'cron-trigger-monitor\.sh' >/dev/null 2>&1; }
  # 1. Wait up to ~60s for the TUI to accept input (best-effort; falls through).
  for i in $(seq 1 30); do
    sleep 2
    tmux capture-pane -pt claude:0.0 2>/dev/null | grep -q '❯' && break
  done
  # 2. Nudge, then PATIENTLY poll for the arm turn to land before re-sending.
  #    Boot-to-first-turn latency routinely exceeds a short retry gap, so a fast
  #    re-send just stacks unprocessed nudges into one turn (found on a real
  #    reboot, 2026-08-12) — the pgrep verify never gets to gate. So after each
  #    send we poll every 10s for up to ~4min; a second send only fires if the
  #    poller is GENUINELY still down (dropped keystroke), not merely slow.
  for attempt in 1 2; do
    armed && break
    tmux send-keys -t claude:0.0 '/start'
    sleep 1
    tmux send-keys -t claude:0.0 Enter
    for j in $(seq 1 24); do sleep 10; armed && break; done
  done
) >/dev/null 2>&1 &
