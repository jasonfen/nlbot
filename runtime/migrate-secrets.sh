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
state_value() {
  local key="$1"
  local file="$VAULT/setup-state.md"
  [ -f "$file" ] || return 0
  grep "^- \*\*$key\*\*:" "$file" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

# Pull a value from a key=value .env / config file.
envfile_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
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

banner "Done — restart services to load new credentials"
cat <<EOF

The plaintext secrets have been moved into:
  $SECRETS_DIR

Restart the services to pick them up (their unit files must already
have LoadCredentialEncrypted= entries — see the new units in
runtime/web-terminal/claude-web.service and runtime/telegram-bot.service):

  sudo systemctl daemon-reload
  sudo systemctl restart ${BOT_NAME}-web.service
  sudo systemctl restart telegram-bot.service

  # SilverBullet (compose) needs its wrapper:
  bash $SCRIPT_DIR/silverbullet-up.sh

If a service fails to start, journalctl -u <unit> will say why; the
most common cause is the unit not having LoadCredentialEncrypted= or
the daemon not yet reading from \$CREDENTIALS_DIRECTORY. Both are
addressed by the kit version that ships this script.
EOF
