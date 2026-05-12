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
if [ -f <REPO_ROOT>/setup-state.md ]; then
  SETUP_PHASE=$(grep '^Current phase:' <REPO_ROOT>/setup-state.md 2>/dev/null | head -1 | sed 's/^Current phase: *//; s/[[:space:]]*$//')
fi

# Count open handoff tasks. Scoped to <VAULT>/handoffs/ + <VAULT>/inbox.md
# only — those are the canonical handoff locations. Scanning the whole
# vault picked up example checkboxes inside docs (silverbullet-setup.md
# line 94 had `- [ ] do the thing #handoff` as illustrative prose) and
# inflated the count, causing soul-loop-runner spawns with no real work.
# Skip handoffs tagged #blocked-on-human — they can't progress without
# the user answering, so spawning a 15-20k-token agent to re-ack the
# same blocker is pure burn. Handoffs need both tags for the short-
# circuit: #handoff and #blocked-on-human on the same checkbox line.
HANDOFFS=$(grep -rhn "\- \[ \].*#handoff" <VAULT>/handoffs/ <VAULT>/inbox.md 2>/dev/null | grep -v "#blocked-on-human" | grep -v "\.conflicted" | wc -l)

# Time since the last non-rest soul loop (creative/handoff action)
LAST_ACTION_FILE=<REPO_ROOT>/cron-prompts/.soul-loop-last-action
NOW=$(date +%s)
if [ -f "$LAST_ACTION_FILE" ]; then
  LAST=$(cat "$LAST_ACTION_FILE")
else
  LAST=0
fi
SECONDS_SINCE=$((NOW - LAST))

# *-blocker phases are human-action gates. The bot can't advance them by
# dispatching setup-runner — the runner just confirms "still waiting" and
# returns. Mirror the #blocked-on-human handoff skip: if Current phase
# ends with -blocker AND a BLOCKER line is still active in setup-state.md
# (not yet replaced with RESOLVED or removed), short-circuit to shell-
# only rest. When the human clears the BLOCKER line, the next loop falls
# through to normal setup-runner dispatch, which detects the resolution
# and advances Current phase.
BLOCKER_GATED=0
if [[ "$SETUP_PHASE" == *-blocker ]] && grep -q '^BLOCKER ' <REPO_ROOT>/setup-state.md 2>/dev/null; then
  BLOCKER_GATED=1
fi

echo "SETUP_PHASE=$SETUP_PHASE BLOCKER_GATED=$BLOCKER_GATED HANDOFFS=$HANDOFFS SECONDS_SINCE_LAST_ACTION=$SECONDS_SINCE"
```

## Tier 2 — decide

In priority order:

- **If `BLOCKER_GATED == 1`:** setup is parked on a `-blocker` phase with an active BLOCKER line. Bot can't advance until the human acts. Shell-only rest:
  ```bash
  echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | 0 | shell-only rest (setup blocker pending: $SETUP_PHASE) |" >> <REPO_ROOT>/cron-prompts/job-log.md
  ```
  Stay silent. Stop here.

- **If `SETUP_PHASE` is non-empty AND not `done`:** setup is still in progress. Spawn `setup-runner` (Agent tool, `subagent_type: "setup-runner"`) with this prompt:
  > Read /home/<BOT_NAME>/<REPO_ROOT>/setup-state.md, find the Current phase, and execute that phase. One phase per dispatch. Update state when done. Return one line.

  Log the result to job-log.md as `setup` (not `soul-loop`). Display only the agent's one-line return value. Stop here.

- **If `HANDOFFS > 0`:** spawn the soul-loop agent — there's real work.

- **If `HANDOFFS == 0` AND `SECONDS_SINCE < 3600` (under 1 hour since last real action):** no agent. Log to job-log only (soul-loop-log.md only gets non-rest entries now):
  ```bash
  echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | 0 | shell-only rest |" >> <REPO_ROOT>/cron-prompts/job-log.md
  ```
  Stay silent. Stop here.

- **If `HANDOFFS == 0` AND `SECONDS_SINCE >= 3600`:** spawn the soul-loop agent — time for a creative cycle.

## Tier 3 — spawn agent

**First, update the last-action timestamp NOW** (before spawning) so the creative cycle rate limit stays enforced regardless of whether the agent picks `rest`:

```bash
date +%s > <REPO_ROOT>/cron-prompts/.soul-loop-last-action
```

Then spawn `soul-loop-runner` (Agent tool, `subagent_type: "soul-loop-runner"`) with this prompt:

> Run the soul loop heartbeat. Claude is idle. Open handoffs: `<HANDOFFS>`. Time since last real action: `<SECONDS_SINCE>` seconds. The caller has already updated the last-action timestamp, so you do NOT need to update it.

After the agent returns, log the result + `total_tokens` from the agent's usage block:
```bash
echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | <total_tokens> | <agent return value> |" >> <REPO_ROOT>/cron-prompts/job-log.md
```

Display ONLY the agent's one-line return value.
