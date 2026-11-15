# Memory

A Claude Code context lasts hours. After a restart or a compaction the session knows only what it reads back from disk. So the bot's memory is whatever it wrote down, and how well it can find it.

There are three layers. They hold different things and are searched differently.

| Layer | Where | Searched with | Good for |
|---|---|---|---|
| Vault files | `${VAULT_DIR}`: journals, `decisions.md`, `inbox.md`, handoffs | `grep` | Exact words, full context. The source of truth |
| Vector memory (memorious) | `${VAULT_DIR}/.memorious/` | `recall`, `store`, `forget` MCP tools | Finding something by meaning when you don't remember the words |
| Auto-memory | `~/.claude/projects/${PROJECT_SLUG}/memory/` | Loaded by Claude Code at session start | Standing rules: preferences, corrections, pointers |

## Layer 1: the vault

| File | Holds |
|---|---|
| `journals/journal.md` | Today's running journal. Entries are appended with a `### YYYY-MM-DD — ~HH:MM — <topic>` heading |
| `journals/YYYY/MM/DD.md` | One narrative file per past day, written by the journal synthesizer after midnight |
| `journals/YYYY/MM.md` | Monthly index: two or three lines per day, each linking to its daily file |
| `decisions.md` | Decisions and facts, with reasoning |
| `inbox.md` | Open tasks |
| `handoffs/YYYY/MM/DD.md` and `handoffs/YYYY/MM/DD/*.md` | Tasks you delegated, and the bot's write-ups |
| `cron-prompts/proposed-decisions.md` | Decisions the secretary proposed and nobody has verified yet |

Link to a day as `[[journals/YYYY/MM/DD|YYYY-MM-DD]]`. SilverBullet shortens wiki links to their last path segment, so without the alias the link reads "DD".

Who writes the journal:

- The **main session**, as it works. `CLAUDE.md` tells it to write during the session, not at the end, and to record the reasoning with the outcome.
- The **secretary**, twice an hour when you have said something new, for whatever the main session did not capture. After journaling an exchange itself, the main session runs `bash cron-prompts/mark-journaled.sh` so the next secretary run is skipped.
- The **journal synthesizer**, after midnight, which turns the day's entries into the daily file and empties `journal.md` of everything before today.

Timestamps come from `date` on the box. Agents are told never to infer the date or weekday.

## Layer 2: memorious

[memorious-mcp](https://pypi.org/project/memorious-mcp/) is a small MCP server over a local Chroma store. It gives the session three tools: `store(key, value)`, `recall(query)` and `forget(key)`.

### Install memorious

Run this from the vault directory, because the default `local` scope registers the server for the current directory's project only:

```bash
cd ${VAULT_DIR}
claude mcp add-json memorious-mcp \
  '{"type":"stdio","command":"${VAULT_DIR}/bin/run-memorious.sh","args":[],"env":{},"timeout":120000}'
jq '.projects["${VAULT_DIR}"].mcpServers' ~/.claude.json
```

`add-json` sets the 120-second per-server timeout in the same step. The shorter `claude mcp add memorious-mcp -- ${VAULT_DIR}/bin/run-memorious.sh` writes the same entry without `timeout`, which you'd then have to add to `~/.claude.json` by hand. Both forms were checked on Claude Code 2.1 in a scratch project on 2026-11-14 and produced exactly the source system's entry. Start a new session (or `/mcp` → Reconnect) to pick it up, then confirm that `recall` and `store` appear in the tool list.

`bin/run-memorious.sh` is one line:

```bash
exec uvx --with 'mcp<2' --from memorious-mcp python ${VAULT_DIR}/bin/memorious-localtime.py "$@"
```

Each part is there for a reason:

- **`--with 'mcp<2'`**. Unpinned, `uvx` resolves the newest dependencies on every launch. When the `mcp` SDK released 2.0.0 it renamed an exception class that the server's framework (fastmcp 2.14.1) still imported, the server died at startup, and the session had no memory tools with no error on screen. Revisit the pin when the framework supports 2.x.
- **`memorious-localtime.py`**. memorious-mcp 0.0.2 stamps entries in UTC, so anything stored in the evening carried tomorrow's date. The wrapper patches the timestamp call to local time at launch and converts old UTC stamps once. It patches at launch and not on disk because `uvx` can re-resolve the package into a new cache directory at any start. If the patch cannot be applied it prints a warning and the server runs unpatched.
- **`MCP_TIMEOUT=120000`** in `bin/start-claude.sh`, plus the per-server timeout. A cold `uvx` cache once spent more than the default 30 seconds downloading packages. The client gave up and the session ran without memory while the server itself was fine.

The store is `.memorious/` in the directory the server starts in, which is the vault. It is in `.gitignore`.

### When the tools are missing

1. Read the client's log first: `~/.cache/claude-cli-nodejs/${PROJECT_SLUG}/mcp-logs-memorious-mcp/*.jsonl`. It names the cause in one line.
2. An `ImportError` and a dead server is the pin. A `CONNECT_TIMEOUT` with a healthy server is the cold cache.
3. Run `bin/run-memorious.sh` by hand and read stderr. Be careful with what a hand run proves: the failed boot warmed the cache, so every later run succeeds.
4. `/mcp` in the session reconnects a failed server in place. A full restart is not needed.

### Sharp edges

- **`store` does not overwrite.** Storing under an existing key returns an id exactly like a successful write, and `recall` still returns the old value.
- **`forget` deletes neighbours.** It matches by similarity, not by exact key. One call on the source system returned three `deleted_ids` for one named key. The two extras were the nearest neighbours of that key.

So correcting an entry is a procedure:

1. `recall` the key and keep what comes back. Those neighbours are what is at risk.
2. `forget` the key and read `deleted_ids` in the response.
3. Re-`store` anything that was deleted by accident.
4. `store` the corrected value.
5. `recall` again and check the new text came back.

### Using it well

- **Keys are 1 to 5 words naming the topic**: `backup timer fix`, not `what I did today`.
- **Values carry the reasoning and the vault path** where the detail lives.
- **Query with topic words, not time words.** The index is keyed by subject. "Recent decisions" matches nothing and returns unrelated old entries at a high distance. Treat any hit with distance above 1.4 as no match.
- **Don't store what is not established.** The secretary may mirror journal and inbox entries to memorious, but not proposed decisions, because an entry is harder to retract than a line in a file.

## Layer 3: auto-memory

Claude Code keeps a per-project folder of Markdown notes and an index file, `MEMORY.md`, that it loads at the start of each conversation. On the source system these are short rule files in four kinds: `user_*` (who the human is), `feedback_*` (corrections and preferences), `project_*` (slow-moving state) and `reference_*` (pointers to systems and gotchas), with one line each in the index.

This layer needs no setup. Its job here is behavioural memory: "after a launcher change, prove a trigger is delivered", "tag a blocked handoff at the moment it blocks". Facts and history belong in the vault.

## How the layers work together

- **The vault is primary.** Nothing important lives only in memorious or only in chat.
- **Each layer points at the others.** A memorious entry names the vault path with the detail. A vault page names its memorious key, so finding the page by grep tells you what to `recall` for related material.
- **Link, don't duplicate.** The same content in two places drifts, and then you cannot tell which copy is current.
- **A `recall` hit is directions, not the answer.** Follow it to the file.
- **When a memory contradicts the files, the files win,** and the memory gets corrected or deleted. A stale memory is worse than none because it is trusted.

## When the bot must search

From `CLAUDE.md`. These are triggers, not suggestions:

1. A past event is referenced ("last time we…", "didn't we already…").
2. A name it cannot place.
3. It is about to state a fact about history or a past decision.
4. After a compaction or restart: `recall` on two or three concrete topics taken from `decisions.md` and `inbox.md`.
5. A topic that probably has prior context.
6. Before theorising about a bug. "Have I hit this before?" is a diagnostic step.
7. Before proposing a fix to anything automated. Find out when it was last touched and why.
8. After being corrected. The real answer is often already written down.

And one habit: search the mistakes, not only the work. The journal records what went wrong and why, and that half is skipped most often.

## When the bot must store

- Decisions, with the reasoning ("chose X over Y because Z").
- Technical fixes: the problem and what worked.
- Facts about people, places and projects.
- Anything it would want to find in a month.

Time-sensitive claims name the version, the date, or the condition that would make them wrong, so a later reader knows when to re-check.

## Re-anchoring after a restart

The checklist is at the end of `CLAUDE.md`. In short: run `bin/orient.sh` and read the bundle, read `collaboration.md`, `decisions.md` and `inbox.md`, check `cron-prompts/soul-loop-log.md`, `recall` a few concrete topics, check `crontab -l` and that the poller is running, and grep for open handoffs. The SessionStart hook starts this automatically.
