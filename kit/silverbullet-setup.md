# SilverBullet — the vault editor

The bot's vault is plain Markdown on disk, which is great for the bot but inconvenient for you. SilverBullet is a self-hosted Markdown wiki that turns the vault into a browser-accessible workspace: live preview, wiki-links between pages, query blocks, plug-ins for treeviews and tag indexes, and a clean editing surface that works equally well on a laptop or a phone.

This is your primary day-to-day interface to the bot. You read its journal in SilverBullet. You leave handoff tasks in SilverBullet. You scroll through `decisions.md` in SilverBullet. The bot writes to the same files via plain `Write` tool calls. No sync conflicts because nobody owns the files — they live on disk and both sides edit them directly.

**You will need this**, even though Nate's bot is a "no-sidechat" build. SilverBullet isn't sidechat; it's the editor for the vault.

> **What the bot does automatically vs. what needs your hands**
>
> During **Phase 0.5** of `first-time-setup.sh`, the operator types the SilverBullet password at an interactive prompt (or pre-sets `BOT_PASSWORD` env var for unattended provisioning). The typed value flows through `bot-secrets.sh store-interactive` which pipes it directly into `systemd-creds encrypt` — plaintext never lands on disk in cleartext. Then during **Step 6** of bot-driven setup, the bot generates the machine-only `sb-auth-token` via `bot-secrets.sh generate`, and runs `bash <KIT>/runtime/silverbullet-up.sh` which decrypts both blobs into env vars and brings up `<KIT>/docker-compose.yml` (kit-managed). The compose file mounts `../vault:/space`. Finally `sudo tailscale serve --https=443` exposes the container. The operator already knows `sb-user-password` (they typed it in Phase 0.5); `sb-auth-token` is machine-only.
>
> If you're doing the assisting-CC fallback flow (Steps 5–9 by hand), the commands below are what you run yourself.

*Separate decision — and the kit recommends *against* installing Portainer here. [portainer.md](portainer.md) explains why: Claude tends to edit `docker-compose.yml` on disk and bypass the Portainer API, causing Portainer's stored stack definition to drift from reality. If you want the UI anyway, read `portainer.md` first.*

## Run it as a Docker container

The official image is `ghcr.io/silverbulletmd/silverbullet:latest`. The simplest setup is `docker compose`:

```yaml
# <KIT>/docker-compose.yml
services:
  silverbullet:
    image: ghcr.io/silverbulletmd/silverbullet:latest
    restart: unless-stopped
    environment:
      - SB_USER=nate:<long-random-password>           # basic auth for the web UI
      - SB_AUTH_TOKEN=<long-random-token>             # sync token (different from password)
    volumes:
      - ../vault:/space                     # the vault root
    ports:
      - "127.0.0.1:3001:3000"                         # bind to localhost only
```

The password is the one you typed in Phase 0.5 of `first-time-setup.sh` (you already know it; that was the point of prompting). The auth-token is machine-only, generated via `bot-secrets.sh generate sb-auth-token 24` during bot-driven Step 6. If you're doing the manual fallback flow, `openssl rand -base64 24` works for both — just save the password somewhere recoverable since SilverBullet on a phone will ask for it the first time you connect.

Bring it up:

```bash
cd <KIT>
docker compose up -d
docker compose logs -f silverbullet     # verify clean start
```

Visit `http://localhost:3001` in a browser on the same machine. You should see the vault — `journals/journal.md`, `inbox.md`, `identity.md`, etc.

### Why bind to 127.0.0.1?

Because we don't want SilverBullet on the public internet. Two reasons:
1. **Auth is basic-auth over HTTP** — fine inside a tailnet, terrible across the open web.
2. **The vault is your bot's brain.** A public exposure means anyone can read the journal, the decisions log, and (if SB_USER is brute-forced) edit it.

For remote access from your phone or laptop, expose it through Tailscale instead.

## Expose via Tailscale

Install Tailscale on the host. Then either:

- **`tailscale serve` (recommended)** — proxies the localhost port onto your tailnet at a stable HTTPS URL: `https://<bot-host>.<your-tailnet>.ts.net` (the hostname is whatever Tailscale registered for the box).
  ```bash
  sudo tailscale serve --bg --https=443 http://127.0.0.1:3001
  sudo tailscale serve status
  ```
- **`tailscale funnel`** — same as serve but exposes it to the public internet (only do this if you actively want that; the basic-auth concern above applies).

After running `serve`, hit the URL from your phone (with the Tailscale app connected). It'll prompt for the basic-auth credentials once and then remember them.

## Recommended plugs

The kit pre-installs TreeView's compiled bundle into `<VAULT>/_plug/treeview.plug.js` at first-time setup (`runtime/install-plugs.sh`, version pinned to a specific commit SHA). SilverBullet loads anything in `_plug/` at startup, so TreeView is available the first time you open the UI — no manual `Plugs: Update` needed.

`CONFIG.md` at the vault root declares kit defaults using `config.define` (not `config.set`):

- **`plugs`** — array of plug URLs, default is `["github:joekrill/silverbullet-treeview/treeview.plug.js"]`. Surfaces in the SB Configuration Manager UI; you can override (add more plugs, drop TreeView) without forking the kit.
- **`treeview.position`** — `lhs` or `rhs`, default `lhs`.
- **`taskStates`** — six custom states (`[ ]` open, `[>]` in-progress, `[x]` done, `[?]` blocked, `[~]` deferred, `[!]` urgent). Click a checkbox to cycle.

To add more plugs (e.g. `silverbullet-silversearch`, `silverbullet-graphview`):

1. Edit `config.define("plugs", { …, default = {...} })` in `CONFIG.md` and add the URL.
2. Open the command palette (`Cmd/Ctrl-/`) → **`Plugs: Update`**. SB fetches new entries, writes them to `_plug/`, reloads. Done.

To pin a new plug into the kit's pre-install set (so fresh installs get it without `Plugs: Update`), append an entry to `PLUGS=( ... )` in `runtime/install-plugs.sh` using a SHA-pinned `raw.githubusercontent.com` URL.

The kit also seeds `_templates/handoff.md` — a SilverBullet page template. To create a new daily handoff: `Page: From Template` → pick `handoff` → SB stamps out `handoffs/YYYY/MM/DD.md` with the canonical structure (tasks list, context section, done section). The bot picks it up on the next soul-loop.

### Optional: programmatic SB commands via the Runtime API

The kit ships `runtime/sb-cmd.sh`, a wrapper around SilverBullet's `POST /.runtime/lua` HTTP endpoint that lets scripts invoke any SB command without opening the UI:

```bash
bash <KIT>/runtime/sb-cmd.sh "Plugs: Update"
bash <KIT>/runtime/sb-cmd.sh --lua 'editor.getCurrentPage()'
```

The Runtime API is **not enabled by default**. To turn it on, flip the SilverBullet container's image from the base variant to the `-runtime-api` variant:

```yaml
# docker-compose.yml
silverbullet:
  image: ghcr.io/silverbulletmd/silverbullet:latest-runtime-api   # was :latest
  # … rest of the service block unchanged …
```

Trade-off: the `-runtime-api` image bundles Chromium (~766MB) versus the base image (~64MB). Worth it only if you want to script SB from the bot side (e.g. drive automated handoff-page creation from setup-runner). Most users should stick with the base image and run `Plugs: Update` from the UI.

## What you'll see when you first open SilverBullet

Assuming Step 2 of `first-time-setup.md` ran (the `cp $KIT/templates/vault-pages/*.md ./` and `cp $KIT/templates/processes/*.md ./processes/` lines), the vault already has its landing pages and process docs:

- **`index.md`** — the entry point. Top-level navigation: recovery-critical files, processes, reference, creative.
- **`dashboard.md`** — live overview. SilverBullet queries render open tasks, recent activity, open handoffs, open ideas — refreshed on each page load. If you see literal `${template.each(...)}` text instead of a rendered list, the query syntax didn't compile (most often: SilverBullet hasn't finished its first index sweep; reload after ~10s).
- **`handoffs.md`** / **`journals.md`** / **`processes.md`** — folder indexes. Same query pattern; each lists the contents of its folder via the SB index.
- **`processes/{soul-loop,journaling,handoffs}.md`** — canonical lifecycle docs the bot's agents BOOTSTRAP from. Edit these to change bot behavior; the agent prompts read them at runtime instead of carrying their own copies.

If Step 2 didn't run those `cp`s (you'll see a near-empty vault), the bot's `setup-runner` will post a `BLOCKER missing-vault-pages` line and stop until you re-run them. Don't synthesize the pages by hand — the templates already match the kit's `<BOT_NAME>` / `<USER_NAME>` / `<VAULT>` substitution flow.

## How you actually use it

Day-to-day:
- **Morning:** open `journals/journal.md`, see what the bot wrote overnight. Read the daily file from yesterday.
- **Leaving a task:** create or edit `handoffs/YYYY/MM/DD.md`, drop a checkbox like `- [ ] do the thing #handoff`. The bot's soul loop will see it within 10 minutes and engage.
- **Reading decisions:** `decisions.md` is searchable from the SB command palette (`/`). Same for `journals/`.
- **Editing identity:** `identity.md` and `user-profile.md` are yours to edit whenever you learn something about how you want the bot to work.

The bot writes to the same files. No locking, no sync — Markdown writes are atomic at the OS level, and SilverBullet picks up file changes from disk within a few seconds. Don't try to edit the same line at the same instant the bot does and you'll be fine.

## Backup

Two layers:

1. **The vault is in git.** Commit and push regularly. `git add . && git commit -m "..." && git push` from the vault directory works; SilverBullet won't fight you. (The bot can be told to do this on a schedule.)
2. **Filesystem snapshot** — if the host is on Proxmox/ZFS, snapshot the dataset. The vault is small (tens of MB) and snapshots are nearly free.

Don't rely on SilverBullet for backup. It's an editor, not storage.

## Troubleshooting

- **"can't connect"** — verify `docker compose ps` shows it running. Check the port binding (`docker compose port silverbullet 3000`).
- **"401 Unauthorized"** — the SB_USER format is `username:password` (one field, colon-separated). If your password has special characters, quote it in the env file.
- **"sync token mismatch"** — if you change `SB_AUTH_TOKEN`, existing client connections need to forget and re-auth. On the SB Sync page, log out and back in.
- **Plugs not loading** — check `:settings` in the command palette; permissions issues with the plug cache directory show up there.

## Why this over Obsidian / a regular notes app

You could absolutely run Obsidian Sync and point it at the vault directory. Some people do. Two things SilverBullet has that matter for the bot setup:

1. **It's a server, not a client.** You access it from any device that can reach the URL. No app to install on every laptop/phone.
2. **It's git-friendly by design.** The vault is plain Markdown, no proprietary metadata layer. The bot reading and writing the same files is the *normal* mode of operation, not a special integration.

If you already use Obsidian and want to keep it, point Obsidian at the same folder. The bot doesn't care which editor you use; it reads what's on disk.
