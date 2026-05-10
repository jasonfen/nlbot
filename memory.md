# Memory & note-capture

Two recurring needs in any persistent-bot setup:

1. **Semantic recall** — finding what was discussed by *meaning*, not exact words. Grep handles exact strings; you also need a way to ask "that conversation about Factorio mod architecture" and get back the right journal entry without remembering the keywords.
2. **Background note-capture** — automatically writing down decisions, facts, and the texture of conversations as they happen, so the journal accumulates without you having to ask.

Both are patterns, not products. This kit ships **memorious** (semantic recall) and a **secretary subagent** (note-capture). They're well-tested with fenbot. They're also swappable — if memorious changes its API, or you prefer a different note-capture approach, the rest of the bot doesn't care.

The rest of this doc walks through both: how to set up the bundled implementations, plus what the swap-out points look like if you outgrow them.

> **What the bot does automatically vs. what needs your hands**
>
> During Step 9 of bot-driven setup, the bot installs memorious-mcp itself (`claude mcp add ...` and verifies it shows up in `claude mcp list`). You don't run any of the commands in this doc by hand for the standard install — they're here for reference, troubleshooting, and the swap-out paths if you want a different backend.
>
> The bot will *not* register a memory backend that doesn't already have its prerequisites met (Python 3.12+, `uv` if needed). Those come from `bootstrap.md`. If Step 9 fails, the bot posts a BLOCKER pointing you here.

## When grep is enough

For the first month while you have <30 journal entries, plain `grep -r "keyword" journals/` is fine — and the kit installs memorious anyway because adding it later is a hassle and the cost of "I don't need it yet" is essentially zero RAM. If you really want a grep-only setup, see the "Skip the memory backend entirely" subsection at the bottom of this doc.

## Installation (5 minutes)

**Prerequisites:**
- Python 3.12+ (check: `python3 --version`)
- `uv` package manager

**Install uv** (if you don't have it):

Linux/macOS:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Windows (PowerShell):
```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

**Then install memorious:**

```bash
claude mcp add memorious-mcp uvx memorious-mcp
```

That's it. Restart your Claude Code session (quit and reopen). Then try:
```
recall("test")
```

If it returns an empty results list, you're good — memorious is running.

## How to use it — The three commands

### 1. Store — Save something you want to find later

```
store("key phrase", "full context")
```

**Key:** 1–5 words, semantic and searchable. Examples:
- `"nate hobbies"` — what does Nate like to do?
- `"factorio mod architecture"` — design decisions for a specific project
- `"alice preferences"` — things another person told you they like
- `"bug fix: async race condition"` — technical solutions

**Value:** Full context. Don't abbreviate. You're writing this so your future self can *understand it immediately* without re-reading a journal.

**Bad:**
```
store("bug", "Fixed it with try-catch")
```

**Good:**
```
store("bug: async race condition", "Race condition in payment webhook handler. Multiple concurrent requests were writing to same file simultaneously. Solution: use lock file pattern with flock() before write, unlock after close. Tested with 100 concurrent requests, no conflicts.")
```

### 2. Recall — Search for something by meaning

```
recall("what do I like to do for fun")
recall("game development")
recall("person named alice")
```

Results come back with the key and value. Read the results, pick the one you need, and — if you want — read the full journal entry it came from via grep.

### 3. Forget — Remove a memory (optional, rarely needed)

```
forget("key to remove")
```

Use this when you want to purge outdated info or sensitive data (passwords, old email addresses, etc.).

## When to store — Decision tree

**Store when:**
- You made a decision and the reasoning is important — "Decided to focus on game dev over web work for the next 3 months because indie games are the thing that actually excites me"
- You learned something technical — "Python's asyncio requires explicit `.gather()` for concurrent tasks, not automatic like JS Promises"
- Someone told you a preference — "Alice prefers async communication, no Slack"
- You completed a project milestone — "Finished first version of Factorio mod, 500 lines Python, submitted to forum"
- You discovered a pattern about yourself — "I do my best creative work between 10–11am, after coffee, before emails"

**Don't store when:**
- It's already in your journal (the journal is the source of truth; vector memory is the index)
- It's recent enough that you'll remember it anyway (< 1 week old)
- It's temporary — "I'm tired today" doesn't need storing
- You have the exact text in a file somewhere (grep it instead)

**The rule:** If you'd want to find this 6 months from now using a *feeling* or *concept* rather than exact words, store it.

## Examples

### Personal project tracking

```
store("project: lego city modular", "Building a Lego city with modular buildings, 10x10 baseplate sections, working on minifig scale consistency, needs custom street parts, will eventually be 5x5 grid = 25 sections, each ~8-10 hours of building. Started May 2026.")

store("lego building techniques", "Masonry techniques help with stability: brick the walls so vertical seams don't align. Use corner braces on tall walls. Standard doorframe is 4x4 studs (minifig width + frame).")
```

### Hobby progress

```
store("hobby: shrimp tank", "20-gallon planted tank, cherry shrimp colony, TDS 150, PH 6.2, water changes 20% weekly. Colony started with 10, now ~40 visible. Losing some shrimplets to predation by other shrimp or fish. Need to research safe tank-mates.")
```

### Preferred workflow

```
store("work preferences", "Prefer deep work sessions (4+ hours uninterrupted). Batch communications (answer email 2x daily, not constantly). Morning 7–11am is peak focus. Afternoon best for meetings, reviews, async work.")
```

### Technical knowledge

```
store("postgres performance", "For large JSON columns: don't query inside JSON with complex logic. Denormalize the query to app layer. Indexes on integer primary keys are cheap; indexes on JSON paths are expensive unless specific operator classes used.")
```

## Combining grep and memorious

You have two tools. Use both.

| Question | Tool | Why |
|----------|------|-----|
| "Did I solve this error before?" | memorious — `recall("error type")` | You don't remember exact message |
| "Where's the exact error log?" | grep — `grep "error string" journals/` | You need the source file/timestamp |
| "What's my hobby?" | memorious — `recall("hobbies")` | You want meaning, not specific dates |
| "When did I do X?" | grep — `grep "specific project" journals/YYYY-MM-DD*` | You need exact dates |
| "What did I decide about X?" | memorious — `recall("X decision")` | You want reasoning, not dates |

## Privacy and security

Memorious stores data in `.memorious/` folder on your local disk. The data is:
- **Not encrypted** — anyone with access to your machine can read it
- **Not synced** — stays local only
- **Not backed up automatically** — you're responsible for backups

**Don't store:**
- Passwords, API keys, secrets (use environment variables instead)
- Sensitive personal data about others (names, addresses, relationships)
- Anything you wouldn't want on your machine unencrypted

## Troubleshooting

**"I installed memorious but `recall()` doesn't work"**
- Check Claude Code has memorious in its MCP list: `claude mcp list` should show `memorious-mcp`
- Restart Claude Code (quit and reopen)
- If still broken, check Python 3.12: `python3 --version`

**"Recall gives me results but they're not quite right"**
- Vector memory finds *meaning*, not exact matches. If you ask "What's my favorite color?" and stored "I like teal", it might return that, but it might also return "I prefer cool colors" from a different memory
- If the results aren't specific enough, use grep instead

**"I'm storing too much and recall is noisy"**
- This is normal! Prune occasionally: `forget()` old/outdated keys
- Be more specific with search: instead of `recall("projects")`, try `recall("game development projects 2026")`

## Next steps

1. **Install memorious** — run the command above, restart Claude Code
2. **Try storing** — write one memory about yourself: hobbies, preferences, a project, a decision
3. **Try recalling** — ask for that memory back: `recall("key phrase")`
4. **Use it naturally** — when you want to remember something, store it. When you want to *find* something, recall it

After a week, you'll have 10–20 stored facts about yourself, your projects, and your preferences. After a month, memorious becomes essential — grep alone won't scale.

## What else could you use for vector memory

A real survey, evaluated for **single-user, 2c/2GB Linux box, 5k–20k lifetime entries, MCP-native preferred, no cloud dependency, hobbyist ops budget** (May 2026). Vector memory is a replaceable component — Claude doesn't care which backend is wrapped behind `recall()` — but the options vary a lot in maintenance burden and lifespan.

### Honest framing first

For roughly the **first six months** while you have <30 journal entries, plain `grep -r "keyword" journals/` is strictly better than embeddings. SilverBullet's tag system (already in your stack) handles "find the note about X" with a coherent tagging discipline. Don't add vector memory before you actually need it. You'll know you need it when grep starts missing things you *know* are in the journal but you can't remember the words you used.

### Survivors worth a real look

| Option | Backend | Repo health (May 2026) | Scale ceiling | Setup LoE |
|---|---|---|---|---|
| **memorious-mcp** *(this kit's default)* | ChromaDB + sentence-transformers, local | 9⭐, single maintainer, last push Oct 2025 | ~50k entries before sluggish on 2GB | Low — `claude mcp add memorious-mcp uvx memorious-mcp` |
| **chroma-core/chroma-mcp** | Chroma persistent client | 544⭐, official, slowed after Sep 2025 | ~50k | Low — `uvx chroma-mcp --client-type persistent --data-dir ~/chroma` |
| **basicmachines-co/basic-memory** | Markdown files + SQLite hybrid index | 3k⭐, very active, org-backed | Effectively unbounded at this scale | Low — `uv tool install basic-memory` |
| **qdrant/mcp-server-qdrant** | Qdrant (separate Docker service) | 1.4k⭐, official, active | 1M+ vectors comfortably | Medium — extra Docker container + ~300MB RAM idle |
| **doobidoo/mcp-memory-service** | Pluggable: SQLite-vec / Chroma / Qdrant + knowledge graph + autonomous consolidation | 1.8k⭐, very active, single maintainer | Tens of thousands easily | Medium — more config surface |
| **iAchilles/memento** | SQLite + FTS5 + sqlite-vec + BGE-M3 | 11⭐, last push Oct 2025, single maintainer | ~100k | Low — single Node binary |

### Don't bother

- **Pinecone, Weaviate Cloud, Mongo Atlas Vector** — cloud SaaS, monthly cost, requires net.
- **Mem0 self-hosted** — runs Qdrant + Neo4j + Ollama in containers, 6–8 GB realistic. Wrong scale.
- **Postgres + pgvector** — running Postgres for one user storing 2k facts is operational overkill heavier than running Qdrant.
- **Milvus / Vespa / Vald** — designed for multi-node clusters.
- **Anthropic's `@modelcontextprotocol/server-memory`** — knowledge-graph in JSON, not a vector store. People confuse them.

### Recommended upgrade paths

**Path #1 — when memorious-mcp gets uncomfortable** (it's abandoned, broken on a Python bump, or your `recall()` queries are slow): **`basic-memory`**. Markdown files on disk means your memory survives the tool. Plays well with the SilverBullet vault you already run. Most actively maintained option in the survivor list.

```bash
uv tool install basic-memory
claude mcp add basic-memory basic-memory mcp
```

**Path #2 — for the curious-tinkerer** who wants a real vector DB and room to grow: **`qdrant/mcp-server-qdrant`** with Qdrant in Docker. Official on both sides, scales 100x past where you'd ever need, and the experience translates to professional work later.

```yaml
# Add to docker-compose.yml
qdrant:
  image: qdrant/qdrant
  volumes:
    - ./qdrant:/qdrant/storage
  ports: ["127.0.0.1:6333:6333"]
```

```bash
claude mcp add qdrant-memory uvx mcp-server-qdrant --qdrant-url http://localhost:6333
```

### Skepticism worth carrying forward

- `memorious-mcp`, `memento`, and most of the small-stars MCP "memory" servers are **single-maintainer hobby projects**. They work today; plan to migrate someday.
- `chroma-core/chroma-mcp` is official but commit velocity slowed after Sep 2025 — glance at the repo before installing.
- `basic-memory` and `qdrant/mcp-server-qdrant` are the two options here that pass a "still maintained in 12 months" smell test.
- Anything that demands **Docker + Neo4j + Ollama + Qdrant simultaneously** is not a hobbyist setup, regardless of how the README markets it.

The point: **don't build the rest of the bot around assumptions about which store you're using**. The store is the smallest piece.

## Secretary — the note-capture pattern

The other half of this doc. Different problem, different tool.

**The pattern:** every ~30 minutes, a background process scans the recent conversation context and silently appends what's worth remembering — decisions, action items, life texture — to your inbox and journal. You never see it run. You just notice the journal is fuller than you wrote.

**The bundled implementation:** `templates/secretary-agent.md` (also at the canonical `kit/templates/secretary-agent.md`) defines a Claude Code subagent with a "be silent, capture, exit" prompt, fired by cron at `:03` and `:33` past the hour (offset from the soul loop so they don't collide). Read that file directly — don't duplicate its contents here.

**Why it's separate from the soul loop.** The loop is *doing* (what should I work on next?). The secretary is *remembering* (what just happened?). Combining them makes both worse — the loop slows down checking conversation history, and note-taking gets skipped when the loop decides to build something instead. Two crons, two prompts, clear ownership.

**What the bundled secretary does NOT do:** auto-store to vector memory. We tested this on fenbot and it was strictly worse — it duplicated journal content as embeddings and made `recall()` results noisy. The right division of labor is: secretary writes the journal; the bot's main session decides when to call `store()` based on what's *interesting*. The canonical template documents this lesson; carry it forward in any reimplementation.

**Alternative implementations:**

- **Cron + LLM API call.** A shell script that scrapes the tmux pane, sends it to an external API, parses the response, appends to files. Fewer moving parts than a Claude Code subagent; loses the in-process tool access.
- **File-change hooks.** Trigger note-capture only when you actually had a conversation. More reactive, less periodic.
- **Just journal manually.** If you're disciplined about writing in the journal yourself, you don't need a secretary at all. The bot still gets the value (it reads the journal); you just lose the automation.

None of these are wrong. The bundled secretary subagent is what fenbot uses because the in-process approach is the cheapest way to get a real Claude reading the actual context. Pick what fits your style.

---

## Skip the memory backend entirely

If you genuinely want grep-only with no MCP memory backend at all, edit `setup-state.md` Current phase from `step-9-memory` to `done` before the bot reaches it (or after, if you change your mind later). The bot will skip the install and transition to operational mode without memorious registered. You can always add it back later by setting Current phase to `step-9-memory` and running `/setup` from the bot's tmux pane.

The bot's CLAUDE-nate.md instructs it to fall back to `grep` if `recall()` isn't available, so a memorious-less bot still works — you just lose the semantic search layer.

---

When Claude should automatically search memory: see the "Memory" section in `CLAUDE-nate.md`.
