# Soul Loop

The 10-minute heartbeat that runs when ${BOT_NAME} is idle. Prevents "default to nothing" when there's real work queued.

## Canonical implementation (non-injecting wake path, 2026-08-11)

- **Cron driver:** system crontab fires `cron-prompts/cron-wake.sh soul-loop` (no injection).
- **Gate (Tier 1, shell):** `cron-prompts/gates/soul-loop.sh` — rest-vs-act backoff; exit 10 = rest (no wake), exit 0 = wake (drops a trigger + context).
- **Delivery:** `bin/cron-trigger-monitor.sh` (background task) delivers `CRON soul-loop …` as a **notification** when the session is idle; the main session routes it (see `processes/cron-wake-path.md`).
- **Agent (runner):** `.claude/agents/soul-loop-runner.md` (haiku) — decision menu, picks one action, returns; main session updates the rest-streak + logs.
- **Log:** `cron-prompts/soul-loop-log.md` (non-rest entries only); `cron-prompts/job-log.md` (every fire incl. rest).
- **Manual:** the `.claude/commands/soul-loop.md` slash-command still works for a hand-run in the pane; the cron path uses the gate, not the command.

## Triage (done by the gate, in shell)

The gate reads three signals:

- `HANDOFFS`: open `- [ ] … #handoff` lines in `handoffs/` and `inbox.md`, minus any line tagged `#blocked-on-human`.
- `DUE`: open tasks whose `[due: …]` has passed, in `inbox.md`, `handoffs/`, `projects/` (lines tagged `#blocked-on-human` are skipped).
- `SECONDS_SINCE`: seconds since `cron-prompts/.soul-loop-last-action`.

The backoff threshold is `3600 × 2^streak` seconds, where `streak` is the count of consecutive `rest` returns in `cron-prompts/.soul-loop-rest-streak` (capped at 5 for the exponent, and the threshold at 86400). So 1 h, 2 h, 4 h, 8 h, 16 h, then 24 h.

| `HANDOFFS` | `DUE` | `SECONDS_SINCE` | Action |
|---|---|---|---|
| `> 0` | any | any | Wake. Real work pending |
| any | `> 0` | any | Wake. A bookmark came due; the main session does it |
| `0` | `0` | `< threshold` | Shell-only rest, no wake. One line in `job-log.md` |
| `0` | `0` | `>= threshold` | Wake. Time for a creative cycle |

The gate bumps the timestamp *before* the wake, so the rate limit holds whatever the agent chooses. The main session must not re-run this triage or bump the timestamp again. After the runner returns it updates the rest streak (`rest` → +1, anything else → 0) and logs the result.

## Decision menu (inside the agent)

In priority order:
1. **Pending work** — open handoffs grep-matched under `handoffs/`, `inbox.md`; and **due bookmarks**: open tasks whose `[due: …]` has passed (the gate lists them in `/tmp/soul-loop-due.txt`; see [[collaboration]] → "Bookmarking tasks for later")
2. **Journal maintenance** — if `journals/journal.md` still holds entries dated before today (after 01:00), the midnight synthesis missed; catch up per `journal-synthesizer.md`
3. **Build something** — concrete task calls itself
4. **Create** — creative writing, fiction
5. **Explore** — codebase question that's been sitting in the back of my mind
6. **Remember** — memorious consolidation, memory pruning
7. **Tidy** — vault hygiene, broken-link sweep
8. **Rest** — when none of the above crystallizes in 10 seconds

## Grep patterns

- Open handoff: `- \[ \].*#handoff`
- Waiting-on-review: `- \[ \].*#review`
- Action items: `- \[ \].*#action`
- Due bookmarks: `- [ ] … [due: YYYY-MM-DD]` or `[due: YYYY-MM-DDTHH:MM]` in `inbox.md`, `handoffs/`, `projects/`. Date-only = 06:00 local. Parsed by the gate, not grep.

The handoff count is scoped to `handoffs/` and `inbox.md` so example checkboxes in docs are never counted.

## Invariants

- Every fire logs to `cron-prompts/job-log.md`, even rests (with 0 tokens).
- Only non-rest, real-action fires get a row in `cron-prompts/soul-loop-log.md`.
- Do not fabricate work when idle. Real rest > invented busywork.
- Ramp heartbeat / start immediately when a new `#handoff` lands; don't wait for next scheduled loop.
- Return honestly: if you did nothing substantive, return `rest`. Never claim an action you didn't actually take — false "work" returns wrongly reset the backoff streak and cause hourly empty cycles.
