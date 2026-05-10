#!/bin/bash
# setup-status.sh — probe the actual state of every setup phase on this box,
# compare to setup-state.md Current phase, recommend the next step.
#
# Use this when:
#   - You want a snapshot of what's actually installed/running.
#   - setup-state.md looks out of sync with reality (manual edit, crashed
#     mid-phase, you moved the vault to a new box).
#   - You just want to know "where am I in setup" without reading the file.
#
# Exit codes:
#   0 — state-file and reality agree (or setup is `done`).
#   1 — discrepancy or pending work; recommendation printed.
#   2 — can't read setup-state.md (no vault detected).
#
# The script is read-only — never edits setup-state.md. The recommendation
# is for the human (or the setup-runner subagent) to apply.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT_DIR:-${VAULT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
SETUP_STATE="$VAULT/setup-state.md"

if [ ! -f "$SETUP_STATE" ]; then
  echo "setup-status: $SETUP_STATE not found." >&2
  echo "  Set VAULT=/path/to/vault or run this script from inside the vault." >&2
  exit 2
fi

# --- Helpers -----------------------------------------------------------------

state_value() {
  # Pull a value from setup-state.md: state_value BOT_NAME → "nlbot"
  grep "^- \*\*$1\*\*:" "$SETUP_STATE" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

declared_phase() {
  grep '^Current phase:' "$SETUP_STATE" | head -1 | sed 's/^Current phase: *//; s/[[:space:]]*$//'
}

BOT_NAME=$(state_value BOT_NAME)
BOT_NAME=${BOT_NAME:-$USER}
DECLARED=$(declared_phase)
DECLARED=${DECLARED:-phase-0}

# Use colors only if stdout is a TTY
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

pass() { printf "  [%s✓%s] %-38s %s\n" "$G" "$N" "$1" "${2:-}"; }
fail() { printf "  [%s✗%s] %-38s %s\n" "$R" "$N" "$1" "${2:-}"; }
warn() { printf "  [%s!%s] %-38s %s\n" "$Y" "$N" "$1" "${2:-}"; }

# --- Header ------------------------------------------------------------------

echo "${B}=== nlbot setup state probe ===${N}"
echo "Probed at:        $(date '+%Y-%m-%d %H:%M:%S')"
echo "Vault:            $VAULT"
echo "Bot user:         $BOT_NAME"
echo "Declared phase:   $DECLARED"
echo

# --- Prerequisites -----------------------------------------------------------

echo "${B}Prerequisites${N}"
if id -nG | tr ' ' '\n' | grep -qx docker; then
  pass "docker group active" "(in current login)"
else
  fail "docker group NOT active" "(log out/in or restart claude-code.service)"
fi
for cmd in /usr/bin/systemctl /usr/bin/crontab /usr/bin/docker; do
  short=$(basename "$cmd")
  if sudo -n "$cmd" --version >/dev/null 2>&1; then
    pass "sudo NOPASSWD $short"
  else
    fail "sudo NOPASSWD $short" "(see first-time-setup.md Step 4 final action)"
  fi
done
if command -v tmux >/dev/null 2>&1; then
  pass "tmux installed" "($(tmux -V))"
else
  fail "tmux installed" "(apt install tmux)"
fi
if command -v claude >/dev/null 2>&1; then
  pass "claude in PATH" "($(command -v claude))"
else
  fail "claude in PATH" "(sudo npm install -g @anthropic-ai/claude-code)"
fi
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    HN=$(tailscale status --json 2>/dev/null | grep -oE '"HostName"[^,]*' | head -1 | cut -d'"' -f4)
    pass "tailscale up" "(${HN:-logged in})"
  else
    fail "tailscale up" "(sudo tailscale up)"
  fi
else
  fail "tailscale installed" ""
fi
echo

# --- Phases ------------------------------------------------------------------

echo "${B}Phases${N}"
REACHED="phase-0"

# pre-step-5: vault + claude-code.service + tmux session + dot-claude
pre_vault=fail; [ -d "$VAULT" ] && [ -f "$VAULT/CLAUDE.md" ] && [ -d "$VAULT/.claude" ] && pre_vault=ok
pre_service=fail; systemctl is-active claude-code.service >/dev/null 2>&1 && pre_service=ok
pre_tmux=fail; tmux has-session -t claude 2>/dev/null && pre_tmux=ok
if [ "$pre_vault" = ok ] && [ "$pre_service" = ok ] && [ "$pre_tmux" = ok ]; then
  pass "pre-step-5" "vault+service+tmux all up"
  REACHED="pre-step-5"
else
  fail "pre-step-5" "vault=$pre_vault service=$pre_service tmux=$pre_tmux"
fi

# step-5-silverbullet
sb_ok=fail
if [ -f "$VAULT/docker-compose.yml" ] && docker compose -f "$VAULT/docker-compose.yml" ps silverbullet 2>/dev/null | grep -q running; then
  sb_ok=ok
fi
if [ "$sb_ok" = ok ]; then
  if sudo -n tailscale serve status 2>/dev/null | grep -q 3001; then
    pass "step-5-silverbullet" "container running; tailscale serve on 443→3001"
  else
    warn "step-5-silverbullet" "container running but no tailscale serve to 3001"
  fi
  REACHED="step-5-silverbullet"
else
  fail "step-5-silverbullet" "container not running"
fi

# step-6-telegram-daemon (systemd unit installed)
tg_unit=fail; [ -f /etc/systemd/system/telegram-bot.service ] && tg_unit=ok
if [ "$tg_unit" = ok ]; then
  pass "step-6-telegram-daemon" "systemd unit installed"
  REACHED="step-6-telegram-daemon"
  # creds populated in setup-state.md?
  tg_token=$(state_value TG_BOT_TOKEN)
  if [ -n "$tg_token" ]; then
    pass "step-6-telegram-creds" "TG_BOT_TOKEN populated in setup-state.md"
    REACHED="step-6-telegram-creds-resolved"
  else
    warn "step-6-telegram-creds" "BLOCKER pending: BotFather token missing"
  fi
  # service active?
  if systemctl is-active telegram-bot.service >/dev/null 2>&1; then
    pass "step-6-telegram-activate" "telegram-bot.service active"
    REACHED="step-6-telegram-activate"
  else
    fail "step-6-telegram-activate" "service inactive"
  fi
else
  fail "step-6-telegram-daemon" "no systemd unit"
fi

# step-7-web-shell
if systemctl is-active "${BOT_NAME}-web.service" >/dev/null 2>&1; then
  pass "step-7-web-shell" "${BOT_NAME}-web.service active"
  REACHED="step-7-web-shell"
else
  fail "step-7-web-shell" "${BOT_NAME}-web.service not active"
fi

# step-8-cron
if sudo -n crontab -u "$BOT_NAME" -l 2>/dev/null | grep -q inject-prompt.sh; then
  pass "step-8-cron" "heartbeat entries installed"
  REACHED="step-8-cron"
else
  fail "step-8-cron" "no inject-prompt.sh in crontab"
fi

# step-9-memory
if command -v claude >/dev/null 2>&1 && claude mcp list 2>/dev/null | grep -q memorious; then
  pass "step-9-memory" "memorious-mcp registered"
  REACHED="step-9-memory"
elif command -v claude >/dev/null 2>&1 && claude mcp list 2>/dev/null | grep -qi memor; then
  warn "step-9-memory" "non-memorious memory backend registered (treating as done)"
  REACHED="step-9-memory"
else
  fail "step-9-memory" "no memory backend registered"
fi

echo

# --- Recommendation ----------------------------------------------------------

echo "${B}=== Recommendation ===${N}"
echo "setup-state.md says:  Current phase: $DECLARED"
echo "Reality reached:      $REACHED"

# If everything probed as done, recommend `done` regardless of declared phase
if [ "$REACHED" = "step-9-memory" ] && \
   systemctl is-active "${BOT_NAME}-web.service" >/dev/null 2>&1 && \
   sudo -n crontab -u "$BOT_NAME" -l 2>/dev/null | grep -q inject-prompt.sh; then
  if [ "$DECLARED" = "done" ]; then
    echo
    echo "${G}✓ Aligned. Setup is complete; no action needed.${N}"
    exit 0
  else
    echo
    echo "Reality shows all phases complete. Recommend setting Current phase to 'done'."
    exit 1
  fi
fi

# Otherwise compute next-phase suggestion based on what's actually done
case "$REACHED" in
  "phase-0")                          NEXT="pre-step-5" ;;
  "pre-step-5")                       NEXT="step-5-silverbullet" ;;
  "step-5-silverbullet")              NEXT="step-6-telegram-daemon" ;;
  "step-6-telegram-daemon")           NEXT="step-6-telegram-creds-blocker" ;;
  "step-6-telegram-creds-resolved")   NEXT="step-6-telegram-activate" ;;
  "step-6-telegram-activate")         NEXT="step-7-web-shell" ;;
  "step-7-web-shell")                 NEXT="step-8-cron" ;;
  "step-8-cron")                      NEXT="step-9-memory" ;;
  *)                                  NEXT="$REACHED" ;;
esac

echo "Recommended next:     $NEXT"
echo

if [ "$DECLARED" = "$NEXT" ]; then
  echo "${G}✓ Declared phase matches the next-to-run phase. Run /setup (or wait for next soul-loop) to execute it.${N}"
else
  echo "${Y}! Declared phase ($DECLARED) doesn't match reality ($NEXT).${N}"
  echo "  To resync: edit $SETUP_STATE → 'Current phase: $NEXT' → run /setup."
fi

exit 1
