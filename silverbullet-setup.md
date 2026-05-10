# SilverBullet — the vault editor

The bot's vault is plain Markdown on disk, which is great for the bot but inconvenient for you. SilverBullet is a self-hosted Markdown wiki that turns the vault into a browser-accessible workspace: live preview, wiki-links between pages, query blocks, plug-ins for treeviews and tag indexes, and a clean editing surface that works equally well on a laptop or a phone.

This is your primary day-to-day interface to the bot. You read its journal in SilverBullet. You leave handoff tasks in SilverBullet. You scroll through `decisions.md` in SilverBullet. The bot writes to the same files via plain `Write` tool calls. No sync conflicts because nobody owns the files — they live on disk and both sides edit them directly.

**You will need this**, even though Nate's bot is a "no-sidechat" build. SilverBullet isn't sidechat; it's the editor for the vault.

*Separate decision (defer or skip): [Portainer](portainer.md) is an optional browser UI for managing Docker containers. It slots into the same `docker-compose.yml`, but is **not** required to run the bot — most one-person setups run without it. Don't install it just because you're reading this; read `portainer.md` first.*

## Run it as a Docker container

The official image is `ghcr.io/silverbulletmd/silverbullet:latest`. The simplest setup is `docker compose`:

```yaml
# <VAULT>/docker-compose.yml
services:
  silverbullet:
    image: ghcr.io/silverbulletmd/silverbullet:latest
    restart: unless-stopped
    environment:
      - SB_USER=nate:<long-random-password>           # basic auth for the web UI
      - SB_AUTH_TOKEN=<long-random-token>             # sync token (different from password)
    volumes:
      - <VAULT>:/space                     # the vault root
    ports:
      - "127.0.0.1:3001:3000"                         # bind to localhost only
```

Generate the password and token with `openssl rand -base64 24` (do it twice, they should be different). Save them somewhere you'll remember — SilverBullet on a phone will ask for the password the first time you connect.

Bring it up:

```bash
cd <VAULT>
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

- **`tailscale serve` (recommended)** — proxies the localhost port onto your tailnet at a stable HTTPS URL: `https://natebot.<your-tailnet>.ts.net`.
  ```bash
  sudo tailscale serve --bg --https=443 http://127.0.0.1:3001
  sudo tailscale serve status
  ```
- **`tailscale funnel`** — same as serve but exposes it to the public internet (only do this if you actively want that; the basic-auth concern above applies).

After running `serve`, hit the URL from your phone (with the Tailscale app connected). It'll prompt for the basic-auth credentials once and then remember them.

## Recommended plugs

SilverBullet has a plug system. The ones worth installing on day one:

- **TreeView** — sidebar showing the folder hierarchy. Essential. *(Per kit memory: always install this.)* Install via the SB command palette: `Plugs: Add` → `github:silverbulletmd/silverbullet-treeview/treeview.plug.js`.
- **Tags** — auto-index for `#tag` references across the vault. Useful for finding all `#handoff` items. Built-in.
- **Frontmatter / Tasks** — built-in; let you query open `[ ]` checkboxes across files. The bot uses this pattern for handoff tracking.

The `dashboard.md` page in this kit has example query blocks you can drop into your own vault.

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
