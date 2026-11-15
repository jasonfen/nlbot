# How We Work Together

## Communication Layers

| Layer | Direction | How | When |
|-------|-----------|-----|------|
| **Terminal** | ${HUMAN_NAME} → ${BOT_NAME} | Type in `https://${BOT_NAME}-shell.${TAILNET}.ts.net` | Real-time conversation, hands-on work |
| **SilverBullet** | Both ways | Edit pages at `https://${BOT_NAME}-notes.${TAILNET}.ts.net` | Async notes, browsing the vault, checking the dashboard |
| **Handoffs** | ${HUMAN_NAME} → ${BOT_NAME} | Tag any task `#handoff` in SilverBullet | Async requests |
| **Slash templates** | ${HUMAN_NAME} → ${BOT_NAME} | `/handoff-task` or `/decision` in any page | Quick inline task or decision entry |
| **Page templates** | ${HUMAN_NAME} → ${BOT_NAME} | `${BOT_NAME}: New Handoff` from the command palette | Structured handoff with context |
| **Mentions** | Both ways | `@name` inside a task or comment on any page | Questions and answers in place |
| **Dashboard** | ${BOT_NAME} → ${HUMAN_NAME} | `dashboard.md`, live queries | At-a-glance vault state |
| **Inbox** | Both ways | `inbox.md`, native tasks with checkboxes | Track open work, click to update status |
| **Journal** | ${BOT_NAME} → ${HUMAN_NAME} | `journals/journal.md` | What happened, what was built, what was thought |

## Automated Processes

All scheduled processes are **durable system crons** that run through a
**non-injecting wake path**: the cron runs a shell gate, and if there's work, a
background poller delivers a **notification** the main session acts on by
spawning an isolated runner subagent. Nothing is pasted into the pane. Details:
`processes/cron-wake-path.md`.

| Process | Schedule | Runner (model) | What it does |
|---------|----------|----------------|--------------|
| **Soul loop** | `*/10` (gated: rest-vs-act backoff) | soul-loop-runner (haiku) | Checks handoffs, decides what to do, leaves a trace. Backs off during idle. |
| **Secretary** | `:03/:33` (gated: transcript dedup) | secretary (haiku) | Captures journal texture and tasks from the session **transcript**; proposes decisions and facts for review. |
| **Wake-up** | weekday morning | wake-up-runner (haiku) | Morning re-anchor + health check + journal. |
| **Midnight maintenance** | `0:15` | journal-synthesizer (sonnet) | Compacts the day's journal into a daily file + monthly summary. |
| **Vault mentions** | `*/5` (gated: new mentions only) | none (main session) | Wakes ${BOT_NAME} on a new `@${BOT_NAME}` mention or an untagged `#handoff` line under `handoffs/`. |

One background poller carries the wake path: `bin/cron-trigger-monitor.sh`
(idle-gated). `/start` arms it; `bin/start-claude.sh` sends `/start` at boot.

## Task States

Click checkboxes in SilverBullet to cycle:

| State | Symbol | Meaning |
|-------|--------|---------|
| Open | `[ ]` | Not started |
| In progress | `[>]` | Working on it |
| Done | `[x]` | Complete |
| Blocked | `[?]` | Waiting on something |
| Deferred | `[~]` | Parked for later |
| Urgent | `[!]` | Needs attention now |

The gates only count `[ ]` as open. A task in any other state does not wake the loop.

## Tags

| Tag | Purpose |
|-----|---------|
| `#handoff` | ${BOT_NAME} picks this up (see Handoff Process below) |
| `#blocked-on-human` | On a `#handoff` or `[due: …]` line: waiting on ${HUMAN_NAME}. The gates skip it |
| `#action` | Concrete task to do |
| `#idea` | Something to explore later |
| `#decision` | Record of a choice made |
| `#infra` | Infrastructure / system work |
| `#project` | Larger build effort |

## Addressing, replies and the Mention Inbox (SilverBullet 2.11+)

The in-vault request/reply channel.

- **A request to someone is an `@name` inside a task or a comment**, never loose prose:
  `- [ ] check the UPS dashboard @${BOT_NAME}` or `<!-- is this still needed? @${HUMAN_HANDLE} -->`.
  That puts it in the recipient's **Mention Inbox** (`Navigate: Mentions`, Ctrl-Alt-i).
- **${HUMAN_NAME}'s Mention Inbox is their queue** of things ${BOT_NAME} is waiting on. When ${BOT_NAME} needs a
  decision, it writes `@${HUMAN_HANDLE}` in a task or comment on the page it concerns, *as well as* saying so in chat.
- **Replies are signed**: end the reply block with `-- @${BOT_NAME}` (or `-- @${HUMAN_HANDLE}`). A signature credits;
  it does **not** re-queue the reply in anyone's inbox. Use `/sign` in the editor.
- **Closing a request**: tick the task, or Resolve/delete the comment, or remove the `@`. A mention in
  prose never closes.
- **Talking *about* a mention without making one**: put it in backticks, `` `@${BOT_NAME}` ``. Backticked
  and fenced mentions aren't indexed. Mentions inside HTML blocks (e.g. `<details>`) *are*.
- **Signatures are self-declared**, not authentication; git attribution (Revisions) is the real record.
- **Answering ${BOT_NAME}'s `@${HUMAN_HANDLE}` questions in place**: type the answer as a nested bullet
  under the question, **mention `@${BOT_NAME}` in it**, then tick the question:
  ```
  - [x] Option 1 or Option 2? @${HUMAN_HANDLE}
    - Option 2, the cable path is through finished walls @${BOT_NAME}
  ```
  The `@${BOT_NAME}` is what wakes ${BOT_NAME} (within 5 min). Ticking alone doesn't, and neither does a signature
  (`-- @${HUMAN_HANDLE}` credits without notifying), so keep `@${BOT_NAME}` in the text, not as the signature. A comment
  works too: `<!-- Option 2 @${BOT_NAME} -->`.
- ${BOT_NAME} is woken on new `@${BOT_NAME}` mentions by the `sb-mentions` cron gate (every 5 min). There is **no
  auto-reply agent**: the main session reads the mention and tells ${HUMAN_NAME}, and writes a signed reply on the
  page when asked to. A mention that is an open `#handoff` task is a handoff pickup: start the work.

## Review and rollback via Revisions

SilverBullet's managed revisions commit every page edit ~30 s after it settles. Use them as the review channel:
- **Before a multi-file or risky edit, ${BOT_NAME} pins a rollback point**: `./bin/sb.sh snapshot`
  (commits everything outstanding now; shows as author "SilverBullet", message "Manual snapshot").
  `./bin/sb.sh revlog [N]` lists recent commits. ${BOT_NAME} names the snapshot in its report so ${HUMAN_NAME} knows the "before" state.
- **${HUMAN_NAME} reviews with `Revision: Page History`** (colour diff per revision) and, on disagreement,
  **Restore** is one undo step, rather than asking ${BOT_NAME} to revert by hand.
- Authors in history: `${HUMAN_HANDLE}` (their edits), `External` (${BOT_NAME}'s on-disk edits), `SilverBullet` (manual
  snapshots), `snapshot-timer` (dot-path commits). See `processes/silverbullet.md`.

## Bookmarking tasks for later

To have ${BOT_NAME} do something **at a later time** ("check this tomorrow", "re-measure next week"),
put a normal task in [[inbox]] (or on a handoff or project page) with a **`[due: …]`** attribute:

```
- [ ] Compare CPU throttling before/after the power cap #action [due: 2026-09-27T09:20]
- [ ] Re-check the drive temps after the enclosure fan goes in [due: 2026-10-01]
```

- `[due: YYYY-MM-DD]` means due at **06:00** local that day. `[due: YYYY-MM-DDTHH:MM]` (or a space instead of `T`) means that exact time. Local time is the box's timezone (${TIMEZONE}).
- **What happens:** the soul-loop gate checks every 10 minutes. Once a due time has passed, it wakes ${BOT_NAME} whatever the idle backoff (like a handoff) and lists the task in `/tmp/soul-loop-due.txt`. The main session does the work.
- **Closing it:** ${BOT_NAME} ticks the task when done. If it can't be done yet, ${BOT_NAME} moves the date later (a *snooze*, with the reason on the line) or tags it `#blocked-on-human`. An overdue open task re-wakes ${BOT_NAME} every 10 minutes, so it can't be quietly forgotten.
- **A `[due: …]` on a line tagged `#blocked-on-human` never fires.** When snoozing a blocked item to a date, remove the tag.
- **Where it's scanned:** `inbox.md`, `handoffs/`, `projects/`. Not `processes/`, docs or journals, so writing about the syntax (like this page) never triggers it.
- **Seeing them:** [[dashboard]] → "Bookmarked for later", soonest first, tickable.
- Either side can add one: ${HUMAN_NAME} types it in SilverBullet; ${BOT_NAME} adds one whenever it says "I'll check back on X".

## Handoff Process

The primary async channel from ${HUMAN_NAME} to ${BOT_NAME}. Full detail: `processes/handoffs.md`.

**${HUMAN_NAME} creates a handoff:**
1. In SilverBullet, use `${BOT_NAME}: New Handoff` from the command palette (creates `handoffs/YYYY/MM/DD.md`)
2. Or type `/handoff-task` inline on any page to insert a quick `- [ ] #handoff @${BOT_NAME}` task (the mention is what gets it noticed outside `handoffs/` and `inbox.md`)
3. Or write `- [ ] description #handoff @${BOT_NAME}` by hand in `inbox.md` or under `handoffs/` (the `@${BOT_NAME}` is optional but puts it in ${BOT_NAME}'s Mention Inbox; ticking the task closes it)
4. Add context above the task. ${BOT_NAME} reads surrounding text to understand intent

**${BOT_NAME} detects and acts:**
1. The soul-loop gate runs every 10 minutes and counts open `- [ ] … #handoff` lines in `handoffs/` and `inbox.md` (not tagged `#blocked-on-human`). Any open one wakes the loop at once. The `sb-mentions` gate (every 5 minutes) also catches a new `@${BOT_NAME}` mention or a new `#handoff` line under `handoffs/`.
2. For each open handoff: read the page, read the context above the task, anchor the task (`$h-YYYY-MM-DD-<slug>`), act on it
3. Write the response as a subpage `handoffs/YYYY/MM/DD/<slug>.md` and link it under the task
4. Mark the task `[x]` when the deliverable is present, or tag it `#blocked-on-human` with the question

**Filing:** Daily handoff at `handoffs/YYYY/MM/DD.md` (tasks + context). Responses in the `handoffs/YYYY/MM/DD/` subfolder, one file per response, linked from the task list.

---

## URLs

| Service | URL |
|---------|-----|
| SilverBullet | `https://${BOT_NAME}-notes.${TAILNET}.ts.net` |
| Web terminal | `https://${BOT_NAME}-shell.${TAILNET}.ts.net` |

## Identities

| Platform | ${HUMAN_NAME} | ${BOT_NAME} |
|----------|-------|--------|
| SilverBullet account | ${HUMAN_HANDLE} | ${BOT_NAME} |

## Custom Tools

### Web Terminal (`web-terminal/`)

Custom Node.js app: Express + xterm.js + node-pty + WebSocket. Attaches to the `claude` tmux session (or `shell` with `?session=shell`). Auth via session cookie. Runs as `claude-web.service`.

---

## Ground Rules

- ${BOT_NAME} confirms before posting on any external platform
- "Resume" means do the work. Don't ask, don't report, just go
- ${BOT_NAME} searches the web before assuming feature limitations (the model's training has a cutoff)
- The vault is the source of truth, not the conversation window
- After compaction, re-anchor from identity files
