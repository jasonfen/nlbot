Soul loop heartbeat. Three-tier triage to minimize token burn:

## Tier 1 — shell pre-check

Run this bash block to decide whether to spawn an agent at all:

```bash
# Setup-state check — if Current phase != done, route to setup-runner
# instead of soul-loop-runner. The heartbeat agent doesn't have the Agent
# tool in its toolset, so it can't itself dispatch setup-runner; catching
# this at the shell layer is cheaper than spawning the heartbeat agent
# just for it to ad-lib around the missing capability. Caught on nlbot-
# test 2026-05-11 when soul-loop-runner direct-edited setup-state.md
# instead of dispatching.
SETUP_PHASE=""
if [ -f <VAULT>/setup-state.md ]; then
  SETUP_PHASE=$(grep '^Current phase:' <VAULT>/setup-state.md 2>/dev/null | head -1 | sed 's/^Current phase: *//; s/[[:space:]]*$//')
fi

# Count open handoff tasks across the vault. Skip handoffs tagged
# #blocked-on-human — those can't progress without the user answering, so
# repeatedly spawning a 15-20k-token agent to re-ack the same blocker is
# pure burn. Handoffs need both tags for the short-circuit: #handoff and
# #blocked-on-human on the same checkbox line.
HANDOFFS=$(grep -rn "\- \[ \].*#handoff" <VAULT>/ 2>/dev/null | grep -v templates/ | grep -v node_modules | grep -v kit/ | grep -v CLAUDE.md | grep -v collaboration.md | grep -v "#blocked-on-human" | grep -v "\.conflicted" | wc -l)

# Time since the last non-rest soul loop (creative/handoff action)
LAST_ACTION_FILE=<VAULT>/cron-prompts/.soul-loop-last-action
NOW=$(date +%s)
if [ -f "$LAST_ACTION_FILE" ]; then
  LAST=$(cat "$LAST_ACTION_FILE")
else
  LAST=0
fi
SECONDS_SINCE=$((NOW - LAST))

echo "SETUP_PHASE=$SETUP_PHASE HANDOFFS=$HANDOFFS SECONDS_SINCE_LAST_ACTION=$SECONDS_SINCE"
```

## Tier 2 — decide

In priority order:

- **If `SETUP_PHASE` is non-empty AND not `done`:** setup is still in progress. Spawn `setup-runner` (Agent tool, `subagent_type: "setup-runner"`) with this prompt:
  > Read /home/<BOT_NAME>/<VAULT>/setup-state.md, find the Current phase, and execute that phase. One phase per dispatch. Update state when done. Return one line.

  Log the result to job-log.md as `setup` (not `soul-loop`). Display only the agent's one-line return value. Stop here.

- **If `HANDOFFS > 0`:** spawn the soul-loop agent — there's real work.

- **If `HANDOFFS == 0` AND `SECONDS_SINCE < 3600` (under 1 hour since last real action):** no agent. Log to job-log only (soul-loop-log.md only gets non-rest entries now):
  ```bash
  echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | 0 | shell-only rest |" >> <VAULT>/cron-prompts/job-log.md
  ```
  Stay silent. Stop here.

- **If `HANDOFFS == 0` AND `SECONDS_SINCE >= 3600`:** spawn the soul-loop agent — time for a creative cycle.

## Tier 3 — spawn agent

**First, update the last-action timestamp NOW** (before spawning) so the creative cycle rate limit stays enforced regardless of whether the agent picks `rest`:

```bash
date +%s > <VAULT>/cron-prompts/.soul-loop-last-action
```

Then spawn `soul-loop-runner` (Agent tool, `subagent_type: "soul-loop-runner"`) with this prompt:

> Run the soul loop heartbeat. Claude is idle. Open handoffs: `<HANDOFFS>`. Time since last real action: `<SECONDS_SINCE>` seconds. The caller has already updated the last-action timestamp, so you do NOT need to update it.

After the agent returns, log the result + `total_tokens` from the agent's usage block:
```bash
echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | <total_tokens> | <agent return value> |" >> <VAULT>/cron-prompts/job-log.md
```

Display ONLY the agent's one-line return value.
