#!/usr/bin/env bash
# sb-fs.sh — read/write SilverBullet pages via the HTTP File API.
#
# Wraps `/.fs/<path>` so callers can talk to SB's view of the vault
# rather than going through bare filesystem. Useful when you want what
# SB *actually serves* (post-index, post-transforms) instead of what
# happens to be on disk, or when you want write→serve roundtrip in a
# single call instead of write-then-wait-for-index.
#
# AUTH: reads SB_AUTH_TOKEN from systemd-creds (sb-auth-token blob);
# falls back to the env var. Same auth surface as sb-cmd.sh.
#
# THREAT MODEL: the bearer goes into the curl `-H` argv, which means it
# transiently appears in `/proc/<pid>/cmdline` until the call returns.
# That is acceptable on this kit's deployment model (single-tenant box,
# Tailscale-isolated tailnet, same-uid `/proc` access only). See
# `processes/silverbullet.md` § *Supported pattern* and `processes/security.md`
# for the broader context. If the kit is ever adapted to multi-tenant or
# non-tailnet boxes, this wrapper needs to move behind a broker.
#
# USAGE:
#   sb-fs.sh GET <path>                 # read page; body to stdout
#   sb-fs.sh PUT <path>                 # write page; body from stdin
#   sb-fs.sh DELETE <path>              # remove page
#   sb-fs.sh LIST [<dir>]               # list pages in dir (default: root)
#
# EXAMPLES:
#   sb-fs.sh GET journals/journal.md
#   echo '# New note' | sb-fs.sh PUT inbox.md
#   sb-fs.sh DELETE handoffs/2026/05/13.md
#   sb-fs.sh LIST processes
#
# RETURN: response body on stdout; non-zero exit on HTTP/curl error.

set -euo pipefail

SB_URL=${SB_URL:-http://127.0.0.1:3001}
BOT_NAME=${BOT_NAME:-$USER}
SECRETS_DIR="/etc/${BOT_NAME}/secrets"

# Resolve auth token. Prefer the encrypted blob over an env var.
if [ -z "${SB_AUTH_TOKEN:-}" ] && sudo test -f "$SECRETS_DIR/sb-auth-token" 2>/dev/null; then
  SB_AUTH_TOKEN=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-auth-token" -)
fi

if [ -z "${SB_AUTH_TOKEN:-}" ]; then
  echo "sb-fs: no SB_AUTH_TOKEN found (env var unset, secrets blob missing)" >&2
  exit 2
fi

method="${1:-}"
path="${2:-}"

if [ -z "$method" ]; then
  echo "Usage: sb-fs.sh {GET|PUT|DELETE|LIST} <path>" >&2
  exit 2
fi

case "$method" in
  GET)
    [ -z "$path" ] && { echo "sb-fs GET: missing <path>" >&2; exit 2; }
    curl -fsS --max-time 30 \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      "$SB_URL/.fs/$path"
    ;;

  PUT)
    [ -z "$path" ] && { echo "sb-fs PUT: missing <path>" >&2; exit 2; }
    # Body from stdin. SB's PUT /.fs/<path> accepts the raw page content
    # as the request body. --data-binary @- preserves bytes exactly.
    curl -fsS --max-time 30 -X PUT \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      -H "Content-Type: text/markdown" \
      --data-binary @- \
      "$SB_URL/.fs/$path"
    echo  # response is empty on success; add newline for terminal clarity
    ;;

  DELETE)
    [ -z "$path" ] && { echo "sb-fs DELETE: missing <path>" >&2; exit 2; }
    curl -fsS --max-time 30 -X DELETE \
      -H "Authorization: Bearer $SB_AUTH_TOKEN" \
      "$SB_URL/.fs/$path"
    echo
    ;;

  LIST)
    # SB's index API lists all pages with metadata. Filter by path prefix
    # if a directory is provided.
    if [ -n "$path" ]; then
      curl -fsS --max-time 30 \
        -H "Authorization: Bearer $SB_AUTH_TOKEN" \
        -H "Accept: application/json" \
        "$SB_URL/.fs/" \
        | jq --arg p "$path/" '[.[] | select(.name | startswith($p))]'
    else
      curl -fsS --max-time 30 \
        -H "Authorization: Bearer $SB_AUTH_TOKEN" \
        -H "Accept: application/json" \
        "$SB_URL/.fs/"
    fi
    ;;

  *)
    echo "sb-fs: unknown method '$method' (expected GET|PUT|DELETE|LIST)" >&2
    exit 2
    ;;
esac
