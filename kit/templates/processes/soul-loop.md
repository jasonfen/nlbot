# Soul Loop

The 10–30 minute heartbeat that runs when <BOT_NAME> is idle. Prevents "default to nothing" when there's real work queued.

## Canonical implementation

- **Cron driver:** system crontab, fires `/soul-loop` slash command via `cron-prompts/inject-prompt.sh`
- **Skill:** `.claude/commands/soul-loop.md` (shell triage) — runs Tier 1 pre-check, decides whether to spawn an agent
- **Agent:** `.claude/agents/soul-loop-runner.md` (decision menu, picks one action, logs the loop)
- **Log:** `soul-loop-log.md` (non-rest entries only); `job-log.md` (every fire incl. rest)

## Three-tier triage

The command reads two signals:

```bash
HANDOFFS=$(grep -rn "\- \[ \].*#handoff" <VAULT>/ ...)
SECONDS_SINCE=$(NOW - cat cron-prompts/.soul-loop-last-action)
```

Decision tree:

| `HANDOFFS` | `SECONDS_SINCE` | Action |
|---|---|---|
| `> 0` | any | Spawn agent — real work pending |
| `== 0` | `< 3600` | Shell-only rest, no agent — keeps the creative-cycle budget |
| `== 0` | `>= 3600` | Spawn agent — time for a creative cycle |

Timestamp is updated *before* spawning so rate-limit holds regardless of what the agent chooses.

## Decision menu (inside the agent)

In priority order:
1. **Pending work** — open handoffs grep-matched under `handoffs/`, `inbox.md`
2. **Journal maintenance** — if `journals/journal.md` > 300 lines, compact into the daily file
3. **Check messaging channels** — poll for unanswered threads, if any
4. **Build something** — concrete task calls itself
5. **Create** — creative writing, fiction, drafts
6. **Explore** — codebase question that's been sitting in the back of my mind
7. **Remember** — memory consolidation, pruning
8. **Tidy** — vault hygiene, broken-link sweep
9. **Rest** — when none of the above crystallizes in 10 seconds

## Grep patterns

- Open handoff: `- \[ \].*#handoff`
- Waiting-on-review: `- \[ \].*#review`
- Action items: `- \[ \].*#action`

Filter out: `templates/`, `node_modules`, `CLAUDE.md`.

## Invariants

- Every fire logs to `job-log.md`, even rests (with 0 tokens).
- Only non-rest, real-action fires get a row in `soul-loop-log.md`.
- Do not fabricate work when idle. Real rest > invented busywork.
- Ramp heartbeat / start immediately when a new `#handoff` lands; don't wait for next scheduled loop.
- Poll messaging channels while waiting on async deliverables; don't rest through a pending review.
