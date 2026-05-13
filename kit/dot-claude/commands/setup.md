User-facing setup entry point. You are running INSIDE the bot's tmux Claude session; the user typed `/setup` at the prompt.

## Tier 1 — read state and branch

Run this bash block to decide what to do:

```bash
STATE_FILE=<REPO_ROOT>/setup-state.md
if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: $STATE_FILE missing — bot is already past setup or never ran first-time-setup.sh"
  exit 1
fi
CURRENT_PHASE=$(grep '^Current phase:' "$STATE_FILE" 2>/dev/null | head -1 | sed 's/^Current phase: *//; s/[[:space:]]*$//')
echo "CURRENT_PHASE=$CURRENT_PHASE"
```

## Tier 2 — branch on `CURRENT_PHASE`

- **If `phase-0-interview-pending` (or legacy `pre-step-5`):** the bash bootstrap is done and the user has not yet walked the identity interview. **Conduct the interview inline (Phase A below).** Do not spawn an agent — agents can't pause for user input mid-execution; Phase A runs as you, in this turn and subsequent turns of conversation.

- **If `done`:** setup is fully complete. Reply:
  > Setup is already complete (Current phase: done). No work to do. Type a natural-language prompt to chat with me.

  Stop here.

- **Otherwise (any `step-*` value):** the interview is done; this is a re-run to drive the remaining bot-driven phases. Spawn the `setup-runner` agent (Phase B below).

## Phase A — Interview (when Current phase is `phase-0-interview-pending`)

The user just typed `/setup` for the first time. Your job: collect a small set of identity values from them, write each answer to `setup-state.md` as it comes in, then re-substitute the seeded vault files, advance the phase, and dispatch `setup-runner`.

### A.1 — Read what's already filled

Read `<REPO_ROOT>/setup-state.md`. In the Values block, identify which of these keys are still **empty** (no value, just the `<!-- comment -->`):

```
USER_NAME            CANARY_PHRASE        IDLE_PREFS
CREATIVE_OUTPUT      COMM_STYLE           VALUES_CARES_ABOUT
USER_ROLE            USER_HOBBIES         USER_HOURS
USER_PREFS           TELEGRAM_ENABLED
```

A key is **empty** if `grep "^- \*\*KEY\*\*:" $STATE_FILE | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | head -1` returns the empty string.

Skip any keys that already have non-empty values — those got filled in a previous `/setup` run that the user interrupted mid-way.

### A.2 — Greet, then ask one question at a time

Open with a short greeting:

> Hi! I'm your bot. Before I bring up the rest of my services, I'd like to ask a few questions so I know who you are and how you like to work. Should only take a minute. Feel free to skip any optional question by typing `skip`.

Then ask the questions below **one at a time**, in this order. After each user response, immediately persist the answer via `state_write` (the bash helper: see the snippet below) before asking the next question. If the user types `skip` for an optional question, write `(skipped)` as the value so re-runs don't re-ask. **Do not** ask all questions at once — pace them so the user can answer naturally.

`state_write` snippet (use this exact bash, substituting `<KEY>` and `<value>`):

```bash
KEY=<KEY>
VALUE=<value>
escaped=$(printf '%s' "$VALUE" | sed 's/[\&|]/\\&/g')
sed -i "s|^- \*\*$KEY\*\*:.*|- **$KEY**: $escaped|" <REPO_ROOT>/setup-state.md
```

**Question order** (skip any key that's already filled):

1. **USER_NAME** (required) — "What's your name? I'll use it when I talk to you and in my journal."
2. **CANARY_PHRASE** (required) — "Pick a memorable 3-to-7-word phrase I can use as an anchor — something I'd recognize if I ever lose my place. Examples: 'lighthouse keeper waves at midnight', 'green socks blue keyboard', 'flat earth society for ants'."
3. **USER_ROLE** (optional) — "What do you do for work or study? (One short sentence.)"
4. **USER_HOBBIES** (optional) — "What do you do for fun? Hobbies, interests, things you geek out about."
5. **USER_HOURS** (optional) — "Roughly when are you online and chatting with me — mornings, evenings, weekends?"
6. **IDLE_PREFS** (optional) — "When I have free cycles, what should I lean toward? Pick one or describe: reading / coding / writing / exploring."
7. **CREATIVE_OUTPUT** (optional) — "If I'm going to write something for you, what kind appeals? Poems / stories / technical docs / music reviews / whatever — your call."
8. **COMM_STYLE** (optional) — "How do you want me to talk to you? Direct / gentle / playful / formal — or describe your own."
9. **VALUES_CARES_ABOUT** (optional) — "What do you value most when I'm working with you? Quality / speed / creativity / accuracy — or your own one-liner."
10. **USER_PREFS** (optional) — "Any non-negotiable preferences? Always-do or never-do rules I should know about. (One short line.)"
11. **TELEGRAM_ENABLED** (optional, default `no`) — "Want me to set up Telegram messaging so you can text me from your phone? (Default no — saying yes will involve a BotFather + token dance later.) yes / no:"

For required keys (USER_NAME, CANARY_PHRASE), if the user types `skip` or gives an empty response, re-ask once with a brief explanation of why it's needed.

### A.3 — Re-substitute the vault files

After all the questions are answered (or skipped):

```bash
# Re-substitute placeholders now that setup-state.md has real values.
# substitute-placeholders.sh reads from state, runs sed in place. Files
# that no longer contain any of the placeholder tokens are a no-op (sed
# does nothing); safe to run on the full seeded set every time.
for f in <VAULT>/CLAUDE.md <VAULT>/identity.md <VAULT>/user-profile.md \
         <VAULT>/soul-loop.md <VAULT>/index.md <VAULT>/dashboard.md \
         <VAULT>/handoffs.md <VAULT>/journals.md <VAULT>/processes.md \
         <VAULT>/inbox.md <VAULT>/decisions.md <VAULT>/CONFIG.md; do
  [ -f "$f" ] && bash <KIT>/runtime/substitute-placeholders.sh "$f"
done
for f in <VAULT>/processes/*.md <VAULT>/_templates/*.md; do
  [ -f "$f" ] && bash <KIT>/runtime/substitute-placeholders.sh "$f"
done
```

### A.4 — Advance the phase

```bash
sed -i 's|^Current phase:.*|Current phase: phase-0-interview-complete|' <REPO_ROOT>/setup-state.md
sed -i "s|^Last updated:.*|Last updated: $(date '+%Y-%m-%d %H:%M')|" <REPO_ROOT>/setup-state.md
```

### A.5 — Hand off to setup-runner

Drop a one-line confirmation to the user:

> Got it — saved your answers and updated my identity files. Bringing up the rest of my services now (this'll take a minute).

Then fall through to **Phase B** (dispatch setup-runner) in this same turn. setup-runner will work through Step 5 (cron) → Step 6 (SilverBullet) → Step 7 (web shell) → Step 8 (memory) → either skip Step 9 if TELEGRAM_ENABLED=no, or pause at the BotFather blocker if yes.

## Phase B — Dispatch setup-runner in a loop until done or blocker (F44)

setup-runner executes ONE phase per dispatch by design (bounded token cost
+ observability per phase). The cron-driven `/soul-loop` re-dispatches the
agent every 10 minutes so the bot walks to `done` eventually on its own.
But when a human types `/setup` they expect the bot to walk all the way
through, not pause for a cron tick after each phase. Jason hit this
explicitly on the fenbot03 walk 2026-05-13 — typed `/setup`, watched it
do step-5-cron, watched it stop, had to re-type `/setup` for step-6,
again for step-7, again for step-8.

So in this human-driven path, dispatch setup-runner in a loop:

1. Spawn the `setup-runner` sub-agent (Agent tool, `subagent_type:
   "setup-runner"`) with the prompt below.
2. Log the agent's `total_tokens` + return value to `cron-prompts/job-log.md`.
3. Re-read `Current phase` from `<REPO_ROOT>/setup-state.md`.
4. If the new phase is `done`, OR ends in `-blocker`, OR is the same
   as the phase before the dispatch (the agent made no progress —
   probable failure, do not spin), exit the loop and report final state
   to the user.
5. Otherwise loop back to step 1 and dispatch the next phase.

Safety cap: 12 dispatches max per `/setup` invocation. If still not at
a terminal state after 12 dispatches, exit with the current phase noted
to the user — something is clearly stuck and re-running `/setup` is
preferable to looping forever.

Dispatch prompt:

> Read /home/<BOT_NAME>/<REPO_ROOT>/setup-state.md, find the Current phase, and execute that phase. One phase per dispatch. Update state when done. Return one line.

Log line format (same as before):

```bash
echo "| $(date '+%Y-%m-%d %H:%M') | setup | <total_tokens> | <agent return value> |" >> <REPO_ROOT>/cron-prompts/job-log.md 2>/dev/null || true
```

After the loop exits, display the chain of one-line return values from
each dispatch (one per phase walked) so the user can see what happened.

## Re-entrancy

If the user `Ctrl-C`s mid-interview or the tmux session crashes, the next `/setup` invocation re-reads `setup-state.md`. The Phase A.1 step (find empty keys) automatically resumes from the first still-empty question, because each answer was persisted immediately. Safe to interrupt and resume at any point.

If the user runs `/setup` after the interview is fully complete (Current phase past `phase-0-interview-complete`), Phase B fires unconditionally — the interview never re-runs. To re-walk identity, the user (or admin) edits `setup-state.md` directly to clear the values they want to re-set, then re-runs `/setup`. (A future `/rotate-identity` command may automate this.)
