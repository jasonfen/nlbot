#!/usr/bin/env bash
# tg-post.sh — queue a message for telegram-bot.service to send.
#
# Writes to .telegram/message.txt and exits. The running daemon
# (tg-bot.py, started by telegram-bot.service) polls that file every
# few seconds, sends the message via the Telegram API using its
# systemd-creds-loaded BOT_TOKEN, then deletes the file.
#
# This script does NOT need BOT_TOKEN or CHAT_ID — the daemon is the
# only thing that holds them. Keeping the secret reachable to fewer
# processes is the point of the systemd-creds migration.
#
# Usage:
#   ./tg-post.sh "message"          (message as argument)
#   ./tg-post.sh                    (no-op — message.txt is consumed by daemon)
#   echo "msg" | ./tg-post.sh -     (read from stdin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSG_FILE="$SCRIPT_DIR/message.txt"

if [[ "${1:-}" == "-" ]]; then
  MSG=$(cat)
elif [[ -n "${1:-}" ]]; then
  MSG="$1"
else
  if [[ -f "$MSG_FILE" ]]; then
    echo "Message already queued at $MSG_FILE (daemon will send it within a few seconds)."
    exit 0
  fi
  echo "Usage: tg-post.sh \"message\" | <(echo msg | tg-post.sh -)" >&2
  exit 1
fi

if [[ -z "$MSG" ]]; then
  exit 0
fi

# Atomic write so the daemon doesn't read a partial message mid-write.
tmp=$(mktemp "${MSG_FILE}.XXXXXX")
printf '%s' "$MSG" > "$tmp"
mv "$tmp" "$MSG_FILE"
echo "Queued to $MSG_FILE — daemon will deliver within a few seconds."
