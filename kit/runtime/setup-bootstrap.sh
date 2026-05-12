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
#
# This is intentionally a WARN-not-FAIL. The kit policy is "grant NOPASSWD
# as the LAST action before the verification reboot, after you've confirmed
# claude-code.service starts cleanly and the tmux session is healthy." If
# we hard-failed here, the service couldn't start to be verified, and the
# user couldn't get to the point where granting NOPASSWD is appropriate.
#
# Once NOPASSWD is in place + the box is rebooted, setup-runner's
# step-N branches need these scopes and they'll fail loudly if missing.
# So the bot catches it at the right layer.
NOPASSWD_MISSING=0
for cmd in /usr/bin/systemctl /usr/bin/crontab /usr/bin/docker; do
  if ! sudo -n "$cmd" --version >/dev/null 2>&1; then
    NOPASSWD_MISSING=1
  fi
done
if [ "$NOPASSWD_MISSING" -eq 1 ]; then
  echo "[setup-bootstrap] WARN: scoped NOPASSWD sudoers not yet granted." >&2
  echo "  This is expected on first-time-setup pre-reboot. The bot will" >&2
  echo "  refuse to drive Steps 5-9 until you grant it (last action before" >&2
  echo "  reboot — see first-time-setup.md Step 4 'Final action')." >&2
fi

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
