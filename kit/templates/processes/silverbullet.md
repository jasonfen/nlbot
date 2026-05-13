# SilverBullet

How <BOT_NAME> interacts with its vault editor. The short version: through the filesystem, not the HTTP API.

## Canonical setup

- **Runtime:** Docker container, image `ghcr.io/silverbulletmd/silverbullet:latest` (or `:latest-runtime-api`, see "Other clients" below), brought up by `<KIT>/runtime/silverbullet-up.sh`.
- **Vault mount:** the bot's vault directory bind-mounts into the container as `/space`. Whatever lives at `<VAULT>/` on the host is what SilverBullet serves.
- **Port:** `127.0.0.1:3001` on the host, proxied to `:443` via tailscale serve at `https://<TAILSCALE_HOSTNAME>.<tailnet>.ts.net`.
- **Credentials:** `SB_USER` (`<BOT_NAME>:<password>`) and `SB_AUTH_TOKEN` are pulled from systemd-creds at compose-up by `silverbullet-up.sh` — never in plaintext on disk, never in the bot's env.

## How the bot reads and writes

Two supported channels. Use the one that fits the task.

**Channel 1 — filesystem (the default).** The vault is a directory of `.md` files; SilverBullet is one process reading/writing them, the bot is another. For everyday vault churn (journal entries, inbox checkboxes, handoff replies, decisions logs), use the normal `Read`, `Write`, `Edit` tool surface directly on disk.

```bash
cat <VAULT>/journals/journal.md            # read
echo "..." >> <VAULT>/journals/journal.md  # append
```

SilverBullet's **index pass** picks up disk changes within seconds. Write the file, wait a beat, the page renders. Concurrent edits between the bot and a human browser session are atomic at the OS write level; SB's last-write-wins for the rendered view, but the canonical state is always the file on disk.

**Channel 2 — SB's HTTP API (when filesystem isn't enough).** When the task benefits from going *through SilverBullet* rather than past it, use the kit-shipped wrappers in `<KIT>/runtime/`:

| Wrapper | Wraps | Use it for |
|---|---|---|
| `sb-cmd.sh` | `POST /.runtime/lua` | Invoke SB commands (`Plugs: Update`, `Page: From Template`); run arbitrary space-lua expressions for things SB knows how to do that bash doesn't. |
| `sb-fs.sh` | `GET/PUT/DELETE /.fs/<path>`, `LIST /.fs/` | Read/write/delete pages through SB's view (post-index, post-transforms); list the indexed page set; force-roundtrip a write so SB has it before the next read. |
| `sb-config.sh` | `GET /.config`, `PUT /.fs/CONFIG.md` | Inspect merged runtime config (with layered overrides applied); round-trip `CONFIG.md` edits through SB so they take effect immediately. |

```bash
bash <KIT>/runtime/sb-cmd.sh "Plugs: Update"
bash <KIT>/runtime/sb-cmd.sh --lua 'editor.getCurrentPage()'
bash <KIT>/runtime/sb-fs.sh GET journals/journal.md
echo '# Note' | bash <KIT>/runtime/sb-fs.sh PUT inbox.md
bash <KIT>/runtime/sb-config.sh get indexInterval
```

All three handle auth the same way: decrypt `sb-auth-token` from systemd-creds at call time, pass it as `Authorization: Bearer` on the curl request, exit when done. The bearer never lives outside the per-call shell process; `processes/security.md` § *SilverBullet HTTP API — supported pattern* explains the threat-model boundary (single-tenant + Tailscale-isolated tailnet = bounded `/proc/<pid>/cmdline` exposure).

**`sb-cmd.sh` requires the `-runtime-api` container variant** (`ghcr.io/silverbulletmd/silverbullet:latest-runtime-api`, ~766MB, includes Chromium). The base `:latest` image (~64MB) doesn't expose `/.runtime/lua`. See `<KIT>/silverbullet-setup.md` for the trade-off and how to flip the docker-compose image. `sb-fs.sh` and `sb-config.sh` work against either image variant.

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

## When to use which channel

The two channels (filesystem vs. HTTP API) aren't strict alternatives — both produce the same vault state — but each has ergonomic strengths. Rough guide:

| Task | Channel | Why |
|---|---|---|
| Append a journal entry | filesystem | One open-append-close; SB indexes within seconds. |
| Write inbox checkbox + immediately query whether SB sees it | `sb-fs.sh PUT` then `sb-cmd.sh --lua` | Round-trip through SB, no race against the index pass. |
| Invoke a SB command (`Plugs: Update`, `Page: From Template`) | `sb-cmd.sh` | The command is SB-side; there's no filesystem-equivalent. |
| Run a complex page-level query (backlinks, tag filter) | `sb-cmd.sh --lua` | Space-lua has direct access to SB's index; doing it from the bash side means re-indexing the world. |
| Read a page in the form SB actually serves (template-expanded, post-transform) | `sb-fs.sh GET` | Filesystem gives raw bytes; SB gives the rendered/transformed version. |
| Inspect or edit merged config | `sb-config.sh get` / `edit` | `CONFIG.md` on disk shows declared config; SB's merged view reflects layered overrides. |
| Bulk-edit thirty files at once | filesystem | One `sed -i` is faster than thirty PUTs. |

When in doubt: filesystem is faster and cheaper; the API is more *correct* (reflects SB's view rather than raw disk).

## Other clients

The HTTP API surface is shared with non-bot consumers:

- **Browser.** The web UI authenticates with `SB_USER` (basic auth) and uses the same API surface internally.
- **Sync clients.** Other SilverBullet instances syncing with this one authenticate via `SB_AUTH_TOKEN`.
- **Future broker (conditional).** If the kit is ever adapted for multi-tenant boxes or non-tailnet deployments, the wrappers should move behind a kit-managed broker daemon (loads `sb-auth-token` via `LoadCredentialEncrypted=`, exposes a unix socket, so the bearer never enters argv). Not needed for this kit's target deployments — see `[[processes/security]]` § *Threat-model boundary*.

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
