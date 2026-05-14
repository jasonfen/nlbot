#!/bin/bash
# setup-status.sh — probe the actual state of every setup phase on this box,
# compare to setup-state.md Current phase (if it exists), recommend the next step.
#
# Two modes:
#   PRE-SETUP   — no <REPO_ROOT>/setup-state.md yet. Probes system prereqs
#                 + bootstrap.md / first-time-setup.md Steps 1–4 progress.
#                 Use this while you're still manually working through
#                 bootstrap.md.
#   POST-SETUP  — <REPO_ROOT>/setup-state.md exists. Probes everything
#                 above plus per-phase reality (containers, services,
#                 cron, MCP) and compares to Current phase.
#
# Exit codes:
#   0 — state-file and reality agree (or setup is `done`, or --apply
#       resolved the drift).
#   1 — discrepancy or pending work; recommendation printed.
#   2 — script can't determine vault location (only happens if you set
#       VAULT explicitly to a bogus path).
#
# Default mode is read-only — the script prints a recommendation and
# the human (or the setup-runner subagent) applies it. Pass --apply to
# let the script rewrite setup-state.md's `Current phase:` line itself
# when declared and reality disagree. `Last updated:` is bumped to match.
#
# Useful invocations:
#   bash runtime/setup-status.sh                    # read-only probe
#   bash runtime/setup-status.sh --apply            # probe + auto-resync state-file
#   BOT_NAME=nlbot bash runtime/setup-status.sh     # tell the script who the bot user will be (pre-setup)
#   VAULT=/home/nlbot/nlbot bash runtime/setup-status.sh  # explicit vault path

set -u

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT=$(cd "$SCRIPT_DIR/.." && pwd)            # kit/runtime/ → kit/
REPO_ROOT=$(cd "$KIT/.." && pwd)             # kit/ → repo root
VAULT="${VAULT_DIR:-${VAULT:-$REPO_ROOT/vault}}"
SETUP_STATE="$REPO_ROOT/setup-state.md"

# Atomically rewrite the `Current phase:` line and bump `Last updated:`.
# Called from the POST-SETUP recommendation block when --apply is set.
apply_phase() {
  local new_phase="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M')"
  # Use a temp file so a partial write never corrupts state.
  local tmp
  tmp="$(mktemp "${SETUP_STATE}.XXXXXX")"
  awk -v ph="$new_phase" -v ts="$ts" '
    /^Current phase:/ { print "Current phase: " ph; next }
    /^Last updated:/  { print "Last updated: " ts;  next }
    { print }
  ' "$SETUP_STATE" > "$tmp" && mv "$tmp" "$SETUP_STATE"
}

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
# fail() also captures the FIRST failing phase name into FIRST_FAIL, so the
# recommendation block can suggest "go back and fix this" even when later
# phases coincidentally completed. The `${VAR:=val}` form only sets if VAR
# is currently empty — subsequent fails don't overwrite the earliest one.
fail() {
  printf "  [%s✗%s] %-38s %s\n" "$R" "$N" "$1" "${2:-}"
  : "${FIRST_FAIL:=$1}"
}
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
# Locale probe must accept both the canonical hyphenated form
# (`C.UTF-8`) and Debian's lowercase short form (`C.utf8`) — they're
# aliases for the same locale and the kit's systemd unit Environment
# lines use the short form (LANG=C.utf8, LC_ALL=C.utf8), so probing
# only the long form false-flagged on every kit-bootstrapped box.
# Caught by jason on nlbot0 via /setup-status (F27, sidechat msg 2753).
if locale 2>/dev/null | grep -qiE '(C|en_US)\.UTF-?8'; then
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

  # Scoped NOPASSWD. The kit grants twelve binaries. Probe via `sudo -ln`
  # (which lists effective NOPASSWD entries from the running user's POV)
  # rather than `cat /etc/sudoers.d/<bot>` — the sudoers file is mode 440
  # root-owned, so cat without NOPASSWD-for-cat fails and the old probe
  # returned the empty string, falsely reporting all entries missing.
  # Caught on ansi's 2026-05-12 e2e #2 walk (Finding 6).
  #
  # `sudo -ln` output shape:
  #   User nlbot may run the following commands on this host:
  #       (ALL) NOPASSWD: /usr/bin/systemctl
  #       ...
  # so the same regex used against the sudoers file still matches.
  if [ "$(id -un)" = "$BOT_NAME" ]; then
    sudoers_content=$(sudo -ln 2>/dev/null)
  else
    sudoers_content=$(sudo -n -u "$BOT_NAME" sudo -ln 2>/dev/null)
  fi
  if [ -z "$sudoers_content" ] && [ ! -f "/etc/sudoers.d/$BOT_NAME" ]; then
    warn "scoped NOPASSWD sudoers" "(grant in first-time-setup.md Step 4 'Final action' — this is the LAST step before reboot, not now)"
  elif [ -z "$sudoers_content" ]; then
    warn "scoped NOPASSWD sudoers" "(file exists but probe couldn't run sudo -ln as $BOT_NAME from $(id -un); verify manually with: sudo -u $BOT_NAME sudo -ln | grep NOPASSWD)"
  elif printf '%s' "$sudoers_content" | grep -q 'NOPASSWD:[[:space:]]*ALL'; then
    pass "scoped NOPASSWD sudoers" "(blanket NOPASSWD:ALL — works but wide-blast-radius)"
  else
    missing=""
    for bin in systemctl crontab docker tee journalctl tailscale systemd-creds install mktemp rm test ls; do
      printf '%s' "$sudoers_content" | grep -qE "NOPASSWD:[[:space:]]*(/usr/bin/)?$bin([[:space:]]|,|$)" \
        || missing="$missing $bin"
    done
    if [ -z "$missing" ]; then
      pass "scoped NOPASSWD sudoers" "(all 12 entries present)"
    else
      warn "scoped NOPASSWD sudoers" "(missing:$missing — see first-time-setup.md Step 4 'Final action')"
    fi
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
  if [ -d "$REPO_ROOT/.claude" ]; then
    pass ".claude/ dir present" "(renamed from dot-claude/)"
  else
    fail ".claude/ dir present" "(first-time-setup.md Step 2 — the dot-claude → .claude rename)"
  fi
  if [ -f "$VAULT/identity.md" ] && [ -f "$VAULT/user-profile.md" ]; then
    pass "identity.md + user-profile.md present"
  else
    fail "identity.md + user-profile.md" "(first-time-setup.md Step 2)"
  fi

  # .claude/ freshness: confirm the post-merge hook is installed and that
  # the rendered .claude/ matches what dot-claude/ would produce right
  # now. If they drift, kit updates aren't reaching the bot — every git
  # pull leaves orphan-stale slash commands and agents.
  if [ -x "$REPO_ROOT/.git/hooks/post-merge" ] && grep -q refresh-claude-dir.sh "$REPO_ROOT/.git/hooks/post-merge" 2>/dev/null; then
    pass ".claude/ auto-refresh hook installed" "(.git/hooks/post-merge)"
  else
    warn ".claude/ auto-refresh hook" "(install: install -m 755 $KIT/runtime/hooks/post-merge $REPO_ROOT/.git/hooks/post-merge)"
  fi
  if [ -d "$KIT/dot-claude" ] && [ -d "$REPO_ROOT/.claude" ] && [ -x "$KIT/runtime/refresh-claude-dir.sh" ]; then
    drift_tmpdir=$(mktemp -d)
    # Dry-run the refresh into a scratch dir, then diff to find drift.
    if (cd "$drift_tmpdir" && cp -r "$KIT/dot-claude" "$drift_tmpdir/.claude" 2>/dev/null) ; then
      # Re-apply substitution to the scratch copy and compare. Cheaper
      # than calling refresh-claude-dir.sh directly because we don't
      # want to touch the live .claude/ from a probe.
      _BOT_NAME=$(grep "^- \*\*BOT_NAME\*\*:" "$REPO_ROOT/setup-state.md" 2>/dev/null | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | head -1)
      _USER_NAME=$(grep "^- \*\*USER_NAME\*\*:" "$REPO_ROOT/setup-state.md" 2>/dev/null | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | head -1)
      _VAULT=$(grep "^- \*\*VAULT\*\*:" "$REPO_ROOT/setup-state.md" 2>/dev/null | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | head -1)
      _OS_USER=$(grep "^- \*\*OS_USER\*\*:" "$REPO_ROOT/setup-state.md" 2>/dev/null | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | head -1)
      [ -n "$_OS_USER" ] || _OS_USER="$_BOT_NAME"
      if [ -n "$_BOT_NAME" ] && [ -n "$_VAULT" ]; then
        # Substitute the same six placeholders refresh-claude-dir.sh
        # substitutes — without <KIT> and <REPO_ROOT>, the scratch copy
        # keeps those literal tokens and the diff against the real
        # .claude/ (which DID get them substituted) reports false drift.
        # Caught on ansi's 2026-05-12 e2e #2 walk (Finding 9).
        find "$drift_tmpdir/.claude" -type f -exec sed -i \
          -e "s|<BOT_NAME>|$_BOT_NAME|g" \
          -e "s|<USER_NAME>|$_USER_NAME|g" \
          -e "s|<USER>|$_OS_USER|g" \
          -e "s|<KIT>|$KIT|g" \
          -e "s|<VAULT>|$_VAULT|g" \
          -e "s|<REPO_ROOT>|$REPO_ROOT|g" \
          {} \;
        if diff -rq "$drift_tmpdir/.claude" "$REPO_ROOT/.claude" >/dev/null 2>&1; then
          pass ".claude/ in sync with dot-claude/"
        else
          drift_count=$(diff -rq "$drift_tmpdir/.claude" "$REPO_ROOT/.claude" 2>/dev/null | wc -l)
          warn ".claude/ drift" "($drift_count file(s) differ — run bash $KIT/runtime/refresh-claude-dir.sh)"
        fi
      fi
    fi
    rm -rf "$drift_tmpdir"
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

  # step-5-cron — first bot-driven phase. Probed first because everything
  # downstream becomes re-drivable once the heartbeat is alive.
  if sudo -n crontab -u "$BOT_NAME" -l 2>/dev/null | grep -q inject-prompt.sh; then
    pass "step-5-cron" "heartbeat entries installed"
    REACHED="step-5-cron"
  else
    fail "step-5-cron" "no inject-prompt.sh in crontab"
  fi

  # step-6-silverbullet
  # `docker compose ps`'s default output shows the STATUS column ("Up 8m
  # (healthy)") not the STATE column ("running") — grepping for "running"
  # against that output is a false-negative even when the container is up.
  # Use the explicit `--status running` filter + `--services` to get an
  # unambiguous match: a service name on stdout means it's running, else
  # empty.
  if [ -f "$KIT/docker-compose.yml" ] && \
     docker compose -f "$KIT/docker-compose.yml" ps \
       --status running --services 2>/dev/null | grep -qx silverbullet; then
    if sudo -n tailscale serve status 2>/dev/null | grep -q 3001; then
      pass "step-6-silverbullet" "container + tailscale serve"
    else
      warn "step-6-silverbullet" "container running but no tailscale serve to 3001"
    fi
    REACHED="step-6-silverbullet"
  else
    fail "step-6-silverbullet" "container not running"
  fi

  # step-7-web-shell
  if systemctl is-active "${BOT_NAME}-web.service" >/dev/null 2>&1; then
    pass "step-7-web-shell" "${BOT_NAME}-web.service active"
    REACHED="step-7-web-shell"
  else
    fail "step-7-web-shell" "${BOT_NAME}-web.service not active"
  fi

  # step-8-memory
  if command -v claude >/dev/null 2>&1 && claude mcp list 2>/dev/null | grep -q memorious; then
    pass "step-8-memory" "memorious-mcp registered"
    REACHED="step-8-memory"
  elif command -v claude >/dev/null 2>&1 && claude mcp list 2>/dev/null | grep -qi memor; then
    warn "step-8-memory" "non-memorious memory backend (treating as done)"
    REACHED="step-8-memory"
  else
    fail "step-8-memory" "no memory backend"
  fi

  # step-9 telegram trio (moved to end so its BotFather BLOCKER doesn't gate
  # the rest of the install). By the time we get here, web/cron/memory are
  # all live and the box is fully operational.
  if [ -f /etc/systemd/system/telegram-bot.service ]; then
    pass "step-9-telegram-daemon" "systemd unit installed"
    REACHED="step-9-telegram-daemon"
    if [ -n "$(state_value TG_BOT_TOKEN)" ]; then
      pass "step-9-telegram-creds" "TG_BOT_TOKEN populated"
      REACHED="step-9-telegram-creds-resolved"
    else
      warn "step-9-telegram-creds" "BLOCKER pending: BotFather token"
      # creds-missing is a user-action blocker; counts as the FIRST_FAIL
      # so the recommendation reports "wait on BotFather" instead of
      # falling through to the activate-fail below (which can't proceed
      # without creds anyway).
      : "${FIRST_FAIL:=step-9-telegram-creds-blocker}"
    fi
    if systemctl is-active telegram-bot.service >/dev/null 2>&1; then
      pass "step-9-telegram-activate" "service active"
      REACHED="step-9-telegram-activate"
    else
      fail "step-9-telegram-activate" "service inactive"
    fi
  else
    fail "step-9-telegram-daemon" "no systemd unit"
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
  # bootstrap.sh covers bootstrap.md Steps 3-9 non-interactively. The two
  # carve-outs (adduser, tailscale up) need a real prompt or browser auth,
  # so we skip the automation hint there.
  case "$NEED_BOOTSTRAP" in
    *"create bot user"*|*Tailscale*) ;;
    *) echo "Next automated:       bash $KIT/runtime/bootstrap.sh  (bootstrap.md Steps 3-9, idempotent)" ;;
  esac
  echo
  echo "${Y}You're not at the bot-driven phase yet. Complete bootstrap.md, then first-time-setup.md Steps 1–4, then the bot wakes up and finishes Steps 5–9 itself.${N}"
  exit 1
fi
if [ -n "$NEED_FIRSTTIME" ]; then
  echo "Mode:                 PRE-SETUP (in first-time-setup.md Steps 1–4)"
  echo "Next manual step:     $NEED_FIRSTTIME"
  # first-time-setup.sh covers Steps 1-4 *except* the final NOPASSWD
  # sudoers grant — that one stays manual on purpose as the "hand over
  # the keys" gate before the verification reboot.
  case "$NEED_FIRSTTIME" in
    *"final action"*) ;;
    *) echo "Next automated:       bash $KIT/runtime/first-time-setup.sh  (Steps 1-4 except final NOPASSWD grant)" ;;
  esac
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
if [ "$REACHED" = "step-9-telegram-activate" ] && \
   systemctl is-active "${BOT_NAME}-web.service" >/dev/null 2>&1 && \
   sudo -n crontab -u "$BOT_NAME" -l 2>/dev/null | grep -q inject-prompt.sh; then
  if [ "$DECLARED" = "done" ]; then
    echo "${G}✓ Aligned. Setup is complete; no action needed.${N}"
    exit 0
  elif [ "$APPLY" = "1" ]; then
    apply_phase "done"
    echo "${G}✓ Reality shows all phases complete. Wrote 'Current phase: done' to $SETUP_STATE.${N}"
    exit 0
  else
    echo "${Y}Reality shows all phases complete. Recommend setting Current phase to 'done'.${N}"
    echo "  To auto-apply: re-run with --apply"
    exit 1
  fi
fi

# Compute next-phase suggestion.
#
# Preference order:
#   1. FIRST_FAIL — the earliest phase that didn't pass, even if later
#      phases coincidentally did. Catches "step-5-cron ✗ but step-9-* ✓"
#      where the right action is "go back and fix step-5", not "proceed
#      forward past the gap." Set by fail() (any [✗]) or by the
#      telegram-creds warn branch when BotFather token is missing.
#   2. REACHED → NEXT case mapping — used when FIRST_FAIL is empty
#      (everything before REACHED passed). This is the normal "advance
#      to next phase" path.
#
# `phase-0` is the legacy alias of `pre-step-5`. Telegram trio moved to
# the end of the walk in c38173f; legacy `step-6-telegram-*` names kept
# as aliases. Cron moved to first phase in 8b10926; legacy
# `step-5-silverbullet`, `step-6-web-shell`, `step-7-cron`, and
# `step-9-memory` kept as aliases.
if [ -n "${FIRST_FAIL:-}" ]; then
  NEXT="$FIRST_FAIL"
else
  case "${REACHED:-pre-step-5}" in
    "phase-0"|"pre-step-5"|"")          NEXT="step-5-cron" ;;
    "step-5-cron"|"step-7-cron")        NEXT="step-6-silverbullet" ;;
    "step-6-silverbullet"|"step-5-silverbullet")
                                        NEXT="step-7-web-shell" ;;
    "step-7-web-shell"|"step-6-web-shell")
                                        NEXT="step-8-memory" ;;
    "step-8-memory"|"step-9-memory")    NEXT="step-9-telegram-daemon" ;;
    "step-9-telegram-daemon"|"step-6-telegram-daemon")
                                        NEXT="step-9-telegram-creds-blocker" ;;
    "step-9-telegram-creds-resolved"|"step-6-telegram-creds-resolved")
                                        NEXT="step-9-telegram-activate" ;;
    *)                                  NEXT="${REACHED}" ;;
  esac
fi

echo "Recommended next:     $NEXT"
echo "Next automated:       /setup  (dispatches the setup-runner subagent; soul-loop will also pick it up on next fire)"
echo

if [ "$DECLARED" = "$NEXT" ]; then
  echo "${G}✓ Declared phase matches next-to-run. Run /setup (or wait for next soul-loop) to execute.${N}"
  exit 0
elif [ "$APPLY" = "1" ]; then
  apply_phase "$NEXT"
  echo "${G}✓ Resynced: rewrote 'Current phase: $NEXT' in $SETUP_STATE (was: ${DECLARED:-unset}).${N}"
  echo "  Run /setup (or wait for next soul-loop) to execute."
  exit 0
else
  echo "${Y}! Declared phase ($DECLARED) doesn't match reality ($NEXT).${N}"
  echo "  To resync: re-run with --apply (or edit $SETUP_STATE → 'Current phase: $NEXT' → /setup)."
  exit 1
fi
