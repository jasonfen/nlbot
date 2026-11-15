#!/bin/bash
# Record that the main session has ALREADY journaled the current exchange, so the
# next secretary cron noops instead of spending ~35k tokens to report "nothing new".
#
# Usage:  bash cron-prompts/mark-journaled.sh
#
# Call this from the MAIN SESSION immediately after writing a journal entry that
# covers what ${HUMAN_NAME} just said. Do not call it speculatively — the whole safety
# property is that an unset/behind marker means the secretary runs.
#
# WHY A COUNT AND NOT A HASH: a hash records "the latest message at mark time".
# If the transcript is even briefly behind, that hash pins the PREVIOUS exchange
# and stops matching once the current one lands, silently disabling suppression.
# A count degrades gracefully instead — being behind just means the run happens.
#
# NO +1. An earlier version added one, on the belief that the transcript always
# lagged the live turn by exactly one message. That belief was wrong: the messages
# were present all along, but the gate's filter selected promptSource=="typed" and
# silently dropped everything ${HUMAN_NAME} sent via suggestion-accept. The filter bug
# fully explains the "missing" message; there was no lag to compensate for. The +1
# was therefore unjustified AND fail-unsafe — called from a cron-triggered turn
# (no human message in flight) it would over-claim by one and suppress the next
# real message unread. Removed. Do not reintroduce it without first proving a lag
# exists with the corrected filter.
#
# Consequence: if a message genuinely has not landed in the transcript when this
# runs, the marker simply comes up short and the secretary runs. That is the
# intended direction.
#
# Failure direction is deliberate:
#   marker missing / behind  -> secretary RUNS (status quo, nothing lost)
#   marker >= transcript     -> secretary skips (it would have found nothing)
# Never the reverse. Do not key this on journal mtime — mtime says the journal was
# touched, not that THIS exchange was captured, and it fails silent.
#
# SESSION-SCOPED (2026-09-10). The marker is `<session-id> <count>`. It used to be
# a bare count, which survived restarts: a marker of 18 from an old session made
# every newer session's lower count read as "already journaled", and the gate
# skipped real input 12 times 2026-08-22..09-10. The gate now ignores a marker
# whose session doesn't match the live transcript (and a legacy bare count), so a
# stale marker falls into the safe direction: the secretary runs.
set -uo pipefail
VAULT=${VAULT_DIR}
MARKER="$VAULT/cron-prompts/.journaled-through"

SESSION=$("$VAULT/cron-prompts/human-msgs.sh" session) || SESSION=""
COUNT=$("$VAULT/cron-prompts/human-msgs.sh" count) || COUNT=""
if [ -z "$SESSION" ] || [ -z "$COUNT" ]; then
  echo "mark-journaled: could not read transcript — marker NOT written" >&2
  exit 1
fi

printf '%s %s' "$SESSION" "$COUNT" > "$MARKER"
echo "marked journaled-through: ${HUMAN_NAME} message #$COUNT (session ${SESSION:0:8})"
