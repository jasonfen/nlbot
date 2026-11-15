#!/usr/bin/env bash
# SessionStart hook: tell a fresh main-session context to orient.
# Fires on every source (startup, resume, clear, compact). After a compaction
# or restart the session no longer holds its identity or recent context, and
# until now recovering depended on the agent noticing it didn't know the canary
# phrase. This makes it automatic. It injects only a one-line reminder, not the
# bundle itself: orient.sh writes the ~22 KB bundle to a file, and the agent
# Reads it (see the header of orient.sh for why). Added 2026-09-11 at ${HUMAN_NAME}'s
# request.
SRC=$(jq -r '.source // "start"' 2>/dev/null || echo start)
NOW=$(date '+%Y-%m-%d %H:%M %A %Z')

jq -n --arg src "$SRC" --arg now "$NOW" '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ("Fresh context (" + $src + ", " + $now + "). Orient before anything else: run `bash ${VAULT_DIR}/bin/orient.sh`, then use the Read tool on the bundle file it names and read all of it (identity + canary, ${HUMAN_NAME}, today'"'"'s journal, yesterday, recent days). Then continue with the CLAUDE.md re-anchor checklist from step 2.")
  }
}'
