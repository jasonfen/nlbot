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
# Pseudo-code; real form lives in .claude/commands/soul-loop.md
HANDOFFS = sb-cmd.sh --lua 'index.queryLuaObjects("task", {limit=200})'
           filtered to: itags includes "handoff", not done,
                        itags excludes "blocked-on-human",
                        page not under _templates/
SECONDS_SINCE = NOW - cat <REPO_ROOT>/cron-prompts/.soul-loop-last-action
```

`HANDOFFS` queries SilverBullet's task index (`index.queryLuaObjects`), not a filesystem grep — see *Why SB index, not grep* below.

Decision tree:

| `HANDOFFS` | `SECONDS_SINCE` | Action |
|---|---|---|
| `> 0` | any | Spawn agent — real work pending |
| `== 0` | `< 3600` | Shell-only rest, no agent — keeps the creative-cycle budget |
| `== 0` | `>= 3600` | Spawn agent — time for a creative cycle |

Timestamp is updated *before* spawning so rate-limit holds regardless of what the agent chooses.

## Decision menu (inside the agent)

In priority order:
1. **Pending work** — open handoffs from SB's task index anywhere in the vault, filtered for `#handoff` tag, not-done, not `#blocked-on-human`
2. **Journal maintenance** — if `journals/journal.md` > 300 lines, compact into the daily file
3. **Check messaging channels** — poll for unanswered threads, if any
4. **Build something** — concrete task calls itself
5. **Create** — creative writing, fiction, drafts
6. **Explore** — codebase question that's been sitting in the back of my mind
7. **Remember** — memory consolidation, pruning
8. **Tidy** — vault hygiene, broken-link sweep
9. **Rest** — when none of the above crystallizes in 10 seconds

## Why SB index, not grep

The earlier implementation used `grep -rhn "\- \[ \].*#handoff" <VAULT>/handoffs/ <VAULT>/inbox.md`. Two failure modes pushed it to the SB index:

1. **Scope blindness.** Grep only checked `<VAULT>/handoffs/` and `<VAULT>/inbox.md`. Handoff checkboxes in journals, processes docs, or random subpages were invisible. Widening the grep to the whole vault then caught example checkboxes in doc prose (a kit doc legitimately had `- [ ] do the thing #handoff` as illustrative text) and inflated the count, causing soul-loop spawns with no real work.
2. **Parse-by-regex fragility.** `- [ ]` matches any open-checkbox-shaped string in the file, including code blocks, quoted snippets, and frontmatter.

`index.queryLuaObjects("task", ...)` returns every parsed task object SilverBullet sees, with its tag set and done-state already resolved. That's the same source `inbox.md`'s render template uses, same source `Page: From Template` reads. Asking the editor what it actually indexed beats re-inferring from raw text.

The filter set:

| Field | Condition | Why |
|---|---|---|
| `itags` | includes `"handoff"` | The handoff tag is what flags the work |
| `done` | falsy | Don't re-count completed handoffs |
| `itags` | excludes `"blocked-on-human"` | Skip handoffs waiting on operator input — spawning an agent to re-ack pure burn |
| `page` | not under `_templates/` | Exclude template prose (false positives from `meta/template/page` files) |

The filesystem fallback (`|| echo 0`) makes SB unavailability a safe degrade: the bot logs a shell-only rest rather than crashing.

## Invariants

- Every fire logs to `job-log.md`, even rests (with 0 tokens).
- Only non-rest, real-action fires get a row in `soul-loop-log.md`.
- Do not fabricate work when idle. Real rest > invented busywork.
- Ramp heartbeat / start immediately when a new `#handoff` lands; don't wait for next scheduled loop.
- Poll messaging channels while waiting on async deliverables; don't rest through a pending review.
