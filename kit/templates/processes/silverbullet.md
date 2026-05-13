# SilverBullet

How <BOT_NAME> interacts with its vault editor. The short version: through the filesystem, not the HTTP API.

## Canonical setup

- **Runtime:** Docker container, image `ghcr.io/silverbulletmd/silverbullet:latest` (or `:latest-runtime-api`, see "Other clients" below), brought up by `<KIT>/runtime/silverbullet-up.sh`.
- **Vault mount:** the bot's vault directory bind-mounts into the container as `/space`. Whatever lives at `<VAULT>/` on the host is what SilverBullet serves.
- **Port:** `127.0.0.1:3001` on the host, proxied to `:443` via tailscale serve at `https://<TAILSCALE_HOSTNAME>.<tailnet>.ts.net`.
- **Credentials:** `SB_USER` (`<BOT_NAME>:<password>`) and `SB_AUTH_TOKEN` are pulled from systemd-creds at compose-up by `silverbullet-up.sh` — never in plaintext on disk, never in the bot's env.

## How the bot reads and writes

**Through the filesystem.** Always. The vault is a directory of `.md` files; SilverBullet is one of several processes that read and write to it (the bot is another). Use the normal `Read`, `Write`, `Edit` tool surface — no SilverBullet-specific machinery needed.

```bash
# Bot reading a vault page
cat <VAULT>/journals/journal.md

# Bot writing a vault page
echo "..." >> <VAULT>/journals/journal.md
```

SilverBullet's **index pass** picks up disk changes within seconds. There is no `notify`, no `reload`, no API call required — write the file, wait a beat, the page renders. Concurrent edits between the bot and a human browser session are atomic at the OS write level; SilverBullet's last-write-wins for the rendered view, but the canonical state is always the file on disk.

## Conventions the bot relies on

- **Native tasks.** `- [ ]` and `- [x]` checkboxes with inline `#tag` markers. Don't roll your own task syntax; SB's task index queries the native form.
- **Folder indexes.** A page named `foo.md` and a folder named `foo/` at the same level are linked by SB convention: the page is the folder's index. The convention is **page-as-sibling-of-folder, not page-inside-folder.** Putting an `index.md` inside the folder will not auto-link.
- **Wikilinks.** `[[path/to/page]]` is preferred over Markdown links for intra-vault references — SB indexes them and renders backrefs.
- **Filenames.** No dots before `.md`. `soul-loop-log.md` works; `soul-loop.log.md` fails the index. Use hyphens, not dots, as word separators.
- **Page templates.** Live in `_templates/`. Create new instances via the SB command palette: `Page: From Template` → pick a template → SB stamps out the file with the canonical structure. The bot can also write directly to the target path; both produce identical files.

## What lives where

| Path | Purpose |
|---|---|
| `<VAULT>/index.md` | Landing page. Top-level navigation. |
| `<VAULT>/dashboard.md` | Live overview — open tasks, recent activity, open handoffs, rendered via SB queries. |
| `<VAULT>/identity.md`, `user-profile.md` | The bot's anchor files; re-read after any compaction. |
| `<VAULT>/decisions.md`, `inbox.md` | Reference logs (decisions/facts) and active-task list. |
| `<VAULT>/journals/journal.md` | Running journal (compacted nightly into `journals/YYYY-MM-DD.md` daily files). |
| `<VAULT>/handoffs/YYYY/MM/DD.md` + subpages | Async task delegation, per `[[processes/handoffs]]`. |
| `<VAULT>/processes/*.md` | Canonical lifecycle docs (this one, soul-loop, journaling, handoffs, security). |
| `<VAULT>/_templates/*.md` | SB page templates. |

## The HTTP API — the bot does NOT call it

SilverBullet exposes an HTTP API at `/.fs/<path>`, `/.shell`, `/.proxy/<host>/...`, `/.runtime/lua`, `/.ping`, `/.config`, authenticated by `Authorization: Bearer ${SB_AUTH_TOKEN}`. **This is not the bot's interface.** The bot reads and writes the vault through the filesystem, period.

The doctrinal reasoning lives in `[[processes/security]]` — short version: any pattern that decrypts `sb-auth-token` and places the bearer in a `curl -H` header leaks via `/proc/<pid>/cmdline`, weakening the rule that the only process which sees a plaintext token is the daemon that needs it. When a real bot-as-client use case lands (sandboxed sub-agent without filesystem access, remote integration), the future-approved shape is a kit-managed unix-socket broker — not a hand-rolled wrapper. See `[[processes/security]]` § *SilverBullet HTTP API*.

## Other clients

The HTTP API exists and is correct for clients that are *not* the bot:

- **Browser.** The web UI authenticates with `SB_USER` (basic auth) and uses the API internally.
- **Sync clients.** Other SilverBullet instances syncing with this one use `SB_AUTH_TOKEN`.
- **Future broker.** When/if a kit-managed broker is built, it loads `sb-auth-token` via `LoadCredentialEncrypted=` and proxies bot-side socket requests to the SB HTTP API. The bot is the socket client; the token stays in the broker.

For ad-hoc operator use (a human at a terminal, *not* the bot's agent code), the kit ships `<KIT>/runtime/sb-cmd.sh` — a wrapper around `POST /.runtime/lua`. It is **operator-tier**, flagged for deprecation or broker-wrap in a future kit revision. The bot's agent code does not invoke `sb-cmd.sh`. See `[[processes/security]]` § *Note on `runtime/sb-cmd.sh`* for context.

## Plug management

Plugs are SilverBullet extensions (TaskCommander, TreeView, etc.).

- **Pre-installed set:** the kit seeds an initial plug list via `<KIT>/runtime/install-plugs.sh`, SHA-pinned for reproducibility.
- **Adding a plug later:** edit `config.define("plugs", { ... })` in `<VAULT>/CONFIG.md`, then run **`Plugs: Update`** from the SB command palette. SB fetches new entries into `_plug/` and reloads.
- **TreeView is required.** Per `[[decisions]]` it's pinned as a must-have plug. If a fresh install is missing it, run `Plugs: Update` after seeding `CONFIG.md`.

## Backup

Two layers, both belt-and-suspenders:

1. **The vault is in git.** Commit + push regularly. Markdown writes are atomic; SB doesn't fight `git add`. The bot can be told to do this on a schedule, but the canonical action is operator-driven.
2. **Host-level snapshots.** If the host is on Proxmox/ZFS, snapshot the dataset. The vault is small (tens of MB) and snapshots are nearly free.

SilverBullet is an editor, not storage. Do not rely on its sync layer for backup.

## Troubleshooting

- **"can't connect"** — `docker compose ps` should show silverbullet running. Check the port binding with `docker compose port silverbullet 3000`.
- **"401 Unauthorized"** — `SB_USER` is one field, format `username:password` (colon-separated). If the password has special characters, quote it in the env file.
- **"sync token mismatch"** — if `SB_AUTH_TOKEN` rotated, existing sync clients need to forget and re-auth from the Sync page.
- **Pages render `${template.each(...)}` literally** — SB hasn't finished its index sweep yet. Reload after ~10s. If it persists, the query has a syntax error.
- **A page disappears from indexes** — check for dots before `.md` in the filename.

## See also

- `[[processes/security]]` — credential handling, the HTTP API doctrine, why the bot doesn't call it
- `[[processes/handoffs]]` — async task delegation lifecycle
- `[[processes/soul-loop]]` — the heartbeat that drives bot reads/writes against the vault
- `<KIT>/silverbullet-setup.md` — operator-facing setup doc (kit-side, not vault-side)
