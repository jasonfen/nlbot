# Memorious

Vector-store layer for semantic memory. Complements the vault (grep-literal) with meaning-search.

## Setup

- Backend: the `memorious-mcp` package, a local Chroma store in `.memorious/` at the vault root, launched by `bin/run-memorious.sh` (which pins `mcp<2` and runs `bin/memorious-localtime.py` so timestamps are local time)
- MCP surface exposed to Claude Code: `mcp__memorious-mcp__store`, `mcp__memorious-mcp__recall`, `mcp__memorious-mcp__forget`

## Three layers of memory, ranked by retrieval type

| Layer | Tool | Best for |
|---|---|---|
| **Vault files + grep** | `Grep` / `Bash grep -rn` on `journals/`, `decisions.md`, handoffs | Exact phrases, full context |
| **Vector memory (memorious)** | `recall`, `store`, `forget` | Meaning / concept — "that finance conversation" |
| **Auto-memory** | `~/.claude/projects/${PROJECT_SLUG}/memory/*.md` | Rules about me + ${HUMAN_NAME} + feedback, persists across conversations |

The vault is the source of truth. Memorious is the searchable index.

## When to search (non-negotiable)

1. Past events referenced — "remember when…", "last time we…", "didn't we already…" → `recall` + `grep journals/`
2. Names / people you can't place → grep + recall
3. About to state a fact about history, decisions, or past work → recall to verify before speaking
4. After compaction / re-anchor → recall on 2–3 concrete topic keys. Time phrases like "recent decisions" match nothing in a topic-keyed index; treat distance > 1.4 as no match
5. Topic with likely prior context → recall before discussing

**The rule:** if about to say "I think…" or "I'm not sure if…" about something that might be in history — SEARCH FIRST. Guessing when you could know is lazy.

## When to store

- Decisions made (with reasoning)
- Technical fixes (the problem + what worked)
- Facts about people, places, projects
- Anything you'd want to find in a month

Store format:
- `key`: 1–5 words, specific enough to be re-findable
- `value`: the full context — what, why, when, who

Also write to `decisions.md` and the relevant journal. Memorious is the index; vault files are the body.

## Auto-memory (the `memory/` folder under `~/.claude/projects/`)

Different from memorious — these are **human-curated rules** about:
- Who the user is (`user_*.md`)
- Standing feedback / preferences (`feedback_*.md`)
- Project state when slow-moving (`project_*.md`)
- External-system pointers (`reference_*.md`)

The `MEMORY.md` file is the index (≤200 lines, one line per memory). Memories get loaded automatically on conversation start.

Write a new memory when:
- User gives guidance (correction OR validated approach)
- A failure mode is worth avoiding next time
- A non-obvious pattern is worth preserving

## Correcting a memory

`store` on an existing key does not overwrite: it returns an id as if it worked, and `recall` still gives the old value. To correct an entry, `recall` the key first and note its nearest neighbours, `forget` the key, read `deleted_ids` in the response (`forget` matches by similarity and can delete neighbours too), re-`store` anything that was collateral, `store` the corrected value, then `recall` to verify.

## Invariants

- Never let memory become the only copy of something important. The vault is primary.
- When a memorious recall conflicts with current file state, trust the file and update/delete the stale memory.
- Vet memories before recommending from them — named paths, functions, flags may have moved. Grep-verify before acting.
- Snapshot memories (activity summaries, commit lists) are frozen in time. For "what's current?" prefer `git log` or reading the code.
