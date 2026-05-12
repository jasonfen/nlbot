#!/usr/bin/env bash
# silverbullet-up.sh — bring up the SilverBullet docker compose stack
# with secrets sourced from systemd-creds instead of an inline plaintext
# docker-compose.yml.
#
# Reads:
#   /etc/<BOT_NAME>/secrets/sb-user-password (systemd-creds blob)
#   /etc/<BOT_NAME>/secrets/sb-auth-token    (systemd-creds blob)
#
# Sets env vars SB_USER_PASSWORD and SB_AUTH_TOKEN, then runs
# `docker compose up -d silverbullet` against $VAULT/docker-compose.yml.
# That compose file should reference the env vars (not inline values):
#
#   environment:
#     - SB_USER=${BOT_NAME}:${SB_USER_PASSWORD}
#     - SB_AUTH_TOKEN=${SB_AUTH_TOKEN}
#
# Requires sudo because systemd-creds decrypt needs root to read host-key
# encrypted blobs. The plaintext env vars only exist for the duration of
# the `docker compose up` command — they're export-only-in-this-process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$SCRIPT_DIR/.." && pwd)
BOT_NAME="${BOT_NAME:-$USER}"
SECRETS_DIR="/etc/${BOT_NAME}/secrets"

# docker-compose.yml lives in kit/ (kit-managed). The compose file mounts
# ../vault:/space so SilverBullet only sees the vault subset of the tree.
COMPOSE_FILE="${COMPOSE_FILE:-$KIT/docker-compose.yml}"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: docker-compose.yml not found at $COMPOSE_FILE" >&2
  exit 1
fi

for cred in sb-user-password sb-auth-token; do
  if ! sudo test -f "$SECRETS_DIR/$cred"; then
    echo "ERROR: missing credential $SECRETS_DIR/$cred" >&2
    echo "  Run runtime/bot-secrets.sh generate $cred 24 first," >&2
    echo "  or runtime/migrate-secrets.sh if you have plaintext to import." >&2
    exit 1
  fi
done

# Decrypt straight into env vars in a subshell so the values never land
# in this shell's history or in any temp file. Plaintext exists only in
# memory for the lifetime of the `docker compose up` call below.
export SB_USER_PASSWORD
export SB_AUTH_TOKEN
export BOT_NAME
SB_USER_PASSWORD=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-user-password" -)
SB_AUTH_TOKEN=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-auth-token" -)

# Hand off to docker compose. compose substitutes ${SB_USER_PASSWORD} etc.
# from the environment at parse time.
exec docker compose -f "$COMPOSE_FILE" up -d silverbullet
