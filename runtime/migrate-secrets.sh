#!/usr/bin/env bash
# migrate-secrets.sh — one-shot move from plaintext config files to
# systemd-creds blobs. Idempotent: skips secrets that already exist
# encrypted; never overwrites without confirmation.
#
# Run once on an existing box after pulling the kit version that
# introduces bot-secrets.sh. Fresh installs hit the new flow directly
# from setup-runner and don't need this script.
#
# What it touches:
#   <VAULT>/setup-state.md Values block — TG_BOT_TOKEN, TG_CHAT_ID,
#       TG_BOT_USERNAME, SB_USER_PASSWORD, SB_AUTH_TOKEN,
#       WEB_SESSION_SECRET, WEB_UI_USERNAME, WEB_UI_PASSWORD.
#   <VAULT>/web-terminal/.env — SESSION_SECRET, UI_USERNAME, UI_PASSWORD.
#   <VAULT>/.telegram/config — BOT_TOKEN, CHAT_ID, BOT_USERNAME.
#
# What it does NOT touch (yet):
#   - docker-compose.yml inline SB_USER / SB_AUTH_TOKEN (those need a
#     compose-restart with the new wrapper; out of scope for this script
#     to avoid a cascading restart of a running silverbullet container).
#     Run runtime/silverbullet-up.sh after migration to flip the running
#     compose stack to the env-var form.
#
# Plaintext is REMOVED from these files after a verified encrypt. The
# original lines are replaced with a stub pointing at the credential
# store, so anyone reading the file can see what happened.

set -euo pipefail

BOT_NAME="${BOT_NAME:-$USER}"
VAULT="${VAULT:-$HOME/${BOT_NAME}}"
SECRETS_DIR="/etc/${BOT_NAME}/secrets"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_SECRETS="$SCRIPT_DIR/bot-secrets.sh"

if [ ! -x "$BOT_SECRETS" ]; then
  echo "ERROR: bot-secrets.sh not executable at $BOT_SECRETS" >&2
  exit 1
fi

banner() {
  echo
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

# Encrypt one value, stripped of the surrounding plaintext context, into
# a named credential. Skip if the encrypted blob already exists.
#   $1 = credential name (e.g. tg-bot-token)
#   $2 = plaintext value
encrypt_one() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ] || [ "$value" = "REDACTED" ]; then
    echo "  [skip] $name — empty/placeholder, nothing to migrate"
    return 0
  fi
  if sudo test -f "$SECRETS_DIR/$name"; then
    echo "  [skip] $name — already encrypted at $SECRETS_DIR/$name"
    return 0
  fi
  # Pipe the plaintext through bot-secrets.sh store. The value never
  # touches a temp file in plaintext; bot-secrets.sh writes the encrypted
  # output atomically.
  printf '%s' "$value" | "$BOT_SECRETS" store "$name" >/dev/null
  echo "  [enc]  $name → $SECRETS_DIR/$name"
}

# Pull a value from setup-state.md's Values block. Empty if unset or
# still the <!-- hint --> placeholder.
#
# Note the `|| true` after grep: under `set -euo pipefail` a no-match grep
# returns 1, pipefail propagates that through the pipeline, the $(...)
# substitution in the caller fails, and `set -e` kills the script with no
# error message because the failure was inside command substitution.
# nlbot-test hit this on .telegram/config (file existed but every line was
# a redaction comment, no BOT_TOKEN= match).
state_value() {
  local key="$1"
  local file="$VAULT/setup-state.md"
  [ -f "$file" ] || return 0
  { grep "^- \*\*$key\*\*:" "$file" 2>/dev/null || true; } \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

# Pull a value from a key=value .env / config file. Same `|| true` guard
# as state_value — see comment there.
envfile_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  { grep "^${key}=" "$file" 2>/dev/null || true; } \
    | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

# Replace a line in setup-state.md so the plaintext value is gone.
# Leaves a clear pointer for future readers.
state_redact() {
  local key="$1"
  local cred_name="$2"
  local file="$VAULT/setup-state.md"
  [ -f "$file" ] || return 0
  sed -i "s|^- \*\*$key\*\*:.*|- **$key**: (systemd-creds: $cred_name)|" "$file"
}

# Replace a key=value line so the plaintext is gone.
envfile_redact() {
  local file="$1"
  local key="$2"
  local cred_name="$3"
  [ -f "$file" ] || return 0
  sed -i "s|^${key}=.*|# ${key} — loaded from systemd-creds (\$CREDENTIALS_DIRECTORY/${cred_name}) at service start|" "$file"
}

banner "Phase 0 — Resolve paths"
echo "  BOT_NAME=$BOT_NAME"
echo "  VAULT=$VAULT"
echo "  SECRETS_DIR=$SECRETS_DIR"
echo
echo "  Will pull plaintext from:"
echo "    $VAULT/setup-state.md (Values block)"
echo "    $VAULT/web-terminal/.env"
echo "    $VAULT/.telegram/config"

banner "Phase 1 — Encrypt"

# Telegram
TG_TOKEN=$(state_value TG_BOT_TOKEN)
[ -z "$TG_TOKEN" ] && TG_TOKEN=$(envfile_value "$VAULT/.telegram/config" BOT_TOKEN)
encrypt_one tg-bot-token       "$TG_TOKEN"

TG_CHAT=$(state_value TG_CHAT_ID)
[ -z "$TG_CHAT" ] && TG_CHAT=$(envfile_value "$VAULT/.telegram/config" CHAT_ID)
encrypt_one tg-chat-id         "$TG_CHAT"

TG_USERNAME=$(state_value TG_BOT_USERNAME)
[ -z "$TG_USERNAME" ] && TG_USERNAME=$(envfile_value "$VAULT/.telegram/config" BOT_USERNAME)
encrypt_one tg-bot-username    "$TG_USERNAME"

# SilverBullet
SB_PASS=$(state_value SB_USER_PASSWORD)
encrypt_one sb-user-password   "$SB_PASS"

SB_TOKEN=$(state_value SB_AUTH_TOKEN)
encrypt_one sb-auth-token      "$SB_TOKEN"

# Web shell
WEB_SECRET=$(state_value WEB_SESSION_SECRET)
[ -z "$WEB_SECRET" ] && WEB_SECRET=$(envfile_value "$VAULT/web-terminal/.env" SESSION_SECRET)
encrypt_one web-session-secret "$WEB_SECRET"

WEB_PASS=$(state_value WEB_UI_PASSWORD)
[ -z "$WEB_PASS" ] && WEB_PASS=$(envfile_value "$VAULT/web-terminal/.env" UI_PASSWORD)
encrypt_one web-ui-password    "$WEB_PASS"

# UI_USERNAME is less sensitive but still encrypted for consistency.
WEB_USER=$(state_value WEB_UI_USERNAME)
[ -z "$WEB_USER" ] && WEB_USER=$(envfile_value "$VAULT/web-terminal/.env" UI_USERNAME)
encrypt_one web-ui-username    "$WEB_USER"

banner "Phase 2 — Verify"
ok=0
fail=0
for name in tg-bot-token tg-chat-id tg-bot-username \
            sb-user-password sb-auth-token \
            web-session-secret web-ui-password web-ui-username; do
  if sudo test -f "$SECRETS_DIR/$name"; then
    if "$BOT_SECRETS" verify "$name" >/dev/null 2>&1; then
      echo "  ✓ $name"
      ok=$((ok+1))
    else
      echo "  ✗ $name — exists but fails decryption" >&2
      fail=$((fail+1))
    fi
  else
    echo "  -  $name — not stored (empty/missing input value, OK if you didn't use that feature yet)"
  fi
done

if [ "$fail" -gt 0 ]; then
  echo
  echo "  $fail credential(s) failed verification. Plaintext NOT removed." >&2
  echo "  Investigate before re-running. Most likely cause: TPM seal mismatch or systemd-creds binary missing." >&2
  exit 1
fi

# Replace a systemd unit file from a kit template, substituting placeholders.
# Idempotent: if the running unit already loads encrypted credentials, skip.
#   $1 = unit file name in /etc/systemd/system (e.g. nlbot-web.service)
#   $2 = path to kit template (e.g. $VAULT/web-terminal/claude-web.service)
#   $3 = (optional) human label for the banner
replace_unit_if_stale() {
  local unit_name="$1"
  local template="$2"
  local label="${3:-$unit_name}"
  local installed="/etc/systemd/system/$unit_name"

  if [ ! -f "$template" ]; then
    echo "  [skip] $label — template not found at $template" >&2
    return 0
  fi

  # If the unit exists AND already has the LoadCredentialEncrypted= lines
  # the new template introduces, nothing to do. Test with sudo because
  # /etc/systemd/system files are root-readable on some installs.
  if sudo test -f "$installed" && \
     sudo grep -q "^LoadCredentialEncrypted=" "$installed" 2>/dev/null; then
    echo "  [skip] $label — already loads encrypted credentials"
    return 0
  fi

  # Render and install. The template uses <BOT_NAME>, <VAULT>, <USER>;
  # OS_USER defaults to BOT_NAME (kit convention).
  echo "  [unit] $label — replacing $installed with rendered template"
  sed \
    -e "s|<BOT_NAME>|$BOT_NAME|g" \
    -e "s|<VAULT>|$VAULT|g" \
    -e "s|<USER>|$BOT_NAME|g" \
    "$template" \
    | sudo tee "$installed" >/dev/null
  return 1   # signal "changed" so caller can daemon-reload
}

banner "Phase 2.5 — Refresh service units"
echo
echo "  Encrypted credentials are useless if the unit files don't tell"
echo "  systemd to load them. Replacing any unit that's missing"
echo "  LoadCredentialEncrypted= with the kit's current template."
echo

units_changed=0
replace_unit_if_stale "${BOT_NAME}-web.service" \
  "$VAULT/web-terminal/claude-web.service" \
  "web-terminal" || units_changed=$((units_changed+1))

replace_unit_if_stale "telegram-bot.service" \
  "$SCRIPT_DIR/telegram-bot.service" \
  "telegram-bot" || units_changed=$((units_changed+1))

if [ "$units_changed" -gt 0 ]; then
  echo "  Reloading systemd to pick up $units_changed replaced unit(s)…"
  sudo systemctl daemon-reload
fi

banner "Phase 3 — Redact plaintext"

# setup-state.md
state_redact TG_BOT_TOKEN        tg-bot-token
state_redact TG_CHAT_ID          tg-chat-id
state_redact TG_BOT_USERNAME     tg-bot-username
state_redact SB_USER_PASSWORD    sb-user-password
state_redact SB_AUTH_TOKEN       sb-auth-token
state_redact WEB_SESSION_SECRET  web-session-secret
state_redact WEB_UI_USERNAME     web-ui-username
state_redact WEB_UI_PASSWORD     web-ui-password
echo "  [redact] $VAULT/setup-state.md Values block updated"

# web-terminal/.env
envfile_redact "$VAULT/web-terminal/.env" SESSION_SECRET    web-session-secret
envfile_redact "$VAULT/web-terminal/.env" UI_USERNAME       web-ui-username
envfile_redact "$VAULT/web-terminal/.env" UI_PASSWORD       web-ui-password
[ -f "$VAULT/web-terminal/.env" ] && echo "  [redact] $VAULT/web-terminal/.env"

# .telegram/config
envfile_redact "$VAULT/.telegram/config" BOT_TOKEN          tg-bot-token
envfile_redact "$VAULT/.telegram/config" CHAT_ID            tg-chat-id
envfile_redact "$VAULT/.telegram/config" BOT_USERNAME       tg-bot-username
[ -f "$VAULT/.telegram/config" ] && echo "  [redact] $VAULT/.telegram/config"

# Tighten setup-state.md perms — the file no longer holds secrets but
# it does hold identity prefs and was world-readable before.
chmod 600 "$VAULT/setup-state.md" 2>/dev/null || true

banner "Phase 4 — Restart services"
echo
echo "  Plaintext secrets are now at $SECRETS_DIR (encrypted)."
echo "  Restarting services so they pick up credentials via"
echo "  \$CREDENTIALS_DIRECTORY."
echo

restart_one() {
  local unit="$1"
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    echo "  [skip] $unit — not installed"
    return 0
  fi
  if sudo systemctl restart "$unit"; then
    sleep 1
    if systemctl is-active "$unit" >/dev/null 2>&1; then
      echo "  [ok]   $unit — active"
    else
      echo "  [FAIL] $unit — restart returned 0 but not active; check journalctl --no-pager -u $unit -n 30" >&2
    fi
  else
    echo "  [FAIL] $unit — restart failed; check journalctl --no-pager -u $unit -n 30" >&2
  fi
}

restart_one "${BOT_NAME}-web.service"
restart_one "telegram-bot.service"

cat <<EOF

SilverBullet (compose) still needs its wrapper to flip from
inline literals to \${SB_USER_PASSWORD} / \${SB_AUTH_TOKEN} loaded
from systemd-creds:

  bash $SCRIPT_DIR/silverbullet-up.sh

(Skipped automatically here because it cascades a container
restart; run it when you're ready for that.)
EOF
