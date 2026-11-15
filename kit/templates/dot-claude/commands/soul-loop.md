Soul loop heartbeat. Three-tier triage to minimize token burn:

## Tier 1 — shell pre-check

Run this bash block to decide whether to spawn an agent at all:

```bash
# Count open handoff tasks. Scoped to handoffs/ + inbox.md only — those
# are the canonical handoff locations. Scanning the whole vault picked
# up example checkboxes in docs (e.g. a setup guide that has
# `- [ ] do the thing #handoff` as illustrative prose) and inflated the
# count, causing soul-loop-runner spawns with no real work. Skip handoffs
# tagged #blocked-on-human — they can't progress without ${HUMAN_NAME} answering,
# so spawning a 15-20k-token agent to re-ack the same blocker is pure
# burn. Handoffs need both tags for the short-circuit: #handoff and
# #blocked-on-human on the same checkbox line.
HANDOFFS=$(grep -rhn "\- \[ \].*#handoff" ${VAULT_DIR}/handoffs/ ${VAULT_DIR}/inbox.md 2>/dev/null | grep -v "#blocked-on-human" | grep -v "\.conflicted" | wc -l)

# Time since the last creative-cycle spawn.
LAST_ACTION_FILE=${VAULT_DIR}/cron-prompts/.soul-loop-last-action
NOW=$(date +%s)
if [ -f "$LAST_ACTION_FILE" ]; then
  LAST=$(cat "$LAST_ACTION_FILE")
else
  LAST=0
fi
SECONDS_SINCE=$((NOW - LAST))

# Exponential backoff on consecutive rests. A fixed 1h creative-cycle
# threshold meant that during a prolonged idle stretch (weeks) we spawned
# a ~20k-token agent every hour just to have it return "rest" — ~500k
# tokens/day to confirm nothing changed. Now each consecutive rest doubles
# the interval: 1h, 2h, 4h, 8h, 16h, capped at 24h. Any real work — a
# handoff, or a creative cycle that does something other than rest —
# resets the streak to 0 (see Tier 3), so the loop snaps back to a 1h
# cadence the moment there's momentum. During indefinite idle it settles
# to one creative cycle per day while preserving daily self-direction.
REST_STREAK_FILE=${VAULT_DIR}/cron-prompts/.soul-loop-rest-streak
STREAK=$(cat "$REST_STREAK_FILE" 2>/dev/null || echo 0)
[ "$STREAK" -gt 5 ] 2>/dev/null && STREAK=5
THRESHOLD=$((3600 * (1 << STREAK)))
[ "$THRESHOLD" -gt 86400 ] && THRESHOLD=86400

echo "HANDOFFS=$HANDOFFS SECONDS_SINCE_LAST_ACTION=$SECONDS_SINCE REST_STREAK=$STREAK THRESHOLD=$THRESHOLD"
```

## Tier 2 — decide

- **If `HANDOFFS > 0`:** spawn the agent — there's real work.
- **If the gate reports `DUE > 0`** (cron path only; this manual command does not parse due dates): overdue `[due: …]` bookmarks are listed in `/tmp/soul-loop-due.txt`. Handle them first, per `processes/cron-wake-path.md` (the main session does the work, then ticks, re-dates or blocks each one).
- **If `HANDOFFS == 0` AND `SECONDS_SINCE < THRESHOLD` (under the backoff interval since the last spawn):** no agent. Log to job-log only (cron-prompts/soul-loop-log.md only gets non-rest entries now):
  ```bash
  echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | 0 | shell-only rest |" >> ${VAULT_DIR}/cron-prompts/job-log.md
  ```
  Stay silent. Stop here.
- **If `HANDOFFS == 0` AND `SECONDS_SINCE >= THRESHOLD`:** spawn the agent — time for a creative cycle.

## Tier 3 — spawn agent

**First, update the last-action timestamp NOW** (before spawning) so the creative cycle rate limit stays enforced regardless of whether the agent picks `rest`:

```bash
date +%s > ${VAULT_DIR}/cron-prompts/.soul-loop-last-action
```

Then spawn `soul-loop-runner` (Agent tool, `subagent_type: "soul-loop-runner"`) with this prompt:

> Run the soul loop heartbeat. Claude is idle. Open handoffs: `<HANDOFFS>`. Time since last real action: `<SECONDS_SINCE>` seconds. The caller has already updated the last-action timestamp, so you do NOT need to update it.

After the agent returns:

1. **Update the rest streak** based on the outcome. If the agent's return value is `rest` (it chose to do nothing), increment the streak so the next creative cycle is further out. Otherwise — it did real work, or this was a `HANDOFFS > 0` spawn — reset the streak to 0 so the loop snaps back to a 1h cadence:
   ```bash
   # If the agent rested:
   echo $(( $(cat ${VAULT_DIR}/cron-prompts/.soul-loop-rest-streak 2>/dev/null || echo 0) + 1 )) > ${VAULT_DIR}/cron-prompts/.soul-loop-rest-streak
   # If the agent did real work (or HANDOFFS > 0):
   echo 0 > ${VAULT_DIR}/cron-prompts/.soul-loop-rest-streak
   ```

2. **Log** the result + `total_tokens` from the agent's usage block:
   ```bash
   echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | <total_tokens> | <agent return value> |" >> ${VAULT_DIR}/cron-prompts/job-log.md
   ```

Display ONLY the agent's one-line return value.
