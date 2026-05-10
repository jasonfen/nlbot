# First-time setup walkthrough

A 30-minute path from "I want one of these" to "it's running and I'm talking to it." Read [INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md) first if you haven't — it explains *why* this is a thing. This doc is the *how*.

*If a Claude Code instance is helping you with the install, it should read [setup-orchestrator.md](setup-orchestrator.md) first. That doc tells the assisting Claude how to walk through this one with you and track progress in `setup-state.md` so an interrupted setup can resume cleanly.*

## What you'll need before you start

- A Linux machine you can leave running (LXC container, spare laptop, small VPS — see [persistence-and-hardware.md](persistence-and-hardware.md) for the floor: 2 cores / 2 GB RAM / 8 GB disk).
- A Claude Code subscription (the CLI tool, not the API).
- A Telegram account with a phone (to talk to BotFather).
- About 30 minutes of focused time. You can stretch it over a weekend; nothing here is time-pressured.

## Step 1 — Install Claude Code + prereqs (5 min)

On the Linux box, follow the official install: <https://claude.com/download>. Then log in once interactively:

```bash
claude
```

Follow the prompts, accept the TOS. **Do this at a real terminal, not in a tmux session you'll later detach** — the TOS gate doesn't render well in a detached pane and the persistent setup we'll build relies on having that gate already cleared.

Verify the rest of the prereqs:

```bash
claude --version          # Claude Code installed
docker compose version    # Docker Engine + compose plugin (needed Step 5 — SilverBullet)
tmux -V                   # tmux installed
tailscale status          # Tailscale logged in (otherwise: sudo tailscale up)
node --version            # Node 20+ — only if doing the optional web shell (Step 7)
```

Anything that fails: install the missing piece before continuing. `docker compose version` is the trickiest — modern installs use the compose plugin (`docker compose`, two words), not the old standalone binary (`docker-compose`, hyphen).

## Step 2 — Drop in the vault (5 min)

Pick a directory name. The convention here is the bot's name + lowercase: `~/natebot`. From here on this doc uses `~/natebot/` as the vault root — substitute your own name throughout if you pick something else.

```bash
mkdir -p ~/natebot/journals ~/natebot/handoffs
cd ~/natebot

# Substitute /path/to/kit with wherever you cloned this repo
KIT=/path/to/nate-bot-kit

cp $KIT/CLAUDE-nate.md       CLAUDE.md
cp -r $KIT/templates         templates
cp -r $KIT/dot-claude        .claude     # NOTE the rename: dot-claude → .claude

# Seed the bot's identity from the bundled templates
cp templates/identity.md     identity.md
cp templates/user-profile.md user-profile.md
cp templates/soul-loop.md    soul-loop.md

touch journals/journal.md inbox.md decisions.md
```

Now open `CLAUDE.md` in your editor and replace every `[Nate]` and `[Your Bot's Name]` placeholder with your actual name and the bot's name. Same with `identity.md` and `user-profile.md` — fill in the canary phrase, your role, what you want from this bot. There's no "right" answer; first-pass guesses are fine, you'll edit later.

**About the canary phrase:** in `identity.md`, you'll set a short string ("the lighthouse keeper waves at midnight" — anything memorable). The bot is supposed to remember it without re-reading the file. If at any point it can't recall the phrase, that's its signal it has lost context (post-restart, post-compaction) and needs to re-anchor by reading `identity.md` and `user-profile.md`. It's not a security secret; just an orientation anchor.

## Step 3 — Disable the keybindings that kill sessions (1 min)

Edit `~/.claude/keybindings.json`:

```json
{
  "disabled": ["ctrl+x ctrl+e", "ctrl+x ctrl+k"]
}
```

Skip this and you'll discover why on day three. See [persistence-and-hardware.md](persistence-and-hardware.md) for the story.

## Step 4 — Wire up persistence (10 min)

Copy the runtime scripts from this kit into the vault, then drop the systemd unit:

```bash
cp $KIT/runtime/start-claude.sh ~/natebot/start-claude.sh
chmod +x ~/natebot/start-claude.sh
# Edit the path inside if your vault isn't ~/natebot
```

Then drop the systemd unit at `/etc/systemd/system/claude-code.service` (template in [persistence-and-hardware.md](persistence-and-hardware.md) — change `User=` and the path).

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now claude-code.service
tmux ls                         # should show "claude" session
tmux attach -t claude           # see Claude Code running
# Check that the ❯ prompt renders correctly. If you see __ or ?? instead,
# the locale isn't set right in some shell context. See the "Glyph rendering"
# section in persistence-and-hardware.md — fix it before continuing.
# detach with ctrl+b then d (don't kill it)
```

**Reboot the box now and verify it comes back up.** This is non-negotiable — verify the persistence works before you start trusting it. After the reboot:

```bash
systemctl status claude-code.service     # active (running)
tmux attach -t claude                    # back in the session
```

## Step 5 — Set up SilverBullet (the vault editor) (5 min)

This is your daily interface to the bot's brain. Walked through fully in [silverbullet-setup.md](silverbullet-setup.md). The condensed version:

1. Generate two random secrets:
   ```bash
   openssl rand -base64 24    # for SB_USER password
   openssl rand -base64 24    # for SB_AUTH_TOKEN
   ```
2. Drop a `docker-compose.yml` in `~/natebot/` with the silverbullet service block (template in [silverbullet-setup.md](silverbullet-setup.md)) — set `SB_USER=nate:<password>`, `SB_AUTH_TOKEN=<token>`, mount `~/natebot:/space`, bind `127.0.0.1:3001:3000`.
3. `docker compose up -d` and visit `http://localhost:3001`. Log in with the SB_USER credentials. You should see your vault.
4. Expose via Tailscale: `sudo tailscale serve --bg --https=443 http://127.0.0.1:3001`. Now reachable from your phone at `https://<host>.<tailnet>.ts.net`.
5. In SilverBullet's command palette, install the **TreeView** plug — it's essential for vault navigation.

You can now read `journals/journal.md` from your phone and leave handoff tasks (`- [ ] do X #handoff`) for the bot.

## Step 6 — Set up Telegram (10 min)

Walked through end-to-end in [telegram-integration.md](telegram-integration.md). The condensed version:

1. In Telegram, message `@BotFather`, send `/newbot`, follow prompts, save the token.
2. DM your new bot once. Then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find your `chat.id`.
3. Create `~/natebot/.telegram/config` with `BOT_TOKEN=`, `CHAT_ID=`, `BOT_USERNAME=`. `chmod 600` it.
4. Copy `tg-bot.py` and `tg-post.sh` from `runtime/` into `~/natebot/.telegram/`. Make them executable (`chmod +x`).
5. Drop `/etc/systemd/system/telegram-bot.service` (template in [telegram-integration.md](telegram-integration.md)). Enable and start.
6. DM your bot something — anything. `journalctl -u telegram-bot -f` should show the message arrive. The file `.telegram/new-messages.txt` should appear in your vault.

You won't see Claude reply yet — we haven't wired the heartbeat that nudges it.

## Step 7 — Optional: browser access (10 min)

Skip if you only need Telegram + SilverBullet. Add later if you find yourself wanting to *see* the live tmux session from your phone or another laptop. The web shell is a small Node.js server that attaches to your `claude` tmux session and renders it through xterm.js in the browser, login-protected and Tailscale-only.

Walked through end-to-end in [web-shell.md](web-shell.md). The condensed version:

1. Copy `web-terminal/` into `~/natebot/web-terminal/`.
2. `cd web-terminal && npm install`.
3. Create `.env` with `PORT=3000`, `SESSION_SECRET=<random>`, `UI_USERNAME=nate`, `UI_PASSWORD=<random>`.
4. Drop `/etc/systemd/system/natebot-web.service` (template in the doc). Enable and start.
5. `sudo tailscale serve --bg --https=443 http://127.0.0.1:3000`.
6. Visit `https://<host>.<tailnet>.ts.net`, log in, watch Claude type.

On iOS, "Add to Home Screen" makes it behave like a native app (PWA manifest is included).

## Step 8 — Cron the heartbeat (5 min)

⚠ **Do this AFTER the verification reboot from Step 4 — not before.** If cron fires before the tmux session exists, `inject-prompt.sh` will silently noop and you'll think it's broken.

Copy the runtime cron files into the vault:

```bash
mkdir -p ~/natebot/cron-prompts
cp $KIT/runtime/inject-prompt.sh ~/natebot/cron-prompts/
cp $KIT/runtime/cron-prompts/*.md ~/natebot/cron-prompts/
chmod +x ~/natebot/cron-prompts/inject-prompt.sh
```

Then `crontab -e`:

```cron
# 10-min heartbeat during active hours
*/10 7-23 * * * /home/nate/natebot/cron-prompts/inject-prompt.sh /soul-loop

# Morning wake-up (weekdays — adjust to your schedule)
30 7 * * 1-5 /home/nate/natebot/cron-prompts/inject-prompt.sh /wake-up

# Midnight sync
5 0 * * * /home/nate/natebot/cron-prompts/inject-prompt.sh /midnight-maintenance
```

Save. Within 10 minutes you should see soul-loop fires landing in `cron-prompts/job-log.md`. Now DM your bot — Claude should respond within a minute or two.

## Step 9 — Optional: vector memory (5 min)

You don't need this on day one. Add it in week 2–3 when grep starts feeling clunky. Setup is one command, walked through in [memory.md](memory.md). That doc also covers the secretary note-capture pattern (the cron-driven background note-taker) — useful once your conversations get long enough that you'd appreciate Claude writing the journal for you.

## What "done" looks like

- You DM the bot, it replies within a minute.
- `cron-prompts/job-log.md` shows clean heartbeat fires every 10 minutes.
- `journals/journal.md` has Claude's first morning entry.
- You reboot the box; everything comes back up in under 30 seconds.

If any of those fail, troubleshoot before adding more layers. A flaky persistent setup that you can't trust is worse than no setup at all.

## What to do in week one

- Talk to the bot conversationally on Telegram. Tell it about a project. See what it remembers.
- Ask it to journal something. Read what it wrote. Edit the journal directly if you want.
- Edit `user-profile.md` with what you've learned about how you want to work with it. The bot will read it on next wake-up.
- Don't add features yet. Watch what it does. The default decision menu is well-tuned; understand it before you change it.

## What to *not* do

- Don't run two bots from the same vault. They'll fight over the journal.
- Don't put secrets in the journal — it's plain Markdown, often committed to git.
- Don't run the bot on a laptop that sleeps. Soul-loop misses break the rhythm.
- Don't skip step 4's reboot test. You'll regret it.

## When you get stuck

- The persistent-Claude story across reboots is in [persistence-and-hardware.md](persistence-and-hardware.md). Most "it doesn't come back up" issues are answered there.
- Memory and note-capture questions: [memory.md](memory.md).
- Telegram weirdness: [telegram-integration.md](telegram-integration.md) has a troubleshooting section.
- Anything else: ask Claude. It has access to its own kit and can explain its own setup back to you.

That's it. ~30 minutes if everything goes smoothly, ~2 hours if it doesn't. Either way, by the end you have a thing that runs.
