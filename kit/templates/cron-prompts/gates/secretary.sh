#!/bin/bash
# Gate for the secretary cron. Reads the CURRENT SESSION TRANSCRIPT (the durable
# conversation record at ~/.claude/projects/<proj>/<session>.jsonl) instead of
# scraping the tmux pane — the pane scrape returns nothing under the fullscreen
# TUI (alternate screen: history_size=0, only the visible render is captured).
#
# Dedups on the latest real ${HUMAN_NAME} message; exit 0 (new input) writes the recent
# conversation to /tmp/secretary-context.txt for the runner and bumps the hash;
# exit 10 = noop (no new ${HUMAN_NAME} input).
set -uo pipefail
VAULT=${VAULT_DIR}
CTX=/tmp/secretary-context.txt
HASH_FILE="$VAULT/cron-prompts/.secretary-last-hash"
MARKER_FILE="$VAULT/cron-prompts/.journaled-through"
JOBLOG="$VAULT/cron-prompts/job-log.md"
PROJ="${HOME_DIR}/.claude/projects/${PROJECT_SLUG}"
stamp() { date '+%Y-%m-%d %H:%M'; }

# Newest transcript = the live session.
TR=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
if [ -z "$TR" ]; then
  echo "| $(stamp) | secretary | 0 | noop (no transcript found) |" >> "$JOBLOG"; exit 10
fi

# Extract clean conversation: real ${HUMAN_NAME} text + ${BOT_NAME} text. Real human input is
# identified STRUCTURALLY by origin.kind=="human", not by content regex.
#
# This used to select on promptSource=="typed", which silently dropped every
# message ${HUMAN_NAME} sent by accepting a suggestion (promptSource=="suggestion_accepted",
# origin.kind=="human") — 2 of 8 real messages on 2026-08-17. Because the dedup
# hash never advanced past those, the gate kept reporting "no new ${HUMAN_NAME} input" and
# nooping, so the secretary never saw them at all.
#
# origin.kind=="human" matches exactly the real messages; everything the harness
# injects as a "user" turn (task-notifications, hook feedback, monitor events)
# carries origin.kind=="task-notification", and tool results have no .origin.
# Keep this predicate identical to the one in ../human-msgs.sh.
FILTER='
def usertext:
  if (.message.content|type=="string") then .message.content
  elif (.message.content|type=="array") then ([.message.content[]|select(.type=="text")|.text]|join(" "))
  else "" end;
select(.type=="user" or .type=="assistant")
| if .type=="user" then
    select(.origin.kind=="human") | (usertext) as $t | select($t!="") | "HUMAN: " + ($t|gsub("\\s+";" "))
  else
    ([.message.content[]?|select(.type=="text")|.text]|join(" ")) as $t | select($t!="") | "BOT: " + ($t|gsub("\\s+";" ")) end
'

# Latest real ${HUMAN_NAME} message = dedup key (full text).
LATEST=$(jq -rc "$FILTER" "$TR" 2>/dev/null | grep '^HUMAN: ' | tail -1)
if [ -z "$LATEST" ]; then
  echo "| $(stamp) | secretary | 0 | noop (no ${HUMAN_NAME} input in transcript) |" >> "$JOBLOG"; exit 10
fi
NEW_HASH=$(printf '%s' "$LATEST" | sha256sum | cut -d' ' -f1)
LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
if [ "$NEW_HASH" = "$LAST_HASH" ]; then
  echo "| $(stamp) | secretary | 0 | noop (no new ${HUMAN_NAME} input) |" >> "$JOBLOG"; exit 10
fi

# Capture marker: the main session records (via mark-journaled.sh) how many ${HUMAN_NAME}
# messages it has already journaled. If that's caught up with the transcript, the
# proactive journal already covers this exchange and spawning the runner would cost
# ~35k tokens to be told "nothing new" — which is what happened 5x on 2026-08-17.
#
# COUNT, not a hash of the latest message: the transcript lags the live turn by one
# message, so a mid-turn marker would hash the PREVIOUS exchange and never match.
# See the long comment in mark-journaled.sh. (Shipped the hash version first and
# caught this before it ran for real.)
#
# Also deliberately NOT journal mtime — mtime says the journal was touched, not
# that THIS exchange was captured; it would suppress whenever anything unrelated
# was journaled after ${HUMAN_NAME} spoke, and fail silently. This fails safe instead: an
# absent or behind marker => the run happens, which is the pre-existing behaviour.
#
# This preserves the run as a self-nudge exactly where it's needed: if the main
# session did NOT journal, the marker falls behind and the secretary runs.
#
# The marker is `<session-id> <count>` and only counts for the transcript it was
# written against. Counts restart at 1 in every session, so a bare count from an
# old session (the pre-2026-09-10 format) would out-number the new one and
# suppress real input — it did, 12 times, with a marker stuck at 18. A marker
# from another session, or in the legacy one-field format, is ignored => run.
MARKED_SESSION=""; MARKED=""
read -r MARKED_SESSION MARKED < "$MARKER_FILE" 2>/dev/null || true
CUR_SESSION=$(basename "$TR" .jsonl)
HUMAN_COUNT=$("$VAULT/cron-prompts/human-msgs.sh" count 2>/dev/null || echo "")
if [ -n "$MARKED" ] && [ "$MARKED_SESSION" = "$CUR_SESSION" ] && [ -n "$HUMAN_COUNT" ] \
   && [ "$MARKED" -ge "$HUMAN_COUNT" ] 2>/dev/null; then
  echo "| $(stamp) | secretary | 0 | noop (journaled through #$MARKED >= transcript #$HUMAN_COUNT) |" >> "$JOBLOG"
  echo "$NEW_HASH" > "$HASH_FILE"   # bump so we don't re-evaluate this message every 30m
  exit 10
fi

# New input: write the recent conversation window for the runner + bump the hash.
#
# BOT lines are truncated to 200 chars; HUMAN lines pass through whole. Measured
# 2026-08-17: the window was 57,550 bytes of which ${HUMAN_NAME}'s messages were 584 (1.1%)
# — the runner was paying to re-read the main session's own already-journaled prose
# to find them. Truncation alone (rather than shrinking `tail -120`) cannot drop a
# message the gate wasn't already dropping. 57,550 -> ~20,757 bytes.
#
# LC_ALL=C.UTF-8 is REQUIRED, not cosmetic: cron runs without LANG set, and under
# C/POSIX `.{0,200}` counts BYTES, so a cut can land mid-multibyte-character and
# emit invalid UTF-8. Verified with a deliberate probe (3-byte em-dash straddling
# byte 200): C locale => invalid, C.UTF-8 => clean.
jq -rc "$FILTER" "$TR" 2>/dev/null | tail -120 \
  | LC_ALL=C.UTF-8 sed -E 's/^(BOT: .{0,200}).*/\1 …[truncated]/' > "$CTX"
echo "$NEW_HASH" > "$HASH_FILE"
exit 0
