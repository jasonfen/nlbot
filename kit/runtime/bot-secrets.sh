#!/usr/bin/env bash
# bot-secrets.sh — wrapper around systemd-creds for the bot's secrets.
#
# Stores encrypted blobs at /etc/<BOT_NAME>/secrets/<name>. systemd-creds
# encrypts using the host's TPM if available, falling back to the host key
# in /var/lib/systemd/credential.secret. Either way: blobs are tied to this
# host, can't be decrypted off-box, and can only be opened by root or by a
# systemd unit that loads them via LoadCredentialEncrypted=.
#
# Design intent: the bot can `generate` and `store` new credentials but
# cannot `get` them — no command in this script prints a plaintext value
# to stdout. Services read their credentials via LoadCredentialEncrypted=
# in their unit files (kernel-mounted tmpfs at $CREDENTIALS_DIRECTORY).
#
# Usage:
#   bot-secrets.sh generate <name> [length]
#       Generate `length` bytes of random data (default 24, base64-encoded
#       openssl output) and encrypt it under `<name>` in one pipeline.
#       Plaintext is never assigned to a shell variable or written to
#       a temp file.
#
#   bot-secrets.sh store <name>
#       Read plaintext from stdin and encrypt under `<name>`. Use this
#       when the value comes from outside (e.g., BotFather token typed
#       into a prompt and piped in).
#
#   bot-secrets.sh list
#       Print known secret names (file basenames only, no values).
#
#   bot-secrets.sh verify <name>
#       Decrypt and discard. Exit 0 if the credential can be opened on
#       this host; non-zero otherwise. Never prints the value.
#
#   bot-secrets.sh path <name>
#       Print the absolute path to the encrypted blob. Useful for
#       LoadCredentialEncrypted= lines.
#
# Requires: systemd 250+ (Debian 12+ / Ubuntu 22.04+ ship this).
# Requires sudo for write operations (the secrets directory is root-owned
# mode 700; the bot user shouldn't be able to read raw blobs).

set -euo pipefail

# Bot name source order: $BOT_NAME env var, then $USER. The secrets dir is
# /etc/${BOT_NAME}/secrets so the same script works across bots.
BOT_NAME="${BOT_NAME:-$USER}"
SECRETS_DIR="/etc/${BOT_NAME}/secrets"

ensure_dir() {
  if [ ! -d "$SECRETS_DIR" ]; then
    sudo install -d -m 700 -o root -g root "$SECRETS_DIR"
  fi
}

usage() {
  sed -n '2,/^# Requires/p' "$0" | sed 's/^# \?//'
  exit "${1:-2}"
}

require_arg() {
  if [ -z "${1:-}" ]; then
    echo "ERROR: missing <name> argument" >&2
    usage 2
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  generate)
    require_arg "${1:-}"
    name="$1"
    length="${2:-24}"
    ensure_dir
    # Single pipeline: openssl emits to systemd-creds stdin, encrypted blob
    # to a tempfile, then atomic install. Plaintext never lands in a
    # variable or a non-encrypted file. The intermediate file is only
    # ever readable by root.
    tmp=$(sudo mktemp -p "$SECRETS_DIR" ".${name}.XXXXXX")
    openssl rand -base64 "$length" \
      | sudo systemd-creds encrypt --name="$name" - "$tmp"
    sudo install -m 400 -o root -g root "$tmp" "$SECRETS_DIR/$name"
    sudo rm -f "$tmp"
    echo "stored: $name ($length bytes, base64) → $SECRETS_DIR/$name"
    ;;

  store)
    require_arg "${1:-}"
    name="$1"
    ensure_dir
    # stdin is inherited from the caller; the explicit `< /dev/stdin`
    # redirect previously here failed with `/dev/stdin: Permission
    # denied` when invoked through `sudo -u <bot> bash -c '...'`
    # because the inner sudo's pty seal made /dev/stdin unreadable.
    # Leaving the redirect off lets systemd-creds read the inherited
    # fd 0 directly (kit-e2e-test-2 F14).
    tmp=$(sudo mktemp -p "$SECRETS_DIR" ".${name}.XXXXXX")
    sudo systemd-creds encrypt --name="$name" - "$tmp"
    sudo install -m 400 -o root -g root "$tmp" "$SECRETS_DIR/$name"
    sudo rm -f "$tmp"
    echo "stored: $name (from stdin) → $SECRETS_DIR/$name"
    ;;

  list)
    if [ ! -d "$SECRETS_DIR" ]; then
      echo "(no secrets directory yet: $SECRETS_DIR)"
      exit 0
    fi
    # Just print basenames; never even acknowledge file size in a way that
    # could leak the value's length to a casual reader.
    sudo ls -1 "$SECRETS_DIR" 2>/dev/null | grep -v '^\.' || true
    ;;

  verify)
    require_arg "${1:-}"
    name="$1"
    if [ ! -f "$SECRETS_DIR/$name" ]; then
      echo "ERROR: $name not stored at $SECRETS_DIR/$name" >&2
      exit 1
    fi
    # Decrypt to /dev/null. systemd-creds returns 0 if the credential can
    # be opened on this host (TPM/host-key still valid), non-zero if not.
    if sudo systemd-creds decrypt "$SECRETS_DIR/$name" /dev/null 2>/dev/null; then
      echo "ok: $name decrypts on this host"
    else
      echo "ERROR: $name failed to decrypt — TPM/host-key may have changed" >&2
      exit 1
    fi
    ;;

  path)
    require_arg "${1:-}"
    echo "$SECRETS_DIR/$1"
    ;;

  ""|help|-h|--help)
    usage 0
    ;;

  *)
    echo "ERROR: unknown command '$cmd'" >&2
    usage 2
    ;;
esac
