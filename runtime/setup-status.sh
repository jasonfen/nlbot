#!/bin/bash
# setup-status.sh — probe the actual state of every setup phase on this box,
# compare to setup-state.md Current phase (if it exists), recommend the next step.
#
# Two modes:
#   PRE-SETUP   — no <VAULT>/setup-state.md yet. Probes system prereqs +
#                 bootstrap.md / first-time-setup.md Steps 1–4 progress.
#                 Use this while you're still manually working through
#                 bootstrap.md.
#   POST-SETUP  — <VAULT>/setup-state.md exists. Probes everything above
#                 plus per-phase reality (containers, services, cron, MCP)
#                 and compares to Current phase.
#
# Exit codes:
#   0 — state-file and reality agree (or setup is `done`).
#   1 — discrepancy or pending work; recommendation printed.
#   2 — script can't determine vault location (only happens if you set
#       VAULT explicitly to a bogus path).
#
# The script is read-only — never edits setup-state.md. The recommendation
# is for the human (or the setup-runner subagent) to apply.
#
# Useful invocations:
#   bash runtime/setup-status.sh                    # auto-detect vault from script location
#   BOT_NAME=nlbot bash runtime/setup-status.sh     # tell the script who the bot user will be (pre-setup)
#   VAULT=/home/nlbot/nlbot bash runtime/setup-status.sh  # explicit vault path

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT_DIR:-${VAULT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
SETUP_STATE="$VAULT/setup-state.md"

# --- Helpers -----------------------------------------------------------------

state_value() {
  # Pull a value from setup-state.md: state_value BOT_NAME → "nlbot"
  [ -f "$SETUP_STATE" ] || return
  grep "^- \*\*$1\*\*:" "$SETUP_STATE" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

declared_phase() {
  [ -f "$SETUP_STATE" ] || return
  grep '^Current phase:' "$SETUP_STATE" | head -1 | sed 's/^Current phase: *//; s/[[:space:]]*$//'
}

# Resolve BOT_NAME. Order: env override → setup-state.md Values → $USER fallback.
BOT_NAME="${BOT_NAME:-$(state_value BOT_NAME)}"
BOT_NAME=${BOT_NAME:-$USER}
DECLARED=$(declared_phase)
DECLARED=${DECLARED:-}

# Detect mode
if [ -f "$SETUP_STATE" ]; then
  MODE="POST-SETUP"
else
  MODE="PRE-SETUP"
fi

# Colors only if stdout is a TTY
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
echo "Mode:             $MODE"
echo "Probed at:        $(date '+%Y-%m-%d %H:%M:%S')"
echo "Running as:       $USER"
echo "Bot user:         $BOT_NAME${MODE:+ }"
echo "Vault path:       $VAULT${MODE:+ }"
[ "$MODE" = "POST-SETUP" ] && echo "Declared phase:   ${DECLARED:-(unset)}"
echo

# --- System prerequisites (always probed) ------------------------------------

echo "${B}System prerequisites${N}"
if command -v tmux >/dev/null 2>&1; then
  pass "tmux installed" "($(tmux -V))"
else
  fail "tmux installed" "(bootstrap.md Step 3)"
fi
if command -v claude >/dev/null 2>&1; then
  pass "Claude Code installed" "($(command -v claude))"
else
  fail "Claude Code installed" "(bootstrap.md Step 7: sudo npm install -g @anthropic-ai/claude-code)"
fi
if command -v node >/dev/null 2>&1; then
  NV=$(node --version 2>/dev/null)
  NMAJ=$(echo "$NV" | sed 's/^v\([0-9]*\).*/\1/')
  if [ "${NMAJ:-0}" -ge 20 ]; then
    pass "Node 20+ installed" "($NV)"
  else
    fail "Node 20+ installed" "(found $NV; need v20 or newer)"
  fi
else
  fail "Node 20+ installed" "(bootstrap.md Step 4)"
fi
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    pass "Docker + compose plugin" "($(docker --version | cut -d, -f1))"
  else
    fail "Docker compose plugin" "(legacy docker-compose? need 'docker compose' subcommand)"
  fi
else
  fail "Docker installed" "(bootstrap.md Step 5)"
fi
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    HN=$(tailscale status --json 2>/dev/null | grep -oE '"HostName"[^,]*' | head -1 | cut -d'"' -f4)
    pass "Tailscale up" "(${HN:-logged in})"
  else
    fail "Tailscale up" "(sudo tailscale up)"
  fi
else
  fail "Tailscale installed" "(handled outside the kit; install before bootstrap.md)"
fi
if locale 2>/dev/null | grep -q 'C\.UTF-8\|en_US\.UTF-8'; then
  pass "UTF-8 locale active" "($(locale | grep ^LANG | head -1))"
else
  warn "UTF-8 locale" "(check 'locale' output; needed for glyph rendering in tmux)"
fi
echo

# --- Bot user prerequisites (probed by name) ---------------------------------

echo "${B}Bot user ($BOT_NAME)${N}"
if getent passwd "$BOT_NAME" >/dev/null 2>&1; then
  HOMEDIR=$(getent passwd "$BOT_NAME" | cut -d: -f6)
  pass "user exists" "(home: $HOMEDIR)"

  # Group memberships — check from outside since we may not be that user
  BOT_GROUPS=$(id -nG "$BOT_NAME" 2>/dev/null | tr ' ' '\n')
  if echo "$BOT_GROUPS" | grep -qx sudo; then
    pass "in sudo group"
  else
    fail "in sudo group" "(sudo usermod -aG sudo $BOT_NAME)"
  fi
  if echo "$BOT_GROUPS" | grep -qx docker; then
    pass "in docker group"
    # If we're running AS the bot, also verify the group is live in this login
    if [ "$USER" = "$BOT_NAME" ]; then
      if id -nG | tr ' ' '\n' | grep -qx docker; then
        pass "docker group active in login" "(current session)"
      else
        fail "docker group NOT active in login" "(log out and back in)"
      fi
    fi
  else
    fail "in docker group" "(sudo usermod -aG docker $BOT_NAME)"
  fi

  # SSH key
  if [ -f "$HOMEDIR/.ssh/authorized_keys" ]; then
    pass "ssh authorized_keys present"
  else
    warn "ssh authorized_keys" "(bootstrap.md Step 2c — only matters if you want direct SSH as $BOT_NAME)"
  fi

  # Scoped NOPASSWD
  if [ -f "/etc/sudoers.d/$BOT_NAME" ]; then
    if sudo -n test -r "/etc/sudoers.d/$BOT_NAME" 2>/dev/null || [ -r "/etc/sudoers.d/$BOT_NAME" ]; then
      if grep -q 'NOPASSWD.*systemctl.*crontab.*docker' "/etc/sudoers.d/$BOT_NAME" 2>/dev/null \
         || grep -q 'NOPASSWD: */usr/bin/systemctl, */usr/bin/crontab, */usr/bin/docker' "/etc/sudoers.d/$BOT_NAME" 2>/dev/null \
         || grep -q 'NOPASSWD:ALL' "/etc/sudoers.d/$BOT_NAME" 2>/dev/null; then
        pass "scoped NOPASSWD sudoers" "(/etc/sudoers.d/$BOT_NAME)"
      else
        warn "scoped NOPASSWD sudoers" "(file exists but doesn't match expected pattern; verify with visudo -cf)"
      fi
    else
      warn "scoped NOPASSWD sudoers" "(file exists but can't read it from $USER)"
    fi
  else
    warn "scoped NOPASSWD sudoers" "(grant in first-time-setup.md Step 4 'Final action' — this is the LAST step before reboot, not now)"
  fi
else
  fail "user exists" "(bootstrap.md Step 2 — sudo adduser $BOT_NAME)"
fi
echo

# --- Vault and bot service ---------------------------------------------------

echo "${B}Vault and bot service${N}"
if [ -d "$VAULT" ]; then
  pass "vault directory exists" "($VAULT)"
  if [ -f "$VAULT/CLAUDE.md" ]; then
    pass "CLAUDE.md present"
  else
    fail "CLAUDE.md present" "(first-time-setup.md Step 2)"
  fi
  if [ -d "$VAULT/.claude" ]; then
    pass ".claude/ dir present" "(renamed from dot-claude/)"
  else
    fail ".claude/ dir present" "(first-time-setup.md Step 2 — the dot-claude → .claude rename)"
  fi
  if [ -f "$VAULT/identity.md" ] && [ -f "$VAULT/user-profile.md" ]; then
    pass "identity.md + user-profile.md present"
  else
    fail "identity.md + user-profile.md" "(first-time-setup.md Step 2)"
  fi
else
  fail "vault directory exists" "(not yet — first-time-setup.md Step 2 creates it)"
fi
if [ -f /etc/systemd/system/claude-code.service ]; then
  pass "claude-code.service unit installed"
  if systemctl is-active claude-code.service >/dev/null 2>&1; then
    pass "claude-code.service active"
  else
    fail "claude-code.service active" "(first-time-setup.md Step 4: sudo systemctl enable --now claude-code.service)"
  fi
else
  fail "claude-code.service unit" "(first-time-setup.md Step 4)"
fi
if tmux has-session -t claude 2>/dev/null; then
  pass "tmux session 'claude' running"
elif sudo -n -u "$BOT_NAME" tmux has-session -t claude 2>/dev/null; then
  pass "tmux session 'claude' running (as $BOT_NAME)"
else
  fail "tmux session 'claude'" "(starts when claude-code.service runs)"
fi
echo

# --- POST-SETUP only: phases ------------------------------------------------

REACHED=""
if [ "$MODE" = "POST-SETUP" ]; then
  echo "${B}Bot-driven setup phases${N}"

  # step-5-silverbullet
  if [ -f "$VAULT/docker-compose.yml" ] && docker compose -f "$VAULT/docker-compose.yml" ps silverbullet 2>/dev/null | grep -q running; then
    if sudo -n tailscale serve status 2>/dev/null | grep -q 3001; then
      pass "step-5-silverbullet" "container + tailscale serve"
    else
      warn "step-5-silverbullet" "container running but no tailscale serve to 3001"
    fi
    REACHED="step-5-silverbullet"
  else
    fail "step-5-silverbullet" "container not running"
  fi

  # step-6 trio
  if [ -f /etc/systemd/system/telegram-bot.service ]; then
    pass "step-6-telegram-daemon" "systemd unit installed"
    REACHED="step-6-telegram-daemon"
    if [ -n "$(state_value TG_BOT_TOKEN)" ]; then
      pass "step-6-telegram-creds" "TG_BOT_TOKEN populated"
      REACHED="step-6-telegram-creds-resolved"
    else
      warn "step-6-telegram-creds" "BLOCKER pending: BotFather token"
    fi
    if systemctl is-active telegram-bot.service >/dev/null 2>&1; then
      pass "step-6-telegram-activate" "service active"
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
    warn "step-9-memory" "non-memorious memory backend (treating as done)"
    REACHED="step-9-memory"
  else
    fail "step-9-memory" "no memory backend"
  fi
  echo
fi

# --- Recommendation ---------------------------------------------------------

echo "${B}=== Recommendation ===${N}"

# Detect bootstrap progress for pre-bot recommendation
NEED_BOOTSTRAP=""
if ! command -v claude >/dev/null 2>&1; then NEED_BOOTSTRAP="bootstrap.md Step 7 (install Claude Code)"; fi
if [ -z "$NEED_BOOTSTRAP" ] && ! getent passwd "$BOT_NAME" >/dev/null 2>&1; then
  NEED_BOOTSTRAP="bootstrap.md Step 2 (create bot user '$BOT_NAME')"
fi
if [ -z "$NEED_BOOTSTRAP" ] && ! command -v docker >/dev/null 2>&1; then
  NEED_BOOTSTRAP="bootstrap.md Step 5 (Docker)"
fi
if [ -z "$NEED_BOOTSTRAP" ] && command -v tailscale >/dev/null && ! tailscale status >/dev/null 2>&1; then
  NEED_BOOTSTRAP="Tailscale: 'sudo tailscale up'"
fi
NEED_FIRSTTIME=""
if [ -z "$NEED_BOOTSTRAP" ] && [ ! -d "$VAULT" -o ! -f "$VAULT/CLAUDE.md" ]; then
  NEED_FIRSTTIME="first-time-setup.md Step 2 (drop in the vault)"
fi
if [ -z "$NEED_BOOTSTRAP$NEED_FIRSTTIME" ] && [ ! -f /etc/systemd/system/claude-code.service ]; then
  NEED_FIRSTTIME="first-time-setup.md Step 4 (install claude-code.service)"
fi
if [ -z "$NEED_BOOTSTRAP$NEED_FIRSTTIME" ] && ! systemctl is-active claude-code.service >/dev/null 2>&1; then
  NEED_FIRSTTIME="first-time-setup.md Step 4 (enable + start the service, reboot)"
fi
if [ -z "$NEED_BOOTSTRAP$NEED_FIRSTTIME" ] && [ ! -f "/etc/sudoers.d/$BOT_NAME" ]; then
  NEED_FIRSTTIME="first-time-setup.md Step 4 final action (scoped NOPASSWD sudoers — last step before reboot)"
fi

if [ -n "$NEED_BOOTSTRAP" ]; then
  echo "Mode:                 PRE-SETUP (still in bootstrap.md)"
  echo "Next manual step:     $NEED_BOOTSTRAP"
  echo
  echo "${Y}You're not at the bot-driven phase yet. Complete bootstrap.md, then first-time-setup.md Steps 1–4, then the bot wakes up and finishes Steps 5–9 itself.${N}"
  exit 1
fi
if [ -n "$NEED_FIRSTTIME" ]; then
  echo "Mode:                 PRE-SETUP (in first-time-setup.md Steps 1–4)"
  echo "Next manual step:     $NEED_FIRSTTIME"
  echo
  echo "${Y}Once the service is active and you've rebooted, the bot wakes up and drives Steps 5–9 itself.${N}"
  exit 1
fi

# At this point bootstrap is done and first-time-setup Steps 1–4 are done.
# If we're in POST-SETUP mode, recommend based on phase reached.
if [ "$MODE" = "PRE-SETUP" ]; then
  echo "Mode:                 PRE-SETUP (but ready for first bot wake-up)"
  echo "All system prereqs and vault/service look good. The bot should be running."
  echo "Next: check 'tmux attach -t claude' and verify the bot is in its first soul-loop."
  exit 1
fi

# POST-SETUP recommendation
echo "Mode:                 POST-SETUP"
echo "setup-state.md says:  Current phase: ${DECLARED:-(unset)}"
echo "Reality reached:      ${REACHED:-pre-step-5}"
echo

# All-done case
if [ "$REACHED" = "step-9-memory" ] && \
   systemctl is-active "${BOT_NAME}-web.service" >/dev/null 2>&1 && \
   sudo -n crontab -u "$BOT_NAME" -l 2>/dev/null | grep -q inject-prompt.sh; then
  if [ "$DECLARED" = "done" ]; then
    echo "${G}✓ Aligned. Setup is complete; no action needed.${N}"
    exit 0
  else
    echo "${Y}Reality shows all phases complete. Recommend setting Current phase to 'done'.${N}"
    exit 1
  fi
fi

# Compute next-phase suggestion. `phase-0` is the legacy alias of `pre-step-5`
# kept for back-compat with kits seeded before the schema collapse.
case "${REACHED:-pre-step-5}" in
  "phase-0"|"pre-step-5"|"")          NEXT="step-5-silverbullet" ;;
  "step-5-silverbullet")              NEXT="step-6-telegram-daemon" ;;
  "step-6-telegram-daemon")           NEXT="step-6-telegram-creds-blocker" ;;
  "step-6-telegram-creds-resolved")   NEXT="step-6-telegram-activate" ;;
  "step-6-telegram-activate")         NEXT="step-7-web-shell" ;;
  "step-7-web-shell")                 NEXT="step-8-cron" ;;
  "step-8-cron")                      NEXT="step-9-memory" ;;
  *)                                  NEXT="${REACHED}" ;;
esac

echo "Recommended next:     $NEXT"
echo

if [ "$DECLARED" = "$NEXT" ]; then
  echo "${G}✓ Declared phase matches next-to-run. Run /setup (or wait for next soul-loop) to execute.${N}"
else
  echo "${Y}! Declared phase ($DECLARED) doesn't match reality ($NEXT).${N}"
  echo "  To resync: edit $SETUP_STATE → 'Current phase: $NEXT' → run /setup."
fi

exit 1
