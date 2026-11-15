#!/bin/bash
# Reads the live session transcript and reports on genuinely-typed ${HUMAN_NAME} messages.
#
#   human-msgs.sh hash    -> sha256 of the LATEST typed ${HUMAN_NAME} message
#   human-msgs.sh count   -> number of typed ${HUMAN_NAME} messages in the transcript
#   human-msgs.sh session -> id of the transcript being read (its basename)
#
# ONE implementation of the jq filter, shared by every caller, so the gate and the
# marker can never drift apart:
#   - gates/secretary.sh  (hash -> dedup key; count -> capture-marker comparison)
#   - mark-journaled.sh   (count -> records what the main session has journaled)
#
# TIMING: an earlier version of this comment claimed the transcript lags the live
# turn by one message, and mark-journaled.sh added +1 to compensate. That was
# wrong (the "missing" message was the promptSource filter bug below) and the +1
# was removed on 2026-08-17. See mark-journaled.sh.
#
# COUNTS ARE PER-TRANSCRIPT. A count only means something alongside the session
# it came from, so the marker stores both (`<session> <count>`). A bare count
# carried across a restart is how 18 from an old session suppressed 12 real
# secretary runs 2026-08-22..09-10.
set -uo pipefail
PROJ="${HOME_DIR}/.claude/projects/${PROJECT_SLUG}"
MODE="${1:-hash}"

TR=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
[ -z "$TR" ] && exit 1

# Real human input is identified STRUCTURALLY by origin.kind=="human", NOT by
# promptSource and not by a content regex.
#
# Keying on promptSource=="typed" (the original implementation) silently dropped
# every message ${HUMAN_NAME} sent by accepting a suggestion, which carries
# promptSource=="suggestion_accepted". Measured on the live transcript 2026-08-17:
#
#   promptSource        origin.kind         count
#   MISSING             NO-ORIGIN             302   tool results etc.
#   suggestion_accepted human                   2   <- REAL ${HUMAN_NAME}, was dropped
#   system              task-notification      52   harness injections
#   typed               human                   6   matched
#
# So 2 of 8 real messages were invisible — and because the dedup hash never
# advanced past them, the gate reported "no new ${HUMAN_NAME} input" and nooped. Keying on
# origin.kind matches exactly the 8 and nothing else; the harness injections are
# task-notification and stay excluded. It also won't need updating if another
# promptSource value appears.
FILTER='
def usertext:
  if (.message.content|type=="string") then .message.content
  elif (.message.content|type=="array") then ([.message.content[]|select(.type=="text")|.text]|join(" "))
  else "" end;
select(.type=="user")
| select(.origin.kind=="human")
| (usertext) as $t | select($t!="")
| "HUMAN: " + ($t|gsub("\\s+";" "))
'

case "$MODE" in
  hash)
    LATEST=$(jq -rc "$FILTER" "$TR" 2>/dev/null | tail -1)
    [ -z "$LATEST" ] && exit 1
    printf '%s' "$LATEST" | sha256sum | cut -d' ' -f1
    ;;
  count)
    jq -rc "$FILTER" "$TR" 2>/dev/null | grep -c '^HUMAN: ' || echo 0
    ;;
  session)
    basename "$TR" .jsonl
    ;;
  *)
    echo "usage: $(basename "$0") [hash|count|session]" >&2; exit 2
    ;;
esac
