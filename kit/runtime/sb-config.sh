#!/usr/bin/env bash
# sb-config.sh — read/write SilverBullet runtime config via the HTTP API.
#
# Wraps SB's config surface so callers can inspect or modify settings
# without round-tripping through the UI or directly editing `CONFIG.md`
# (which loses any layered/runtime overrides SB applies).
#
# SB exposes its merged config at `GET /.config` (read), and respects
# config edits via `PUT /.fs/CONFIG.md` (which is what the UI does under
# the hood). This wrapper combines both — `get` queries the live merged
# view, and `set` round-trips through `CONFIG.md` so the change is
# durable and re-applied on container restart.
#
# AUTH: reads SB_AUTH_TOKEN from systemd-creds (sb-auth-token blob);
# falls back to the env var. Same auth surface as sb-cmd.sh.
#
# THREAT MODEL: the bearer goes into the curl `-H` argv, transiently
# visible in `/proc/<pid>/cmdline`. Acceptable on this kit's deployment
# model (single-tenant + Tailscale-isolated + same-uid `/proc`). See
# `processes/silverbullet.md` § *Supported pattern*.
#
# USAGE:
#   sb-config.sh get                    # print merged config JSON
#   sb-config.sh get <key>              # print one key (dotted path OK)
#   sb-config.sh edit                   # spawn $EDITOR on CONFIG.md
#
# EXAMPLES:
#   sb-config.sh get
#   sb-config.sh get indexInterval
#   sb-config.sh get plugs.0
#   sb-config.sh edit
#
# `set` is intentionally NOT implemented as a one-shot — programmatic
# mutation of a structured config file from a shell wrapper is a footgun
# (no schema awareness, easy to corrupt the file). `edit` opens the
# canonical CONFIG.md so the operator sees what they're changing. For
# bot-driven config updates, use `sb-cmd.sh --lua` to invoke SB's own
# config-mutation primitives, which are schema-aware.
#
# RETURN: JSON response on stdout; non-zero exit on HTTP/curl error.

set -euo pipefail

SB_URL=${SB_URL:-http://127.0.0.1:3001}
BOT_NAME=${BOT_NAME:-$USER}
SECRETS_DIR="/etc/${BOT_NAME}/secrets"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Resolve auth token. Prefer the encrypted blob over an env var.
if [ -z "${SB_AUTH_TOKEN:-}" ] && sudo test -f "$SECRETS_DIR/sb-auth-token" 2>/dev/null; then
  SB_AUTH_TOKEN=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-auth-token" -)
fi

if [ -z "${SB_AUTH_TOKEN:-}" ]; then
  echo "sb-config: no SB_AUTH_TOKEN found (env var unset, secrets blob missing)" >&2
  exit 2
fi

cmd="${1:-}"
key="${2:-}"

case "$cmd" in
  get)
    raw=$(curl -fsS --max-time 30 \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      -H "Accept: application/json" \
      "$SB_URL/.config")
    if [ -n "$key" ]; then
      # Convert dotted path to jq path (`indexInterval` → `.indexInterval`,
      # `plugs.0` → `.plugs[0]`). Simple translation; jq does the work.
      jq_path=$(echo ".$key" | sed -E 's/\.([0-9]+)/[\1]/g')
      printf '%s' "$raw" | jq "$jq_path"
    else
      printf '%s\n' "$raw" | jq .
    fi
    ;;

  edit)
    # Pull current CONFIG.md, let operator edit it locally, push it back.
    # Round-trips through the same /.fs endpoint sb-fs.sh uses, so SB
    # re-loads the merged config automatically.
    tmp=$(mktemp --suffix=.md)
    trap 'rm -f "$tmp"' EXIT
    curl -fsS --max-time 30 \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      "$SB_URL/.fs/CONFIG.md" > "$tmp"
    "${EDITOR:-vi}" "$tmp"
    # Only push if the operator actually changed something. cmp returns 0
    # for identical files; we want to push when they differ.
    current=$(curl -fsS --max-time 30 \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      "$SB_URL/.fs/CONFIG.md" 2>/dev/null || echo "")
    if [ "$(cat "$tmp")" = "$current" ]; then
      echo "sb-config: no changes; not writing." >&2
      exit 0
    fi
    curl -fsS --max-time 30 -X PUT \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      -H "Content-Type: text/markdown" \
      --data-binary @"$tmp" \
      "$SB_URL/.fs/CONFIG.md"
    echo
    echo "sb-config: CONFIG.md updated; SB will reload merged config within ~10s." >&2
    ;;

  ""|help|-h|--help)
    sed -n '2,/^# RETURN/p' "$0" | sed 's/^# \?//'
    exit 0
    ;;

  *)
    echo "sb-config: unknown command '$cmd' (expected: get | edit)" >&2
    exit 2
    ;;
esac
