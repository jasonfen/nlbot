# SilverBullet

SilverBullet is a self-hosted Markdown wiki. Here it is mounted on the same directory Claude Code works in, so the vault is one set of plain files with two editors: you in the browser, the bot on disk. There is no sync step between them.

Since 2.x SilverBullet also has a **Runtime API** that runs Lua inside a live client on the server. That gives the bot the same index and queries you see in the browser, which is what makes the vault usable as a conversation surface and not only as storage.

This page covers the install and the conventions. The bot's own reference, with the endpoint tables and the full list of gotchas, is `templates/processes/silverbullet.md`; it ends up at `processes/silverbullet.md` in the vault.

Everything here was checked against a running **2.12.0** instance in multi-space mode. The Runtime API is marked experimental upstream.

## Install

### 1. Compose file

`templates/silverbullet/docker-compose.yml` is the running stack's compose file with paths replaced. Put it in its own directory outside the vault (the source system keeps it root-owned under a stacks directory). The points that matter, each of which cost an afternoon once:

- **Pin an exact image tag.** `:latest` floats, and so does `:latest-runtime-api`. A routine `docker compose pull` once jumped a minor version unannounced.
- **Do not set `SB_USER`, `SB_AUTH_TOKEN` or `SB_LOG_PUSH`.** Any one of them selects legacy single-space mode. The boot log says which: `boot mode: single-space (SB_LOG_PUSH is set)`.
- **`user:` is the vault owner's uid:gid**, so files SilverBullet writes keep the right owner.
- **`HOME=/tmp`.** A numeric uid has no home inside the container, and headless Chromium aborts when it cannot create its config directories. The symptom is the Runtime API stuck at `503 bridge_unavailable`.
- **`hostname: silverbullet`.** Chrome's profile lock records the hostname. With a random hostname per recreate, Chrome refused its own stale lock.
- **Port bound to `127.0.0.1` only.** `tailscale serve` is the front door.

### 2. First boot, without the vault

Multi-space mode only initialises into an **empty** data folder. With the vault already mounted inside it, 2.11.1 logged `boot mode: single-space (folder is not empty)`. So the vault mount is commented out in the template.

```bash
sudo mkdir -p ${SB_DATA_DIR} && sudo chown ${BOT_UID}:${BOT_GID} ${SB_DATA_DIR}
docker compose up -d
docker logs silverbullet 2>&1 | grep -i 'boot mode'
```

The boot log should say `boot mode: unconfigured (empty folder, no flags, no legacy env)`. Open `http://127.0.0.1:${SB_PORT}` (an SSH port forward is enough for this step). It redirects to the setup wizard at `/.setup/`, which has two screens. This was walked on a fresh 2.12.0 container on 2026-11-14.

**Wizard step 1, the admin account.** Username (prefilled `admin`), password twice, optional full name and email. Revision history uses the name and email as the commit author. A dedicated admin account is suggested; your everyday account comes later.

**Wizard step 2, the first space.** Set the fields like this:

| Field | Default | Set to |
|---|---|---|
| Server URL | the address you opened it on | `https://${BOT_NAME}-notes.${TAILNET}.ts.net`, the address you will actually use. It is stored as `primaryUrl` in `${SB_DATA_DIR}/server.json` |
| Name of your first space | `Notes` | `Vault` |
| Hostname | Primary hostname | leave it |
| Path | `/notes` | `/`, so the space is served at the root (stored as an empty prefix) |
| Folder | `/data/spaces/notes` | `/data/spaces/vault` |
| Revisions | Managed | leave it on **Managed** |

**Finish setup** creates the space and drops you on the login page. Sign in as the admin and go to `/.dashboard`. It has four sections: Spaces, Users, Profile and Admin.

**Accounts (Dashboard → Users → Create user).** Create one account for yourself, with a full name and email, and one named `${BOT_NAME}` for the bot. Both are Local login with the Admin box unticked. Then open the bot's user page, go to **API tokens**, give the token a name and press **Create token**. The token starts with `sbt_` and is shown only once, so copy it now.

**Space access (Dashboard → Spaces → Vault → Access).** A new account has no access to any space until you grant it here. The table has three boxes per user: **Read**, **Write** and **Runtime API**. Tick all three for the bot and Read plus Write for yourself, keep "Public (not signed in)" on **No access**, and press **Save changes**. Skip this and every bot call fails with `Insufficient access to this space`, while `sb.sh ready` loops on that message. The grant is stored in `spaces.json` as `"members": {"${BOT_NAME}": {"role": "write", "runtimeApi": true}}`.

Resulting state, as on the source system: one admin account, your account, the bot account with a token, and one space named Vault with folder `spaces/vault`, an empty prefix, public access `none`, and revisions `managed`.

### 3. Mount the vault and restart

Uncomment the vault volume line (`${VAULT_DIR}:/data/spaces/vault`), then:

```bash
docker compose up -d
```

SilverBullet's own placeholder files for that space stay on disk underneath the mount, hidden by it.

### 4. Space settings

Settings for the space live in `${SB_DATA_DIR}/spaces.json`. The file is read at startup, so back it up, edit, and `docker restart silverbullet`. Keep its owner and mode 600. The fields the source system changed from their defaults:

| Field | Value | Why |
|---|---|---|
| `revisions` | `"managed"` | SilverBullet commits page edits into the vault's git repo about 30 seconds after they settle, with the editing account as author |
| `spaceIgnore` | `"node_modules/\n"` plus any noisy folders | Newline-separated gitignore-style patterns. This hides paths from the listing, the index and search. It does **not** stop a direct `GET /.fs/<path>`, so it is no protection for secrets (see below). 2.11+ does not read `.gitignore`, and the `SB_SPACE_IGNORE` variable is ignored in multi-space mode |
| `shell.enabled` | `true` | Defaults to `false`. Only needed for `bin/sb.sh shell` and Space Lua `shell.run` |

Ignoring `node_modules/` matters if you install the web terminal inside the vault. On the source system, ignoring `node_modules/` and one folder of logs took the visible file count from 2,652 to 891.

**How managed revisions treat the vault's git repo** (tested on 2.12.0, 2026-11-14):

- **The vault is already a git repo,** which it is if you followed `first-time-setup.md`. SilverBullet adopts it at startup and sets `silverbullet.managed = true` in its git config itself. Nothing needs setting by hand, and your existing history stays.
- **The vault is not a git repo.** SilverBullet runs `git init`, sets the same flag and makes an "Initial space snapshot" commit.
- **Commits.** Edits made in the browser or through the API are committed with the editing account as author (for example `${BOT_NAME} <email>`). Files changed directly on disk by the bot are committed as `External <external@silverbullet.local>`. Both happen within about 30 seconds ("Responsive", under the space's Revisions tab). `bin/sb.sh snapshot` returns `{"committed":true}` and commits everything outstanding straight away.
- **Get `.gitignore` in place before the first snapshot.** A snapshot commits untracked dotfiles too. In the test, a vault with no `.gitignore` had a token file committed by the first `sb.sh snapshot`. The kit's step 3 copies `gitignore.example` before SilverBullet ever sees the folder, so follow that order. If a secret does get in, remove it from history before the repo goes anywhere.

### 5. Give the bot its token

```bash
cd ${VAULT_DIR}
printf '%s' '<the API token>' > ${SECRETS_DIR}/sb-token && chmod 600 ${SECRETS_DIR}/sb-token
./bin/sb.sh ready                       # first call starts headless Chrome; up to 3 minutes
./bin/sb.sh lua 'system.getVersion()'   # {"result":"2.12.0-…"}
./bin/sb.sh ls | head
```

`bin/sb.sh` reads the token from `${SECRETS_DIR}/sb-token` unless `SB_AUTH_TOKEN` is set in its environment.

**Why the token is not in the vault.** SilverBullet serves any file in the space to any logged-in account. Dotfiles are left out of the file listing, but `GET /.fs/.sb-token` still returns the file, and adding a pattern to `spaceIgnore` doesn't change that: it filters the listing and the index, not a direct read. On the source system, the root token files, the web terminal's `.env` and the Telegram config were all readable that way until they were moved out on 2026-11-15. Keep every secret in `${SECRETS_DIR}`.

### 6. Pages

Step 3 of the setup already copied these into the vault. In the kit they carry a `.template` suffix, because SilverBullet runs `space-lua` blocks and registers page templates from any `.md` page in a space, and the kit itself may sit inside one:

- `CONFIG.md`: six task states (`[ ]`, `[>]`, `[x]`, `[?]`, `[~]`, `[!]`) and three tag definitions. The whole CONFIG is validated as one unit, so **one bad key rejects all of it**. The source system's CONFIG also configures two plugs (a task explorer and a search plug). Those blocks are left out of the template because their keys are only valid with the plugs installed.
- `templates/handoff.md`, `templates/handoff-task.md`, `templates/decision.md`, `templates/journal-entry.md`: page and slash templates.
- `dashboard.md`: live queries for due tasks, things waiting on you, open handoffs, and recent pages.

After editing CONFIG, run `System: Reload` in each open client. After changing a tag definition, also run `Space: Reindex`, because the index lives in each client.

## The Runtime API and `bin/sb.sh`

The SilverBullet server is deliberately simple: it serves files. Indexing and queries happen in the browser client. The Runtime API closes that gap by running a headless Chromium client on the server and evaluating Lua inside it:

| Endpoint | Body | Returns |
|---|---|---|
| `POST /.runtime/lua` | one Lua expression | `{"result": …}` |
| `POST /.runtime/lua_script` | a script with an explicit `return` | `{"result": …}` |
| `GET /.runtime/logs` | | the headless client's console |

`bin/sb.sh` wraps these and the plain file API:

| Command | Does |
|---|---|
| `sb.sh ready` | Polls `/.runtime/lua` every 10 s until the client answers, for up to 3 minutes |
| `sb.sh lua '<expr>'` | Evaluates one expression |
| `sb.sh script [file\|-]` | Runs a multi-statement script |
| `sb.sh query '<query>'` | Shorthand for `lua 'query[[…]]'` |
| `sb.sh cmd '<Command Name>'` | Runs a command-palette command |
| `sb.sh get <path>` / `put <path> [file\|-]` | Reads or writes a file through the server |
| `sb.sh ls` | Every file SilverBullet can see |
| `sb.sh logs [N]` | Last N lines of the headless client's console |
| `sb.sh config` | Server-side config as JSON |
| `sb.sh shell <cmd> [args…]` | Runs a command inside the container |
| `sb.sh snapshot` | Commits everything outstanding now, as a rollback point |
| `sb.sh revlog [N]` | Last N revision commits |

`sb.sh shot` exists only to print an error: the screenshot endpoint was removed in 2.11.

Things to know before relying on it:

- **The first call after a container start is slow.** Chromium starts on the first runtime call, boots the client and indexes the space. Until then every call returns `503 {"code":"bridge_unavailable"}`. The `sb-mentions` gate handles this by starting `sb.sh ready` in the background and trying again on its next tick.
- **API endpoints are at the server root**, whatever URL prefix the space has. A 401 on a prefixed path is the login page, not the API.
- **The header comment in `sb.sh` still describes 2.10.** It says `ls` honours `.gitignore` and names 2.10.0 as the running tag. Both are out of date; the code is correct for 2.12.
- **The bot writes pages on disk, not through the API.** A `PUT` replaces the whole file, so a read-modify-write can drop an edit you made in between. The cost is that the bot's edits appear as author `External` in revision history.

Examples:

```bash
./bin/sb.sh query 'from index.tag "page" order by lastModified desc limit 5 select name'
./bin/sb.sh lua '#identity.mentions("${BOT_NAME}").mentions'
./bin/sb.sh cmd 'System: Reload'
```

## The vault as a conversation surface

### Mentions

A request to someone is an `@name` **inside a task or a comment**:

```markdown
- [ ] check whether the backup ran last night @${BOT_NAME}
<!-- is this section still needed? @${HUMAN_HANDLE} -->
```

- SilverBullet 2.11+ indexes these. Each person's open mentions are in their **Mention Inbox** (`Navigate: Mentions`, Ctrl-Alt-i).
- A mention closes when the task is ticked, the comment is resolved or deleted, or the `@` is removed. A bare mention in running prose never closes, so don't write one.
- To write *about* a mention without creating one, put it in backticks. Backticked and fenced mentions are not indexed. Mentions inside HTML blocks are.
- A reply is signed by ending it with `-- @name`. A signature credits the author and does not put the reply in anyone's inbox.

**Your Mention Inbox is the bot's queue for you.** When the bot needs a decision it writes a task with `@${HUMAN_HANDLE}` on the page the question is about.

**Answering in place.** Type the answer as a nested bullet under the question, mention the bot in it, and tick the question:

```markdown
- [x] Option 1 or option 2? @${HUMAN_HANDLE}
  - Option 2, the cable path is through finished walls @${BOT_NAME}
```

The `@${BOT_NAME}` in the answer is what wakes the bot. Ticking alone does not, and neither does a signature.

### How the bot notices: the `sb-mentions` gate

`cron-prompts/gates/sb-mentions.sh` runs every 5 minutes from cron and costs no tokens on a quiet cycle. It has two sources:

1. **Mentions.** It calls `identity.mentions("${BOT_NAME}")` through the Runtime API. Each mention is keyed on a SHA-1 of the page name, the whitespace-normalised snippet and the target, because the position fields shift on every unrelated edit. New keys are compared against `cron-prompts/state/.sb-mentions-seen`.
2. **Untagged handoff lines.** It greps `handoffs/` on disk for lines containing `#handoff` that have no `@${BOT_NAME}`, with a separate seen-file. This catches a task or comment bullet you wrote without the mention.

Behaviour worth knowing:

- The first run records everything that exists as seen and wakes nothing.
- Editing the text of a mention makes it new again. That is deliberate: an edited, still-open request should not be swallowed.
- Renaming a page re-fires its mentions once.
- The bot's own nested replies in the form `* **${BOT_NAME}:** …` are cut out of the snippet before hashing. Without that, each inline reply changed the parent's key and re-fired it.
- On any error the gate logs to `cron-prompts/inject.log` and rests. It never wakes the session on a failure.

When there is something new the gate writes the detail to `/tmp/sb-mentions-new.txt` and the main session gets `CRON sb-mentions NEW=<n> <page>: <snippet>…`. **There is no runner agent and no automatic reply.** The main session reads the file and tells you. It writes a signed reply on the page when you ask it to. The one exception: a mention that is an open `#handoff` task is treated as a handoff pickup, and the bot starts the work.

### Handoffs

A handoff is a task you leave for the bot to do on its own.

```markdown
- [ ] Compare the two backup tools and recommend one #handoff @${BOT_NAME}
```

- **Where:** `handoffs/YYYY/MM/DD.md`, one page per day, made by the `${BOT_NAME}: New Handoff` command. Put context above the task. `inbox.md` works too.
- **Detection:** the soul-loop gate counts open `- [ ] … #handoff` lines in `handoffs/` and `inbox.md` every 10 minutes. Any open one wakes the loop immediately, whatever the idle backoff. The mentions gate catches the `@${BOT_NAME}` as well.
- **Pickup:** the bot inserts an anchor after the checkbox, `$h-YYYY-MM-DD-<slug>`, so the task has a stable link target.
- **Response:** a subpage `handoffs/YYYY/MM/DD/<slug>.md` with frontmatter `tags: handoff-response` and `authors: ${BOT_NAME}`, opening with `Answers [[$h-…]].` and linked under the task.
- **Done:** the bot ticks the box once the deliverable exists.
- **Blocked on you:** the bot writes its question as an `@${HUMAN_HANDLE}` task on the response page and adds `#blocked-on-human` to the handoff line.

`#blocked-on-human` is the brake. An open handoff without it wakes the soul loop every 10 minutes, and each wake spawns a runner that can only report it is still waiting. With the tag, the gate skips the line. **Remove the tag when you answer**, or the bot never picks the task back up.

Only `[ ]` counts as open. A task in a custom state such as `[>]` is invisible to the gate.

### Due-date bookmarks

To have the bot do something later, add a `[due: …]` attribute to a normal task:

```markdown
- [ ] Re-check the drive temperatures after the fan goes in [due: 2026-10-01]
- [ ] Compare CPU throttling before and after the power cap [due: 2026-09-27T09:20]
```

- A date alone means 06:00 local time that day. A time can follow a `T` or a space.
- Scanned files: `inbox.md`, and every `.md` under `handoffs/` and `projects/`. Nowhere else, so documentation that shows the syntax never fires.
- Once the time has passed, the soul-loop gate wakes the session with `DUE=<n>` and writes the lines to `/tmp/soul-loop-due.txt`. The main session does the work itself, because these are usually commitments that need judgment.
- The task keeps waking the bot every 10 minutes until it is ticked, re-dated to later, or tagged `#blocked-on-human`.
- **A due date on a line tagged `#blocked-on-human` never fires.** If you snooze a blocked item to a date, take the tag off.

The bot adds these itself whenever it says it will check back on something.

### Review and rollback

With managed revisions on, every edit is a git commit. Before a multi-file edit the bot runs `./bin/sb.sh snapshot` and names that commit in its report. You review with `Revision: Page History` in SilverBullet and use Restore if you disagree.

Authors you will see in history: your account for your edits, `External` for the bot's on-disk edits, `SilverBullet` for manual snapshots, and `snapshot-timer` for dot-path commits from `bin/vault-snapshot.sh`.

## Checking that a page renders

A query can be correct and still show nothing, so check the rendered page before trusting it.

**In the live headless client** (no extra install):

```bash
./bin/sb.sh lua 'editor.navigate("dashboard")'
./bin/sb.sh script - <<'LUA'
editor.moveCursor(#editor.getText(), true)   -- widgets only render in the viewport
local nodes = js.window.document.querySelectorAll("<css selector for the widget>")
return nodes.length
LUA
```

Three traps from the source system's notes: the editor only renders widgets near the viewport, so scroll first; NodeLists reached through the JS bridge are 1-indexed; and `el.dataset.x` does not work through the bridge, use `el.getAttribute("data-x")`.

The selector depends on the widget and the SilverBullet version. Inspect the page in your own browser to find it.

**In a separate browser: `bin/sb-render.cjs`.** It logs in as a browser user with Playwright, opens a page, saves a screenshot and prints the visible text.

```bash
SBU=<user>:<password> PROFILE=/tmp/bot-sb-profile WAIT=45000 \
NODE_PATH=<dir-with-playwright>/node_modules \
node bin/sb-render.cjs dashboard /tmp/dashboard.png
```

- It needs a browser login, not the API token, and Playwright installed somewhere.
- **A fresh profile renders queries empty.** A new browser profile has to sync and index the whole space first. Use `WAIT=45000` the first time, then reuse the profile with about 15000.
- Output is cut at `MAXCHARS` (default 2500). A list that seems to stop early is probably the cap.
- `SCROLL=bottom` scrolls the editor before capturing.

Whichever you use, **build a control first**: render a page whose query you have already seen working. An empty result on a cold client is not a broken query.

In the template, one line of `sb-render.cjs` differs from the running copy: there the final `console.log` of console errors had been swallowed into the preceding comment, so errors were never printed. The template puts it back on its own line.
