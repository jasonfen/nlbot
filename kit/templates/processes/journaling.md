# Journaling

How <BOT_NAME> captures, compacts, and recalls what happened.

## Files

- `journals/journal.md` — running journal; entries append throughout the day
- `journals/YYYY-MM-DD.md` — nightly-synthesized daily file (narrative, not a log)
- `journals/YYYY-MM-summary.md` — monthly roll-up, 2–3 lines per day
- `journals/fiction/` — creative writing (not daily-compacted)

## Agents that touch journals

- `secretary` (every 30 min) — silently captures decisions / action items / journal-worthy moments from recent conversation, appends to `journal.md` and `inbox.md`. Does NOT overwrite.
- `journal-synthesizer` (midnight) — compacts `journal.md` → `journals/YYYY-MM-DD.md`, updates `journals/YYYY-MM-summary.md`, truncates `journal.md`.

## Date-heading rule

Journal entries use **local** time (the host's timezone — set in Step 9 of bootstrap). External services may emit UTC timestamps — don't copy those into journal headings. Use `date '+%Y-%m-%d %H:%M'` via bash.

## Memory layers

Two-layer write model:

1. **Vault files** (source of truth) — `journal.md`, `decisions.md`, handoffs/responses
2. **Memorious vector store** (semantic index) — `mcp__memorious-mcp__store` with 1–5 word keys (if the memorious-mcp baseline is installed; see [[memory]] in the kit)

When to store to memorious:
- Decisions made (with reasoning)
- Technical fixes (the problem + what worked)
- Facts about people, places, projects
- Anything worth finding by meaning, not literal word

When to search memorious (non-negotiable triggers):
1. Past events referenced — "remember when…", "last time we…"
2. Names/people you can't place
3. About to state a fact about history, decisions, or past work
4. After compaction / re-anchor
5. Topic with likely prior context

Vault + grep = literal search. Memorious = semantic/conceptual search. Store to both; prefer grep for exact hits, recall for topic sweeps.

## Re-anchor checklist (after compaction or restart)

1. Read `identity.md` — confirm canary phrase
2. Read `user-profile.md` — who <USER_NAME> is
3. Read `CLAUDE.md` — project instructions
4. Read `decisions.md` — choices we've made
5. Read `inbox.md` — open tasks
6. Read `journals/journal.md` — recent context
7. Check `soul-loop-log.md` — what you've been doing
8. `recall` from memorious for semantic sweep — "recent decisions", "current projects"
9. Verify crons with `crontab -l`
10. Grep for open `#handoff` tasks

## Invariants

- Every significant external-channel exchange gets a manual journal entry — the secretary misses what happens outside the main session.
- Always journal handoff work, even when the handoff doc itself already exists.
- Never store important info only in chat — the vault survives; conversations don't.
- After compaction, re-anchor from files; don't reconstruct from memory.
