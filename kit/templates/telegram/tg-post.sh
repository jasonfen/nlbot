#!/usr/bin/env bash
# Usage: ./tg-post.sh "message"        (message as argument)
#        ./tg-post.sh                  (reads from .telegram/message.txt)
#        echo "msg" | ./tg-post.sh -   (reads from stdin)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config"
MSG_FILE="$SCRIPT_DIR/message.txt"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config not found at $CONFIG" >&2
  exit 1
fi

source "$CONFIG"

# Determine message source
if [[ "${1:-}" == "-" ]]; then
  MSG=$(cat)
elif [[ -n "${1:-}" ]]; then
  MSG="$1"
elif [[ -f "$MSG_FILE" ]]; then
  MSG=$(cat "$MSG_FILE")
  rm -f "$MSG_FILE"
else
  echo "Usage: tg-post.sh [message]" >&2
  echo "  Or write message to $MSG_FILE and run without args" >&2
  exit 1
fi

if [[ -z "$MSG" ]]; then
  exit 0
fi

# Split and send messages over 4096 chars
send_part() {
  local text="$1"
  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": ${CHAT_ID}, \"text\": $(echo "$text" | jq -Rs .)}")

  local http_code
  http_code=$(echo "$response" | tail -1)

  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: sendMessage failed ($http_code)" >&2
    return 1
  fi
}

if [[ ${#MSG} -le 4096 ]]; then
  send_part "$MSG"
else
  # Split on paragraph boundaries
  while [[ ${#MSG} -gt 4096 ]]; do
    chunk="${MSG:0:4096}"
    # Try paragraph break
    idx=$(echo "$chunk" | grep -b -o $'\n\n' | tail -1 | cut -d: -f1)
    if [[ -z "$idx" ]]; then
      # Try line break
      idx=$(echo "$chunk" | grep -b -o $'\n' | tail -1 | cut -d: -f1)
    fi
    if [[ -z "$idx" ]]; then
      idx=4096
    fi
    send_part "${MSG:0:$idx}"
    MSG="${MSG:$idx}"
    MSG="${MSG#$'\n'}"
    sleep 0.5
  done
  [[ -n "$MSG" ]] && send_part "$MSG"
fi

echo "Posted to Telegram"
