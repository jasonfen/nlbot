#!/bin/bash
# Sanity-check prereqs the bot needs to drive Steps 5-9 of first-time-setup.md
# automatically (Docker group active, scoped sudo NOPASSWD entries working).
# Invoked by start-claude.sh before the tmux session opens. Fail loud here —
# silent docker-permission or sudo errors at Step 5 are much worse than a
# clear startup gate.

set -u
FAIL=0

# 1. Docker group active in this login session?
#    Group membership is read at login. If `usermod -aG docker` happened
#    after the bot user's first shell, the group isn't live until the
#    next login. Verify via `id`, not `groups` (which can lie under sudo).
if ! id -nG | tr ' ' '\n' | grep -qx docker; then
  echo "[setup-bootstrap] FAIL: docker group not active in this login." >&2
  echo "  Fix: log the bot user out and back in, then restart claude-code.service:" >&2
  echo "    sudo systemctl restart claude-code.service" >&2
  echo "  (Run 'id' to confirm 'docker' appears in your groups after relogin.)" >&2
  FAIL=1
fi

# 2. Scoped sudo NOPASSWD entries present? Check the three commands
#    setup-runner uses: systemctl, crontab, docker.
for cmd in /usr/bin/systemctl /usr/bin/crontab /usr/bin/docker; do
  if ! sudo -n "$cmd" --version >/dev/null 2>&1; then
    echo "[setup-bootstrap] WARN: 'sudo -n $cmd' failed (no NOPASSWD entry?)" >&2
    echo "  Fix: see first-time-setup.md Step 4 'Final action: grant the bot scoped sudo NOPASSWD'." >&2
    echo "  Quick fix from a shell with normal sudo:" >&2
    echo "    sudo tee /etc/sudoers.d/$USER >/dev/null <<EOF" >&2
    echo "    $USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/crontab, /usr/bin/docker" >&2
    echo "    EOF" >&2
    echo "    sudo chmod 440 /etc/sudoers.d/$USER" >&2
    FAIL=1
  fi
done

# 3. tmux installed?
if ! command -v tmux >/dev/null 2>&1; then
  echo "[setup-bootstrap] FAIL: tmux not installed." >&2
  echo "  Fix: sudo apt install -y tmux (bootstrap.md Step 3)." >&2
  FAIL=1
fi

# 4. Tailscale up? (Not fatal — setup-runner can post a BLOCKER instead,
#    but warn early so the human knows.)
if command -v tailscale >/dev/null 2>&1; then
  if ! tailscale status >/dev/null 2>&1; then
    echo "[setup-bootstrap] WARN: tailscale installed but not up. 'sudo tailscale up' before setup-runner reaches Step 5." >&2
  fi
else
  echo "[setup-bootstrap] WARN: tailscale not installed. Step 5 needs it for the SilverBullet HTTPS proxy." >&2
fi

# 5. Claude binary resolvable?
if ! command -v claude >/dev/null 2>&1; then
  echo "[setup-bootstrap] FAIL: 'claude' not in PATH ($PATH)." >&2
  echo "  Fix: bootstrap.md Step 7 — 'sudo npm install -g @anthropic-ai/claude-code'." >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "[setup-bootstrap] One or more prereqs failed. Aborting bot startup." >&2
  exit 1
fi

echo "[setup-bootstrap] All prereqs OK." >&2

# Optional: print a one-line state summary using setup-status.sh
# (skip if the script isn't present or setup-state.md doesn't exist)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_SCRIPT="$SCRIPT_DIR/setup-status.sh"
if [ -x "$STATUS_SCRIPT" ]; then
  STATUS_OUT=$("$STATUS_SCRIPT" 2>/dev/null | grep -E '^(Declared phase:|Reality reached:|Recommended next:|✓ Aligned|! Declared)' || true)
  if [ -n "$STATUS_OUT" ]; then
    echo "[setup-bootstrap] State summary:" >&2
    echo "$STATUS_OUT" | sed 's/^/  /' >&2
  fi
fi

exit 0
