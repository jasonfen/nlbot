# Journaling

How ${BOT_NAME} captures, compacts, and recalls what happened.

## Files

- `journals/journal.md` — **today's entries only**; agents append at the end throughout the day, and the midnight synthesizer moves everything dated before today into daily files (no pointer lines left behind)
- `journals/YYYY/MM/DD.md` — nightly-synthesized daily file (narrative, not a log). Year/month folders, same as `handoffs/`.
- `journals/YYYY/MM.md` — monthly roll-up, 2–3 lines per day, each day's date label linking to its daily file. This is the index of past days (the SilverBullet page for the month folder)
- Links to a day are aliased with the date — `[[journals/YYYY/MM/DD|YYYY-MM-DD]]` — because SilverBullet's `shortWikiLinks` would otherwise render only "DD"
- Flat `journals/YYYY-MM-DD.md` / `journals/YYYY-MM-summary.md` is the layout retired 2026-09-11; treat any such path as the folder form
- `fiction/` + `fiction.md` (vault root, not under journals since 2026-09-11) — creative writing from the soul loop's Create option; `fiction.md` is the index

## Agents that touch journals

- `secretary` (every 30 min) — silently captures action items and journal-worthy moments from recent conversation, appending to `journal.md` and `inbox.md`. Does NOT overwrite. **It does NOT write to `decisions.md`** — since 2026-09-23 (${HUMAN_NAME}: *"secretary should propose decisions, not make them"*) it appends proposals to `cron-prompts/proposed-decisions.md`, and the main session verifies each against the real file or command before promoting it. Five runs in the preceding day had written decision entries whose findings were right but whose *provenance* was invented.
- `journal-synthesizer` (midnight) — turns each past day's entries in `journal.md` into `journals/YYYY/MM/DD.md`, adds the linked entry to `journals/YYYY/MM.md`, and removes those entries so `journal.md` is today-only. Late entries for an already-written day get appended to that daily file.

## Writing style

Journal prose follows [[processes/writing-style]] (distilled from the humanizer skill, adopted 2026-10-01). The secretary, wake-up and soul-loop runners check against that page. The journal synthesizer preloads the full skill and runs the daily narrative and monthly lines through it.

## Date-heading rule

Journal entries use **local** time (${BOT_NAME} runs in `${TIMEZONE}`). Don't copy UTC timestamps from other systems into journal headings. Use `date '+%Y-%m-%d %H:%M'` via bash.

## Memory layers

Two-layer write model:

1. **Vault files** (source of truth) — `journal.md`, `decisions.md`, handoffs/responses
2. **Memorious vector store** (semantic index) — `mcp__memorious-mcp__store` with 1–5 word keys

When to store to memorious:
- Decisions made (with reasoning)
- Technical fixes (the problem + what worked)
- Facts about people, places, projects
- Anything worth finding by meaning, not literal word

When to search memorious (non-negotiable triggers):
1. Past events referenced — "remember when…", "last time we…"
2. Names/people you can't place
3. About to state a fact about history, decisions, or past work
4. After compaction / re-anchor (use topic keys, not time phrases)
5. Topic with likely prior context

Vault + grep = literal search. Memorious = semantic/conceptual search. Store to both; prefer grep for exact hits, recall for topic sweeps.

## Re-anchor checklist (after compaction or restart)

1. Run `bash bin/orient.sh` and Read the bundle file it names — identity + canary, ${HUMAN_NAME}'s profile, current date and weekday, today's journal, yesterday's daily file, latest monthly-summary entries. Every runner subagent starts from the same bundle.
2. Read `collaboration.md` — how everything works
3. Read `decisions.md` — choices we've made
4. Read `inbox.md` — open tasks
5. Check `cron-prompts/soul-loop-log.md` — what you've been doing
6. `recall` on 2–3 concrete topic keys (not time phrases; distance > 1.4 = no match)
7. Verify crons with `crontab -l`
8. Grep for open `#handoff` tasks

## Invariants

- Always journal handoff work, even when the handoff doc itself already exists.
- Never store important info only in chat — the vault survives; conversations don't.
- After compaction, re-anchor from files; don't reconstruct from memory.
