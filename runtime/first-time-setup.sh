#!/usr/bin/env bash
# first-time-setup.sh — automates Steps 1-4 of first-time-setup.md.
#
# Drops the vault skeleton, copies kit files, substitutes Phase 0
# placeholders ([Nate], [Your Bot's Name], <VAULT>, etc.), installs
# claude-code.service, and brings up the tmux session.
#
# Stops BEFORE the NOPASSWD sudoers grant and the verification reboot —
# those stay manual on purpose (the kit's explicit "hand over the keys"
# gate). Prints a clear next-steps block when done.
#
# Usage:
#   bash <KIT_CLONE>/runtime/first-time-setup.sh
#
# Phase 0 values are resolved in this order, first hit wins:
#   1. Environment variable already set (BOT_NAME=nlbot ./first-time-setup.sh)
#   2. Existing populated entry in <VAULT>/setup-state.md Values block
#   3. Interactive `read -p` with default in brackets
#
# Required: BOT_NAME, USER_NAME, VAULT, CANARY_PHRASE
# Optional: IDLE_PREFS, CREATIVE_OUTPUT, COMM_STYLE, VALUES_CARES_ABOUT,
#           USER_ROLE, USER_HOBBIES, USER_HOURS, USER_PREFS

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

banner() {
  echo
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

skip() {
  echo "  [skip] $1"
}

# Resolve VAULT default from script location: <VAULT>/runtime/first-time-setup.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read a value from setup-state.md Values block (returns empty if missing
# or still has the placeholder comment).
state_read() {
  local key="$1"
  local file="$VAULT_DEFAULT/setup-state.md"
  [ -f "$file" ] || return 0
  local value
  value=$(grep "^- \*\*$key\*\*:" "$file" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1)
  echo "$value"
}

# Write a value into setup-state.md Values block.
state_write() {
  local key="$1"
  local value="$2"
  local file="$VAULT/setup-state.md"
  [ -f "$file" ] || return 0
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[\&|]/\\&/g')
  sed -i "s|^- \*\*$key\*\*:.*|- **$key**: $escaped|" "$file"
}

# Prompt-or-resolve. Order: env var, setup-state, default, prompt.
# Usage: prompt_value VAR_NAME "question" [default] [required=yes|no]
prompt_value() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local required="${4:-no}"
  local current
  current="$(eval echo "\${$var_name:-}")"

  if [ -n "$current" ]; then
    echo "  $var_name = $current  (from env)"
    return 0
  fi

  local from_state
  from_state=$(state_read "$var_name")
  if [ -n "$from_state" ]; then
    eval "$var_name=$(printf '%q' "$from_state")"
    echo "  $var_name = $from_state  (from setup-state.md)"
    return 0
  fi

  local answer
  if [ -n "$default" ]; then
    read -rp "  $question [$default]: " answer
    answer="${answer:-$default}"
  else
    read -rp "  $question: " answer
  fi

  if [ -z "$answer" ] && [ "$required" = "yes" ]; then
    echo "  ERROR: $var_name is required" >&2
    exit 1
  fi

  eval "$var_name=$(printf '%q' "$answer")"
}

# Replace Phase 0 placeholders in one file.
substitute_placeholders() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -i \
    -e "s|\[Your Bot's Name\]|$BOT_NAME|g" \
    -e "s|\[Nate's\]|${USER_NAME}'s|g" \
    -e "s|\[Nate\]|$USER_NAME|g" \
    -e "s|\[Nate: Fill this in\. What are your non-negotiable preferences?\]|$USER_PREFS|g" \
    -e "s|\[CHOOSE YOUR CANARY PHRASE\]|$CANARY_PHRASE|g" \
    -e "s|\[YOUR CANARY PHRASE\]|$CANARY_PHRASE|g" \
    -e "s|\[reading/coding/writing/exploring\]|$IDLE_PREFS|g" \
    -e "s|\[poems/stories/technical docs/music reviews\]|$CREATIVE_OUTPUT|g" \
    -e "s|\[direct/gentle/playful/formal\]|$COMM_STYLE|g" \
    -e "s|\[quality/speed/creativity/accuracy\]|$VALUES_CARES_ABOUT|g" \
    -e "s|<BOT_NAME>|$BOT_NAME|g" \
    -e "s|<USER_NAME>|$USER_NAME|g" \
    -e "s|<VAULT>|$VAULT|g" \
    -e "s|<USER>|$BOT_NAME|g" \
    "$file"
}

# --- OAuth pre-flight (must happen before the systemd service can run) ------
# claude --continue inside a detached tmux session silently exits if the
# user hasn't done first-run OAuth at a real terminal — the TOS gate can't
# be answered headlessly. Catch it here before we wire up the service.
if [ ! -f "$HOME/.claude/.credentials.json" ]; then
  echo
  echo "  ✗ Claude Code first-run OAuth has not been completed."
  echo "    \$HOME/.claude/.credentials.json is missing."
  echo
  echo "  Fix: at a real terminal (this SSH session is fine, NOT inside tmux),"
  echo "       run:  claude"
  echo "       Accept the TOS, walk the OAuth, then exit cleanly."
  echo "       Re-run this script after."
  exit 1
fi

# --- Bootstrap setup-state.md from the template if missing ------------------
# The repo ships setup-state.md.template (versioned) and .gitignores
# setup-state.md (per-bot live values). This means `git pull` never
# clobbers Phase 0 answers a previous run wrote. First run copies once.
if [ ! -f "$VAULT_DEFAULT/setup-state.md" ] \
   && [ -f "$VAULT_DEFAULT/setup-state.md.template" ]; then
  cp "$VAULT_DEFAULT/setup-state.md.template" "$VAULT_DEFAULT/setup-state.md"
  echo "  Created setup-state.md from template (first run on this box)."
fi

# --- Phase 0: collect values ------------------------------------------------

banner "Phase 0 — Collect setup values"
echo "  (env var > setup-state.md > prompt — first hit wins)"
echo

prompt_value BOT_NAME       "Bot name (lowercase, becomes the unix user)" "$USER" yes
prompt_value USER_NAME      "Your name (how the bot will address you)"   "${USER^}" yes
prompt_value VAULT          "Vault path (kit clone directory)"           "$VAULT_DEFAULT" yes
prompt_value CANARY_PHRASE  "Canary phrase (3-7 memorable words)"        "" yes
echo
echo "  Optional identity values (Enter accepts the default):"
prompt_value IDLE_PREFS         "Idle-time preference"                        "reading"
prompt_value CREATIVE_OUTPUT    "Preferred creative output"                   "technical docs"
prompt_value COMM_STYLE         "Communication style"                         "direct"
prompt_value VALUES_CARES_ABOUT "Values you care about"                       "quality"
prompt_value USER_ROLE          "Your role / what you work on"                "software engineer"
prompt_value USER_HOBBIES       "Hobbies (free-form)"                         "homelab, gaming"
prompt_value USER_HOURS         "Hours you're typically online"               "evenings EDT"
prompt_value USER_PREFS         "Non-negotiable preferences (one short line)" "be honest, be concise, ask when unsure"

[ -z "${VAULT:-}" ] && { echo "VAULT unresolved; aborting." >&2; exit 1; }

# --- Step 1: prereq check ---------------------------------------------------
#
# setup-status.sh exits 1 whenever ANY part of the kit is incomplete —
# including the vault skeleton + claude-code.service that THIS script
# is about to install. So we can't gate on its exit code directly.
# Instead, run it once, capture the output, and only abort if a [✗]
# appears in the "System prerequisites" or "Bot user" sections (the
# things bootstrap.md owns; everything else is what we're here to do).

banner "Step 1 — Prereqs (delegating to setup-status.sh)"
if [ -x "$VAULT/runtime/setup-status.sh" ]; then
  PROBE=$(bash "$VAULT/runtime/setup-status.sh" 2>&1 || true)
  echo "$PROBE"
  echo
  # Extract just the System + Bot-user sections (between their headers
  # and the next major section "Vault and bot service") and check those
  # lines for [✗] markers. Anything before "Vault and bot service" is a
  # genuine prereq the script can't fix; anything after is our own job.
  PREREQ_FAILS=$(printf '%s\n' "$PROBE" \
    | awk '/^Vault and bot service/{exit} /\[✗\]/{print}')
  if [ -n "$PREREQ_FAILS" ]; then
    echo "  ✗ Genuine prereq failures (bootstrap.md territory):" >&2
    printf '%s\n' "$PREREQ_FAILS" | sed 's/^/      /' >&2
    echo "    Resolve those, then re-run this script." >&2
    exit 1
  fi
  echo "  ✓ System + bot-user prereqs OK. Vault/service items below will be addressed by Steps 2-4."
else
  skip "setup-status.sh not executable (continuing — re-bootstrap recommended)"
fi

# --- Step 2: vault skeleton + identity seed + placeholder substitution ------

banner "Step 2 — Vault skeleton + identity seed"
mkdir -p "$VAULT/journals/fiction" "$VAULT/handoffs" "$VAULT/processes"

# Seed top-level identity files. -n = don't clobber an edited file.
[ -f "$VAULT/CLAUDE.md" ]       || cp "$VAULT/CLAUDE-nate.md" "$VAULT/CLAUDE.md"
[ -d "$VAULT/.claude" ]         || cp -r "$VAULT/dot-claude" "$VAULT/.claude"
[ -f "$VAULT/identity.md" ]     || cp "$VAULT/templates/identity.md"     "$VAULT/identity.md"
[ -f "$VAULT/user-profile.md" ] || cp "$VAULT/templates/user-profile.md" "$VAULT/user-profile.md"
[ -f "$VAULT/soul-loop.md" ]    || cp "$VAULT/templates/soul-loop.md"    "$VAULT/soul-loop.md"

# SilverBullet vault-page + process-doc seeds. -n on cp = no-clobber.
cp -n "$VAULT/templates/vault-pages/"*.md "$VAULT/"            2>/dev/null || true
cp -n "$VAULT/templates/processes/"*.md   "$VAULT/processes/"  2>/dev/null || true
touch "$VAULT/journals/journal.md"

echo "  Files seeded. Now substituting placeholders…"

# Top-level seeded files
for f in CLAUDE.md identity.md user-profile.md soul-loop.md \
         index.md dashboard.md handoffs.md journals.md \
         processes.md inbox.md decisions.md; do
  substitute_placeholders "$VAULT/$f"
done

# Process docs + agents + commands
for f in "$VAULT/processes/"*.md \
         "$VAULT/.claude/agents/"*.md \
         "$VAULT/.claude/commands/"*.md; do
  substitute_placeholders "$f"
done

# Persist Phase 0 values into setup-state.md
state_write BOT_NAME            "$BOT_NAME"
state_write USER_NAME           "$USER_NAME"
state_write VAULT               "$VAULT"
state_write OS_USER             "$USER"
state_write CANARY_PHRASE       "$CANARY_PHRASE"
state_write IDLE_PREFS          "$IDLE_PREFS"
state_write CREATIVE_OUTPUT     "$CREATIVE_OUTPUT"
state_write COMM_STYLE          "$COMM_STYLE"
state_write VALUES_CARES_ABOUT  "$VALUES_CARES_ABOUT"
state_write USER_ROLE           "$USER_ROLE"
state_write USER_HOBBIES        "$USER_HOBBIES"
state_write USER_HOURS          "$USER_HOURS"
state_write USER_PREFS          "$USER_PREFS"
sed -i "s|^Last updated:.*|Last updated: $(date '+%Y-%m-%d %H:%M')|" "$VAULT/setup-state.md"
sed -i "s|^Current phase:.*|Current phase: pre-step-5|" "$VAULT/setup-state.md"

# Verify no leftover placeholders. Only inspect the files we actually
# seeded into the vault — the kit's source docs (README.md, bootstrap.md,
# setup-orchestrator.md, etc.) legitimately reference <BOT_NAME>/<VAULT>
# as documentation and aren't templates the user needs to substitute.
SEEDED_FILES=(
  "$VAULT/CLAUDE.md" "$VAULT/identity.md" "$VAULT/user-profile.md"
  "$VAULT/soul-loop.md" "$VAULT/index.md" "$VAULT/dashboard.md"
  "$VAULT/handoffs.md" "$VAULT/journals.md" "$VAULT/processes.md"
  "$VAULT/inbox.md" "$VAULT/decisions.md" "$VAULT/start-claude.sh"
)
LEFTOVER=""
for f in "${SEEDED_FILES[@]}"; do
  [ -f "$f" ] || continue
  if grep -qE '\[Your Bot|\[Nate\]|\[CHOOSE YOUR|<USER>|<USER_NAME>|<VAULT>|<BOT_NAME>' "$f"; then
    LEFTOVER+="$f"$'\n'
  fi
done
# Also check the seeded processes/ and .claude/ trees
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -qE '\[Your Bot|\[Nate\]|\[CHOOSE YOUR|<USER>|<USER_NAME>|<VAULT>|<BOT_NAME>' "$f"; then
    LEFTOVER+="$f"$'\n'
  fi
done < <(find "$VAULT/processes" "$VAULT/.claude" -name '*.md' 2>/dev/null)

if [ -n "$LEFTOVER" ]; then
  echo "  ⚠ Files still contain placeholders (edit by hand if needed):"
  printf '%s' "$LEFTOVER" | sed 's/^/      /'
else
  echo "  ✓ All Phase 0 placeholders substituted."
fi

# --- Step 3: disable runaway keybindings ------------------------------------

banner "Step 3 — Disable session-killing keybindings"
mkdir -p "$HOME/.claude"
KB="$HOME/.claude/keybindings.json"
if [ -f "$KB" ] && grep -q 'ctrl+x ctrl+e' "$KB"; then
  skip "keybindings.json already disables ctrl+x ctrl+e / ctrl+x ctrl+k"
else
  cat > "$KB" <<'KBEOF'
{
  "disabled": ["ctrl+x ctrl+e", "ctrl+x ctrl+k"]
}
KBEOF
  echo "  Wrote $KB"
fi

# --- Step 4: persistence (start-claude.sh + systemd unit + enable) ----------

banner "Step 4 — Persistence (start-claude.sh + systemd unit)"

# Encrypted credentials directory. systemd-creds blobs live here, owned by
# root mode 700 — the bot user can `ls` via sudo to see names but cannot
# read the ciphertext. See templates/processes/security.md.
sudo install -d -m 700 -o root -g root "/etc/$BOT_NAME/secrets"
echo "  Ensured /etc/$BOT_NAME/secrets exists (root:root, 700)"

# Stage the helper + migration scripts into the vault so they're invocable
# by setup-runner and by the human post-install.
cp "$VAULT/runtime/bot-secrets.sh" "$VAULT/bot-secrets.sh"
chmod +x "$VAULT/bot-secrets.sh"
if [ -f "$VAULT/runtime/migrate-secrets.sh" ]; then
  cp "$VAULT/runtime/migrate-secrets.sh" "$VAULT/migrate-secrets.sh"
  chmod +x "$VAULT/migrate-secrets.sh"
fi
echo "  Staged bot-secrets.sh + migrate-secrets.sh at \$VAULT/"

# Copy + substitute start-claude.sh into the vault root
cp "$VAULT/runtime/start-claude.sh" "$VAULT/start-claude.sh"
substitute_placeholders "$VAULT/start-claude.sh"
chmod +x "$VAULT/start-claude.sh"
echo "  Wrote $VAULT/start-claude.sh"

# Optional setup-bootstrap.sh sidecar (start-claude.sh probes for it)
if [ -f "$VAULT/runtime/setup-bootstrap.sh" ]; then
  cp "$VAULT/runtime/setup-bootstrap.sh" "$VAULT/setup-bootstrap.sh"
  chmod +x "$VAULT/setup-bootstrap.sh"
  echo "  Wrote $VAULT/setup-bootstrap.sh"
fi

# Drop the systemd unit
sudo tee /etc/systemd/system/claude-code.service > /dev/null <<EOF
[Unit]
Description=Claude Code persistent tmux session
After=network-online.target
Wants=network-online.target
# Cap restart loops at 10 within 60s so a genuine break doesn't flood the
# journal — without this, RestartSec=5 will hammer indefinitely. Caught
# during nlbot-test dry-run when a misconfigured start-claude.sh racked
# up 34 restart attempts in seconds.
StartLimitBurst=10
StartLimitIntervalSec=60

[Service]
Type=forking
User=$BOT_NAME
ExecStart=$VAULT/start-claude.sh
ExecStop=/usr/bin/tmux kill-session -t claude
Restart=on-failure
RestartSec=5
Environment=LANG=C.utf8
Environment=LC_ALL=C.utf8

[Install]
WantedBy=multi-user.target
EOF
echo "  Wrote /etc/systemd/system/claude-code.service"

# Sibling tmux service for a regular bash shell — accessible via the web
# shell at ?session=shell, or `tmux attach -t shell` over SSH. Same User,
# same Restart cap as claude-code.service. Independent of Claude — can be
# stopped/restarted without disturbing the bot.
sudo tee /etc/systemd/system/${BOT_NAME}-shell.service > /dev/null <<EOF
[Unit]
Description=Bot user persistent shell tmux session
After=network-online.target
Wants=network-online.target
StartLimitBurst=10
StartLimitIntervalSec=60

[Service]
Type=forking
User=$BOT_NAME
ExecStart=/usr/bin/tmux new-session -d -s shell -c %h /bin/bash -l
ExecStop=/usr/bin/tmux kill-session -t shell
Restart=on-failure
RestartSec=5
Environment=LANG=C.utf8
Environment=LC_ALL=C.utf8

[Install]
WantedBy=multi-user.target
EOF
echo "  Wrote /etc/systemd/system/${BOT_NAME}-shell.service"

sudo systemctl daemon-reload
sudo systemctl enable --now claude-code.service
sudo systemctl enable --now ${BOT_NAME}-shell.service

# Verify BOTH tmux sessions came up. Give them a few seconds to spawn.
echo "  Waiting for tmux sessions to register…"
for i in 1 2 3 4 5; do
  if tmux ls 2>/dev/null | grep -q '^claude:' && \
     tmux ls 2>/dev/null | grep -q '^shell:'; then
    echo "  ✓ tmux sessions 'claude' and 'shell' are up."
    break
  fi
  sleep 1
done
if ! tmux ls 2>/dev/null | grep -q '^claude:'; then
  echo "  ✗ tmux session 'claude' did NOT come up." >&2
  echo "    Check: sudo journalctl -u claude-code.service -n 50" >&2
  exit 1
fi
if ! tmux ls 2>/dev/null | grep -q '^shell:'; then
  echo "  ✗ tmux session 'shell' did NOT come up." >&2
  echo "    Check: sudo journalctl -u ${BOT_NAME}-shell.service -n 50" >&2
  exit 1
fi

# --- Done ------------------------------------------------------------------

banner "Steps 1-4 complete — next, manual"
cat <<EOF

  1. tmux attach -t claude
     Verify the ❯ prompt renders correctly (not __ or ??).
     Ctrl-b then d to detach — DO NOT exit the session.

  2. Grant scoped NOPASSWD sudo (the kit's "hand over the keys" gate):

        sudo tee /etc/sudoers.d/$BOT_NAME >/dev/null <<EOS
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/systemctl
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/crontab
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/docker
EOS
        sudo chmod 440 /etc/sudoers.d/$BOT_NAME
        sudo visudo -cf /etc/sudoers.d/$BOT_NAME

     Verify:
        sudo -u $BOT_NAME sudo -n /usr/bin/systemctl --version >/dev/null \\
          && echo "NOPASSWD OK"

  3. sudo reboot
     Verify the box comes back clean and claude-code.service auto-starts.

  4. After reboot, the bot drives Steps 5-9 via setup-runner.
     Watch progress:  bash $VAULT/runtime/setup-status.sh

EOF
