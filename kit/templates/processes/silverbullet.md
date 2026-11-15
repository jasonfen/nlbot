# SilverBullet

How ${BOT_NAME} drives its own SilverBullet: the APIs, the tools, and the working
methods. Genericised from a running instance on **SilverBullet 2.12.0**,
multi-space mode. The Runtime API is marked experimental upstream, so re-check the
upstream docs at the running tag before trusting a detail here once SilverBullet
updates.

**Primary sources:**
- [Runtime API](https://silverbullet.md/Runtime%20API) and [CLI](https://silverbullet.md/CLI), the live docs site. The site is itself a SilverBullet space, so fetch raw with `curl -H 'X-Sync-Mode: true' 'https://silverbullet.md/.fs/Runtime%20API.md'`; a plain fetch returns an empty app shell.
- [The Runtime API](https://community.silverbullet.md/t/the-runtime-api/4009), the announcement thread. The server is deliberately "dumb" and all indexing and query intelligence lives in the browser client. So the Runtime API runs a headless Chrome client on the server, with sync turned off, at roughly 200–300 MB. Stated use cases include AI agents.

## What we run

| | |
|---|---|
| Image | pinned to an exact version in the compose file. `:latest` floats. Since 2.11 the default images include Chromium; `-slim` has none |
| Mode | multi-space. The vault is bind-mounted at `/data/spaces/vault` as one space. SilverBullet's own state lives in `${SB_DATA_DIR}` (mounted at `/data`) |
| Space | this repo, `${VAULT_DIR}`. Nothing moved on the host |
| URLs | `http://127.0.0.1:${SB_PORT}` on the box; `https://${BOT_NAME}-notes.${TAILNET}.ts.net` on the tailnet |
| Auth | per-account API tokens: `Authorization: Bearer <token>`. ${BOT_NAME}'s token is in `${SECRETS_DIR}/sb-token` (mode 600, outside the vault); `bin/sb.sh` reads it there. `SB_USER` / `SB_AUTH_TOKEN` are single-space-only and must not be set |
| Revisions | `managed`: SilverBullet auto-commits page edits into the vault's git repo about 30 s after quiet. It skips dotfiles, so `bin/vault-snapshot.sh` is the second committer for `.claude/` and other dot-paths |

**A binding prefix is the browser route only. Every API endpoint is at the server
root.** Measured while a space had the prefix `/vault`: `POST /.runtime/lua` →
`{"result":1}` but `POST /vault/.runtime/lua` → 405; `GET /.fs/` → JSON listing but
`/vault/.fs/` → HTML. A 401 on a prefixed path is the space login gate, not proof
the endpoint lives there.

**Space settings** live in `${SB_DATA_DIR}/spaces.json`, read at startup (restart
the container after editing; back it up first; keep owner and mode 600):
`revisions`, `spaceIgnore`, and `shell.enabled` (defaults to `false`; `bin/sb.sh
shell` and Space Lua `shell.run` need it).

**Boot-mode gotchas:** any legacy env var forces single-space, including
`SB_LOG_PUSH` (boot log: `boot mode: single-space (SB_LOG_PUSH is set)`). And
multi-space only initialises into an **empty** data folder, so a space must exist
before the vault is mounted into it.

## Tools

- **`bin/sb.sh`** — the everyday wrapper. `bin/sb.sh lua '<expr>'`, `script`, `cmd '<Command Name>'`, `query '<LIQ>'`, `get`/`put <path>`, `ls`, `logs`, `config`, `shell`, `ready`, `snapshot`, `revlog`. Header has the details. `shot` is dead: `/.runtime/screenshot` was removed in 2.11.
- **`bin/sb-render.cjs`** — renders a page as a logged-in browser via Playwright and prints its visible text plus a screenshot. Needs a browser login (user:password), not the API token. Cold-profile gotcha in its header.
- **Direct disk edits** — the space is this repo, so plain file writes are picked up by the server. For *content*, edit files. Use the APIs for what only the client knows: the index, queries, rendering, commands, config.

## HTTP API (server)

Source: upstream `docs/HTTP API.md`.

| Endpoint | Does |
|---|---|
| `GET /.fs` | JSON listing of every file the space exposes. **2.11+ does NOT read `.gitignore`**; hiding is the per-space `spaceIgnore` field in `spaces.json`. Anything missing here is invisible to SilverBullet, and anything listed here is indexed and committed by managed revisions |
| `GET/PUT/DELETE /.fs/<path>` | read / write / delete a file. Send `X-Sync-Mode: true` (otherwise a browser-style GET may redirect to the UI). Ignored files are still **served** on a direct GET, so a 200 proves nothing about visibility |
| `GET /.ping` | `OK` (no auth) |
| `GET /.config` | readOnly, spaceFolderPath, indexPage, revisions, … |
| `POST /.shell` | run a shell command server-side, in the container (needs `shell.enabled`) |
| `POST /.revisions/` | commit everything outstanding now (`bin/sb.sh snapshot`); `GET /.revisions/?limit=N` lists commits (`bin/sb.sh revlog`) |

## Runtime API

Source: upstream `docs/Runtime API.md`. Evaluates Lua **inside a real SilverBullet
client**: a headless Chromium the server drives. So it has the full client API
(`editor.*`, `space.*`, the index, queries, commands), and results reflect live
client state.

| Endpoint | Does |
|---|---|
| `POST /.runtime/lua` | body = one Lua expression → `{"result": …}` |
| `POST /.runtime/lua_script` | body = a script with explicit `return` |
| `GET /.runtime/logs?limit=&since=` | headless client console |

- `X-Timeout: <s>` header (default 30; `bin/sb.sh` sends 60, override with `TIMEOUT=`).
- Errors: 500 `script_error`, 503 `bridge_unavailable` (no browser yet), 504 `timeout`.
- **Lifecycle:** Chromium starts on the *first* runtime call, then boots the client and indexes the space, so the first call is slow and returns 503 until it's ready. Run `bin/sb.sh ready` (polls for up to 3 minutes).
- If it never comes up, check `docker logs silverbullet 2>&1 | grep -i chrome`. A container uid with no writable home needs `HOME=/tmp` in the compose file, or Chromium's crash handler aborts.

## Space Lua API surface

The docs pages are generated from `plug-api/syscalls/*.ts`, so read the source at
the **running tag** for exact signatures. The same API docs are in the space itself
under `Library/Std/APIs/`.

| Module | Key functions |
|---|---|
| `space` | listPages, readPage, writePage, deletePage, pageExists, getPageMeta, listFiles, readFile, writeFile |
| `editor` | getCurrentPage, navigate, invokeCommand, getText/setText, flashNotification, reloadUI, reloadConfigAndCommands, … |
| `index` | queryLuaObjects, tag, getObjectByRef, reindexSpace |
| `system` | invokeCommand, listCommands, listSyscalls, getVersion, getConfig |
| `config` | get, set, has, define |
| `identity` | mentions(name), define. `identity.mentions("${BOT_NAME}").mentions` is what the `sb-mentions` gate reads |
| `shell` | run (returns exit code/stdout; it does **not** raise on failure, so check the code) |
| define-style | `command.define`, `slashCommand.define`, `tag.define`, `taskState.define`, `virtualPage.define`, `template.new` / `template.each` |

Useful one-liners, once the runtime is up:

```bash
./bin/sb.sh lua 'system.getVersion()'
./bin/sb.sh lua 'system.listCommands()'                       # every command-palette entry
./bin/sb.sh cmd 'System: Reload'                              # or 'Space: Reindex'
./bin/sb.sh query 'from index.tag "page" order by lastModified desc limit 5 select name'
./bin/sb.sh lua 'config.get("shortWikiLinks")'
```

## Methods and gotchas (paid for)

- **Config lives in `CONFIG.md`** as `space-lua` blocks. The schema is validated as a whole, so **one bad key rejects the entire CONFIG**. `taskStates` is an object keyed by checkbox character. After a change, run `System: Reload` or reload the client.
- **A `space-lua` block is all-or-nothing.** An error partway through aborts everything after it in that block, silently. Lua errors surface in the **browser console**, not in `docker logs`. Put `command.define` in its own block, before anything that can throw.
- **SilverBullet serves every file in the vault to any logged-in account**, dotfiles included: `GET /.fs/<path>` returns it even though dotfiles are left out of the listing, and `spaceIgnore` only filters the listing and index, not a direct read. Never keep a secret in the vault; they live in `${SECRETS_DIR}`.
- **`.gitignore` is not a visibility switch in 2.11+.** Hide paths with `spaceIgnore` in `spaces.json`: newline-separated gitignore-style patterns. In multi-space mode the `SB_SPACE_IGNORE` env var is ignored. Ignore `node_modules/` at least. `.gitignore` still controls git, and so what managed revisions commit.
- **Folders:** the page `foo.md` is the page *for* folder `foo/`, as a sibling, not `foo/index.md`. That's why monthly summaries are `journals/YYYY/MM.md`.
- **No empty first header cell in tables:** SilverBullet drops a blank leading header cell (`| | A | B |`), so every title shifts one column left. Label it.
- **`shortWikiLinks` is on by default:** `[[a/b/c]]` renders as "c". Alias links whose last segment isn't meaningful: `[[journals/2026/09/10|2026-09-10]]`.
- **Queries** (Space Lua Integrated Query): `query[[from index.tag "page" where … order by … limit N]]`. Lua patterns work in `string.find(_.name, "^journals/%d%d%d%d/%d%d$")`. Query widgets fill in only after the client has indexed, so a cold client shows empty lists.
- **Space Lua helpers belong on a meta page, not the page they serve:** a `space-lua` block renders as a visible code listing. Put helpers in a separate page tagged `meta`.
- **Page templates:** a page tagged `meta/template/page`, with `command:`, `suggestedName:` and `confirmName`. See `templates/handoff.md`.
- **Page names:** no dots. SilverBullet treats a dot as a file extension.
- **Moving or renaming files on disk:** open browser tabs can write a page back to its old path. Tell ${HUMAN_NAME} to reload tabs after big moves.
- **Trust the source, not threads:** check the code or docs at the running tag, not `main` and not community posts.
- **Verify renders for real** in the live client: `sb.sh lua 'editor.navigate("page")'`, then read the DOM with a `sb.sh script` (`js.window.document.querySelectorAll(…)`). Build a control first (a known-good page) before calling an empty result a bug. Three traps: **the editor only renders widgets in the viewport**, so scroll first (`editor.moveCursor(#editor.getText(), true)`) or lower sections look empty; **JS-interop NodeLists are 1-indexed** (`nodes[0]` is nil, loop `1..nodes.length`); and `el.dataset.x` doesn't work through interop, use `el.getAttribute("data-x")`.
- **Tag definitions** (`tag.define`, in `CONFIG.md`): a `transform` runs only at index time, so after changing one run `System: Reload` **and** `Space: Reindex` in every client (the index lives in each client). A reload issued right after editing CONFIG can beat CONFIG's own reindex and load the old block: check `config.get({"tags","<name>"})` and reload again if it's missing.
- **Tickable query rows:** a task rendered in a query widget is tickable when its line contains a wikilink to a *position or anchor* ref (`page@123` or `$anchor`); an alias is fine. See `dashboard.md`.
- **Mentions:** a bare `@name` anywhere in page text is indexed as a mention and never closes unless it sits in a task or comment. Backtick a mention you only talk about.

## Write paths and attribution

| How ${BOT_NAME} writes | Live update in an open editor | Revision/git author |
|---|---|---|
| On disk (heredoc, Edit/Write) | yes | `External <external@silverbullet.local>` |
| HTTP API `bin/sb.sh put` (bot token) | yes | the bot's account |
| Runtime API `space.writePage` (live client) | yes, with a presence label beside the text | should be the bot's account (the one test of this was taken by the snapshot timer first) |

**${BOT_NAME} writes on disk, not via the API.** A PUT replaces the whole file, so
read-modify-write can drop a concurrent writer's change. Cost accepted: the bot's
edits show as `External` in history.

## Revisions helpers

`./bin/sb.sh snapshot` commits everything outstanding now (`{"committed":true|false}`; 409 if the space isn't managed); the commit is authored **SilverBullet**, message *Manual snapshot*. `./bin/sb.sh revlog [N]` lists the last N commits (rev, author, message). Run a snapshot as the rollback point before multi-file edits and name it in the report.
