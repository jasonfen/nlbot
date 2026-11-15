# The wake path

How scheduled work reaches the Claude session without anything being typed into it.

## The problem it solves

The earlier design had cron paste a slash command into the tmux pane (`inject-prompt.sh`, still described in the May kit). If you were typing at that moment, the paste landed in the middle of your input. That script is retired.

The rule now is that **a wake is a notification, never a keystroke**. Three alternatives were considered and rejected when this was designed:

- A headless `claude -p` per cron fire: a full process start each time, and blind to the main session's context.
- A `FileChanged` hook on a file cron writes: that hook only fires on the agent's own writes, not on writes by outside processes.
- Keeping the paste and improving busy-detection: any paste can still land mid-keystroke.

## The pipeline

```
crontab
  └─ cron-prompts/cron-wake.sh <name>
       ├─ cron-prompts/.cron-wake-paused exists → log "PAUSED", stop
       ├─ cron-prompts/gates/<name>.sh exists and is executable → run it
       │     exit 10    → log "GATE noop", stop
       │     other ≠ 0  → log "GATE error", stop
       │     exit 0     → its stdout becomes the trigger's context
       └─ write .cron-triggers/<name>  (atomically: temp file, then rename)

bin/cron-trigger-monitor.sh          one instance, holds an flock lock
  every 5 s, for each file in .cron-triggers/:
     session idle → print "CRON <name> <context>", delete the file
     session busy → leave it for the next pass
  after a pass that printed anything → exit

main session
  the poller's exit arrives as a background-task completion notice
  → read the CRON lines from the task's output
  → route each one (table below)
  → start the poller again
```

Properties that follow from this:

- **A cron with no gate file always triggers.** That is how the morning and midnight jobs work.
- **One pending trigger per cron.** The file is named after the cron, so a second fire while the first is still waiting overwrites it with fresh context. A long busy stretch does not produce a backlog.
- **Triggers are held, not dropped.** If the poller is not running, files wait in `.cron-triggers/` and are delivered when it comes back.
- **`cron-wake.sh` logs every decision** to `cron-prompts/inject.log` (the filename is a leftover from the old design).

### What "idle" means

`session_idle` in the poller looks at the tmux session named `claude`. It finds the pane whose foreground command is `claude`, or whose shell has a `claude` child process. Then:

1. It reads the pane title twice, 0.4 s apart. If the title changed, the spinner is animating and Claude is working.
2. It reads the cursor column twice, 0.2 s apart. If it moved, someone is typing.

If either differs, or if no such pane is found, the session counts as busy and the trigger stays.

That last case is a real failure mode. When the source system once started Claude through a wrapper script, the pane's foreground command became `bash` and the old check, which only matched `claude`, held every trigger for 36 hours while the poller process looked healthy. The check now also accepts a `claude` child. If you change how Claude is launched, verify a real trigger gets delivered afterwards.

## The gates

A gate is a shell script that answers "is there work?" without spending tokens.

| Exit | Meaning |
|---|---|
| `0`, with `KEY=VAL …` on stdout | There is work. Wake the session |
| `10` | Rest. The gate logs its own noop line |
| anything else | Treated as an error. No wake |

### `gates/soul-loop.sh`

Runs every 10 minutes. It wakes the session if any of these is true:

- **`HANDOFFS > 0`**: there is an open `- [ ] … #handoff` line in `handoffs/` or `inbox.md` that is not tagged `#blocked-on-human`.
- **`DUE > 0`**: an open task in `inbox.md`, `handoffs/` or `projects/` has a `[due: …]` that has passed and is not tagged `#blocked-on-human`. The matching lines go to `/tmp/soul-loop-due.txt` as `file:line: task`.
- **`SECONDS_SINCE >= THRESHOLD`**: enough time has passed since the last wake.

The threshold is the idle backoff. It is `3600 × 2^streak` seconds, where `streak` is the number in `cron-prompts/.soul-loop-rest-streak`, capped at 5 for the exponent, and the result is capped at 86400. So the gap between creative cycles goes 1 h, 2 h, 4 h, 8 h, 16 h, then stays at 24 h.

On a wake the gate writes the current time to `cron-prompts/.soul-loop-last-action` **before** it exits, so the rate limit holds even when delivery is delayed. It prints `HANDOFFS=n DUE=n SECONDS_SINCE=n`. On a rest it appends `| <time> | soul-loop | 0 | shell-only rest |` to `cron-prompts/job-log.md` and exits 10.

The gate owns this decision. The main session must not re-run the check when the notification arrives: the timestamp was bumped seconds ago, so a re-check always says "rest" and the creative cycle never happens. `.claude/commands/soul-loop.md` still carries the same check inline for manual runs, which invites that mistake.

The **streak** is maintained by the main session after the runner returns: `rest` adds one, anything else resets it to zero. A runner that claims work it did not do resets the backoff for nothing, which is why the runner prompt insists on an honest `rest`.

The handoff count is scoped to `handoffs/` and `inbox.md` on purpose. Scanning the whole vault picked up example checkboxes in documentation and spawned runners with nothing to do.

### `gates/secretary.sh`

Runs at :03 and :33. The secretary is a note-taker: it reads the recent conversation and writes down what the main session forgot to.

The gate reads the **session transcript**, the newest `.jsonl` in `~/.claude/projects/${PROJECT_SLUG}/`. It does not read the tmux pane; under Claude Code's fullscreen interface a pane capture contains only the visible screen.

1. It extracts real human messages, identified by `origin.kind == "human"`. An earlier version selected `promptSource == "typed"` and silently dropped every message sent by accepting a suggestion.
2. It hashes the latest human message. Same hash as `cron-prompts/.secretary-last-hash` means no new input: exit 10.
3. It checks the **journaled-through marker**, `cron-prompts/.journaled-through`, which holds `<session-id> <count>`. The main session writes it with `cron-prompts/mark-journaled.sh` right after journaling an exchange itself. If the marker is for the current transcript and its count is at least the number of human messages, the exchange is already covered: exit 10.
4. Otherwise it writes the last 120 turns to `/tmp/secretary-context.txt` as `HUMAN:` and `BOT:` lines, with bot lines cut to 200 characters, and exits 0.

The marker is tied to a session id because counts restart in every session. A bare count from an old session once outnumbered every newer session's count and suppressed twelve real runs. A marker from another session is ignored, so the failure direction is always "the secretary runs".

The secretary does not write to `decisions.md`. It appends proposals to `cron-prompts/proposed-decisions.md`, each with the evidence it has and the evidence it lacks, and the main session checks them before promoting any. That rule came after several runs recorded correct findings with invented provenance.

On a fresh vault the gate prints a "No such file" line for the missing marker; `touch cron-prompts/.journaled-through` in the setup avoids it.

### `gates/sb-mentions.sh`

Runs every 5 minutes. Covered in [silverbullet.md](silverbullet.md), "How the bot notices".

## Routing

When the main session receives a `CRON` line it spawns the matching agent with the Agent tool. This table lives in the vault as `processes/cron-wake-path.md`, where the bot reads it.

| Notification | Agent | Model | Afterwards |
|---|---|---|---|
| `CRON soul-loop HANDOFFS=.. DUE=.. SECONDS_SINCE=..` | `soul-loop-runner`, or the main session itself when `DUE > 0` | haiku | Update the rest streak. Log result and tokens to `job-log.md`. Do not bump the timestamp again |
| `CRON secretary` | `secretary` | haiku | Log to `job-log.md` |
| `CRON wake-up` | `wake-up-runner` | haiku | Log |
| `CRON midnight-maintenance` | `journal-synthesizer` | sonnet | Log |
| `CRON sb-mentions NEW=<n> …` | none | | Read `/tmp/sb-mentions-new.txt`, tell the human. A mention that is an open `#handoff` task is a handoff pickup |

For `DUE > 0` the main session reads `/tmp/soul-loop-due.txt` and does the work itself, then ticks the task, re-dates it, or tags it `#blocked-on-human`.

## The runner agents

Each runner is a Claude Code custom agent: a Markdown file in `.claude/agents/` with frontmatter naming its tools and model. It starts with an empty context, does one job, and returns one line. The work never enters the main session's context.

| Agent | Model | Job | Returns |
|---|---|---|---|
| `soul-loop-runner` | haiku | Works a decision menu top to bottom and takes the first item with something concrete: pending work, journal catch-up, build, create, explore, remember, tidy, rest. Rest is the default | `rest`, or `<verb> — <summary>` |
| `secretary` | haiku | Reads `/tmp/secretary-context.txt`. Appends journal entries and inbox items; proposes decisions | `nothing new` or `captured: …` |
| `wake-up-runner` | haiku | Weekday morning: orient, count open handoffs, health check, journal entry | `wake-up complete — N open handoffs` |
| `journal-synthesizer` | sonnet | After midnight: turns each past day's entries in `journals/journal.md` into `journals/YYYY/MM/DD.md`, adds a line to `journals/YYYY/MM.md`, and removes those entries so `journal.md` holds only today | one token per date handled, or `already-current` |

Every runner begins by running `bin/orient.sh` and reading the file it names.

The journal synthesizer catches up on every day that has no daily file yet, not only yesterday, so one missed night does not leave the sequence a day behind for good. It writes a short stub for a quiet day so the dates stay contiguous. The cron is at 00:15 and not before midnight because it never synthesizes the day in progress.

The health-check step in `wake-up-runner.md` was specific to the source network and has been cut down to its method: compare node by node, never by total; triage expected-offline devices before calling anything an alert; never `head` the node list. It has placeholders for your own device lists.

## `/start` and orientation

Two things have to happen in every new Claude session, and both need an agent turn.

**Arming the poller.** It is a background task of the session, started with the Bash tool and `run_in_background`. It dies with the session, and a hook cannot start one. `.claude/commands/start.md` does it:

1. `pkill -f 'cron-trigger-monitor\.sh'`. A poller left over from a dead session still holds the lock, and its output goes nowhere. A new one would exit behind it.
2. Start `CRON_MONITOR_EXIT_ON_TRIGGER=1 exec bash bin/cron-trigger-monitor.sh` in the background.
3. Confirm with `pgrep -af cron-trigger-monitor`.
4. Orient.

`bin/start-claude.sh` types `/start` once at boot, before anyone could be typing. The only other keystrokes a script sends to the pane are the `/exit` and Enter from `bin/claude-restart`, which waits for five idle seconds first. `hooks/sessionstart-autoarm-cron.sh` is the second line: on any session start where the poller is not running, it injects a reminder to arm it.

With `CRON_MONITOR_EXIT_ON_TRIGGER=1` the poller exits after each batch and the session re-arms it with the same call. The trade-off is that a trigger arriving mid-turn waits for the next tool boundary. The alternative is to run the script under Claude Code's Monitor tool, which streams each line as it is printed but expires after 30 minutes and has to be re-armed each time. The source system switched to the background form because the expiry notices were noise.

**Orientation.** `bin/orient.sh` writes one bundle to a fresh `/tmp/bot-orient.XXXXXX.md` and prints a two-line pointer to it. The bundle holds, in order:

1. the current local date, time and weekday,
2. `identity.md` and `user-profile.md`,
3. `journals/journal.md` (today so far),
4. yesterday's daily file,
5. the newest five day-entries from this month's and last month's summaries.

The agent then reads that file with the Read tool. The bundle goes to a file because a large Bash result reaches an agent only in part: the first version printed to stdout and a runner missed today's journal. `--stdout` prints it for a human. The date is in the bundle because agents that worked out the weekday themselves got it wrong three times in one month.

`hooks/sessionstart-orient.sh` fires on every session start, including after `/clear` and after a compaction, and injects a one-line instruction to run the script. The canary phrase in `identity.md` is the fallback for a compaction the hook somehow missed.

## Kill switch

```bash
touch cron-prompts/.cron-wake-paused     # freeze every cron wake
rm cron-prompts/.cron-wake-paused        # resume
```

`cron-wake.sh` checks for the file before running any gate. Triggers already written are still delivered.

## Adding a cron

1. A crontab line: `<schedule> ${VAULT_DIR}/cron-prompts/cron-wake.sh <name>`.
2. Optionally `cron-prompts/gates/<name>.sh`, executable, following the exit-code contract. Have it log its own noop to `job-log.md`.
3. An agent in `.claude/agents/<runner>.md`. Pick the cheapest model that does the job.
4. A row in the routing table in `processes/cron-wake-path.md`.
5. Test the gate by hand in both directions. A gate that can never exit 0 looks the same as a quiet day.

## Files

| Path | What |
|---|---|
| `cron-prompts/cron-wake.sh` | Cron entry point |
| `cron-prompts/gates/*.sh` | Gates |
| `cron-prompts/human-msgs.sh` | Shared transcript filter: `hash`, `count`, `session` |
| `cron-prompts/mark-journaled.sh` | Main session records "journaled through here" |
| `cron-prompts/inject.log` | Every `cron-wake.sh` decision |
| `cron-prompts/job-log.md` | Every gate rest and every runner result with tokens |
| `cron-prompts/soul-loop-log.md` | Non-rest loop actions and wake-ups |
| `cron-prompts/proposed-decisions.md` | The secretary's queue for review |
| `cron-prompts/state/` | Seen-key files for `sb-mentions` |
| `.cron-triggers/` | Pending triggers |
| `bin/cron-trigger-monitor.sh` | The poller |
| `.claude/commands/start.md` | Arm and orient |
| `.claude/agents/*.md` | Runners |
