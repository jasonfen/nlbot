# Cron wake path — non-injecting cron triggers (2026-08-11)

Replaces
`inject-prompt.sh` (which pasted slash-commands into ${HUMAN_NAME}'s live pane) with a
notification-based, idle-gated trigger. The runners are unchanged — only the
trigger changed.

## Pipeline

```
crontab: cron-wake.sh <name>
  → cron-prompts/gates/<name>.sh   (Tier-1/Tier-2 in shell; exit 10 = rest, no wake)
  → if work: drop .cron-triggers/<name>  (context on stdout → file body)
cron-trigger-monitor.sh  (background Bash task, exits after a batch; re-armed by the main session)
  → polls .cron-triggers/ every 5s
  → emits "CRON <name> <ctx>" ONLY when the main session is idle, then rm's it
  → busy → hold + retry next cycle   (= idle-gate + queue-and-retry)
main session (this file)
  → routes the "CRON <name>" notification to the runner below
```

Invariant: the wake is always a notification; **nothing is ever pasted into
${HUMAN_NAME}'s active input.** Kill switch: `touch cron-prompts/.cron-wake-paused`.

## Routing table — on a `CRON <name> <ctx>` notification, spawn:

| Trigger | Runner (Agent tool) | Model | After it returns |
|---------|--------------------|-------|------------------|
| `CRON soul-loop HANDOFFS=.. DUE=.. SECONDS_SINCE=..` | `soul-loop-runner` (or main, see DUE) | haiku | update rest-streak (return `rest` → +1; else → 0); log result+tokens to `cron-prompts/job-log.md`. The gate already bumped `.soul-loop-last-action`, so do NOT bump it again. **`DUE>0`** (added 2026-09-26): bookmarked tasks have come due; the gate wrote them to `/tmp/soul-loop-due.txt` (`file:line: task`). **The main session reads that file and does the work itself.** These are commitments made in conversation and usually need judgment, e.g. a before/after measurement. Spawn the runner with the lines only for a purely mechanical task. Afterwards, tick the task, re-date it (snooze), or tag it `#blocked-on-human`. Otherwise it re-wakes every 10 minutes. |
| `CRON secretary` | `secretary` | haiku | log result to job-log |
| `CRON wake-up` | `wake-up-runner` | haiku | log |
| `CRON midnight-maintenance` | `journal-synthesizer` | sonnet | log |
| `CRON sb-mentions NEW=<n> <page>: <snippet>…` | **no runner yet** | — | read `/tmp/sb-mentions-new.txt` (full detail: page, snippet, by, replyTo, inComment per mention) and tell ${HUMAN_NAME}. Only write a signed on-disk reply if ${HUMAN_NAME} explicitly asks — no auto-reply agent exists for this one (${HUMAN_NAME}'s call, 2026-09-23: "not into our workflows yet"). |

The soul-loop-runner prompt (from `.claude/commands/soul-loop.md` Tier-3):
> Run the soul loop heartbeat. Claude is idle. Open handoffs: `<HANDOFFS>`. Time
> since last real action: `<SECONDS_SINCE>` seconds. The caller has already
> updated the last-action timestamp, so you do NOT need to update it.

## Arming (per session)

The poller runs under the Bash tool with `run_in_background: true` and
`CRON_MONITOR_EXIT_ON_TRIGGER=1`. It exits after a pass that emitted triggers. Read the
`CRON …` lines from the task output file, route them as above, then re-arm with the same
call. Arming steps: `.claude/commands/start.md`. A SessionStart hook
(`hooks/sessionstart-autoarm-cron.sh`) asks for a re-arm after a restart, and
`bin/start-claude.sh` sends `/start` at boot. The poller holds an flock singleton lock.
While it is down, triggers queue in `.cron-triggers/`, so they arrive late rather than lost.

Fallback: the Monitor tool with `timeout_ms: 1800000` (the tool's cap). It expires every
30 minutes and has to be re-armed each time, which is why the background form replaced it
on 2026-10-07.

## Per-cron notes

- **soul-loop** — live. Gate `gates/soul-loop.sh`. Proven end-to-end.
- **secretary** — live. Gate `gates/secretary.sh`. Reads the **session
  transcript** (`~/.claude/projects/${PROJECT_SLUG}/*.jsonl`, real input =
  `origin.kind=="human"`), not the tmux pane — switched 2026-08-11, filter fixed
  2026-08-17. The pane scrape is dead: it returns nothing under the fullscreen TUI.
  Route `CRON secretary` straight to the `secretary` **agent**. The old
  `/secretary` slash command was a leftover pane-scraper — running it on
  2026-09-10 is what convinced that session the secretary was still reading tmux.
  **Marker is session-scoped (fixed 2026-09-10).** `.journaled-through` holds
  `<session-id> <count>` (written by `mark-journaled.sh`), and the gate only
  honours it for the live transcript. It used to be a bare count, which
  survived restarts: stuck at 18, it made every newer session's lower count read
  as "already journaled" — 12 skipped real inputs 2026-08-22..09-10. A legacy
  bare count or other-session marker is now ignored, so the secretary runs.
  `/secretary` is stubbed to delegate to this gate.
- **wake-up / midnight-maintenance** — live. No gate (always fire at
  their scheduled time). Runners: wake-up-runner (haiku), journal-synthesizer (sonnet).
- `inject-prompt.sh` is retired.
- **sb-mentions, second source (2026-11-11):** the gate also scans `handoffs/**` on disk for lines tagged `#handoff` *without* `@${BOT_NAME}` (task lines and plain comment bullets), keyed per (page, normalised line) in `state/.sb-handoff-tags-seen`, with its own baseline. Backticked `` `#handoff` `` is ignored. Why: ${HUMAN_NAME}'s 08:01 third task and 08:11 inline comments on 11-11 carried no `@${BOT_NAME}`, so mentions never saw them and the soul-loop count (checkbox tasks only, every 10 min) was the only path. Backup of the previous gate: `gates/sb-mentions.sh.bak-2026-11-11`.
- **sb-mentions** — live 2026-09-23. Gate `gates/sb-mentions.sh`, every 5 min. Calls
  `identity.mentions("${BOT_NAME}")` over the Runtime API, keys each mention on
  sha1(page + normalised snippet + target) since `range`/`ref` shift on every
  edit, diffs against `cron-prompts/state/.sb-mentions-seen`. It does not skip
  "self-authored" mentions (that filter was removed 2026-09-26, because `by` comes from the
  page's `authors:` frontmatter and not from who typed the line). **Watcher + trigger only —
  deliberately no runner/auto-reply agent** (${HUMAN_NAME}'s call, 2026-09-23: "not
  into our workflows yet"). On `CRON sb-mentions`, the main session reads
  `/tmp/sb-mentions-new.txt` and tells ${HUMAN_NAME}; it does not reply on its own. **Exception (2026-09-24):** a mention that is an open `#handoff` task (the handoff templates add `@${BOT_NAME}`) is a **handoff pickup**: start the work per [[processes/handoffs]] (anchor the task, signed response subpage). Don't just relay it to ${HUMAN_NAME}.
  On `bridge_unavailable` the gate launches `bin/sb.sh ready` detached to warm the
  headless client for the next tick, then rests.
