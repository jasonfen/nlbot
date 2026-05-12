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

# Hard-fail on missing BOT_NAME rather than letting compose default it to
# the blank string at parse time. An empty BOT_NAME renders SB_USER=":"
# which silently leaves SilverBullet's form-auth wide open (see kit-e2e-
# test-2.md Finding 12). Fail loudly so the setup-runner journal surfaces
# the problem instead of completing with auth disabled.
if [ -z "${BOT_NAME:-}" ]; then
  echo "ERROR: BOT_NAME is empty (env var unset and \$USER unset)." >&2
  echo "  Export BOT_NAME before invoking silverbullet-up.sh." >&2
  exit 1
fi

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
#
# Each decrypt is guarded by an explicit `|| exit 1` because `set -e`
# does NOT abort on a failing command substitution in an assignment
# (bash quirk: `inherit_errexit` would be needed, and the previous
# version of this script relied on it). Without the guard, a failed
# decrypt silently produced an empty plaintext, which then propagated
# into the container as SB_USER_PASSWORD="" / SB_AUTH_TOKEN="" — the
# SilverBullet form-flow accepts the resulting empty:empty match and
# auth is effectively off. See kit-e2e-test-2.md Finding 12.
export SB_USER_PASSWORD SB_AUTH_TOKEN BOT_NAME
SB_USER_PASSWORD=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-user-password" -) \
  || { echo "ERROR: failed to decrypt $SECRETS_DIR/sb-user-password" >&2; exit 1; }
SB_AUTH_TOKEN=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-auth-token" -) \
  || { echo "ERROR: failed to decrypt $SECRETS_DIR/sb-auth-token" >&2; exit 1; }

# Belt-and-suspenders: decrypt may exit 0 with empty stdout in some
# corner cases (e.g. zero-length cred blob). Refuse to start the
# container with an empty password since that disables auth.
if [ -z "$SB_USER_PASSWORD" ]; then
  echo "ERROR: decrypted SB_USER_PASSWORD is empty — refusing to start SilverBullet" >&2
  echo "  Regenerate the credential: runtime/bot-secrets.sh generate sb-user-password 24" >&2
  exit 1
fi
if [ -z "$SB_AUTH_TOKEN" ]; then
  echo "ERROR: decrypted SB_AUTH_TOKEN is empty — refusing to start SilverBullet" >&2
  echo "  Regenerate the credential: runtime/bot-secrets.sh generate sb-auth-token 24" >&2
  exit 1
fi

# Hand off to docker compose. compose substitutes ${SB_USER_PASSWORD} etc.
# from the environment at parse time.
exec docker compose -f "$COMPOSE_FILE" up -d silverbullet
