#!/usr/bin/env bash
# FileChanged hook: fires when new-messages.txt is written by the polling daemon.
# Reads the file and injects its contents as context for Claude to act on.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIGGER_FILE="$SCRIPT_DIR/new-messages.txt"

if [[ ! -f "$TRIGGER_FILE" ]] || [[ ! -s "$TRIGGER_FILE" ]]; then
  exit 0
fi

CONTENT=$(cat "$TRIGGER_FILE")

# Escape content for safe JSON embedding (prevents prompt injection via
# crafted messages breaking out of the JSON heredoc)
ESCAPED=$(printf '%s' "$CONTENT" | jq -Rs .)

# Output JSON to inject context back to Claude
jq -n \
  --argjson escaped "$ESCAPED" \
  '{
    "systemMessage": "New Telegram message from ${HUMAN_NAME} — run /telegram-check to handle it.",
    "hookSpecificOutput": {
      "hookEventName": "FileChanged",
      "additionalContext": ("New Telegram messages arrived in .telegram/new-messages.txt:\n" + $escaped + "\n\nRun /telegram-check to process these.")
    }
  }'
