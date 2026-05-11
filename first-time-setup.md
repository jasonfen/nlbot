# First-time setup walkthrough

A 30-minute path from "I want one of these" to "it's running and I'm talking to it." Read [INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md) first if you haven't — it explains *why* this is a thing. This doc is the *how*.

*If a Claude Code instance is helping you with the install, it should read [setup-orchestrator.md](setup-orchestrator.md) first. That doc tells the assisting Claude how to walk through this one with you and track progress in `setup-state.md` so an interrupted setup can resume cleanly.*

## TL;DR — run the script

`runtime/first-time-setup.sh` automates Steps 1–4 of this walkthrough end-to-end: vault skeleton, identity seed, placeholder substitution, keybindings, `start-claude.sh`, the systemd unit, and bringing up the tmux session. It stops at the kit's explicit "hand over the keys" gate — the NOPASSWD sudoers grant and verification reboot stay manual.

```bash
bash $VAULT/runtime/first-time-setup.sh
```

The script prompts interactively for Phase 0 values (`BOT_NAME`, `USER_NAME`, `VAULT`, `CANARY_PHRASE`, identity prefs), with sensible defaults in brackets. Pre-set env vars (`BOT_NAME=nlbot ./first-time-setup.sh`) skip the corresponding prompt; values already populated in `setup-state.md`'s Values block are also picked up automatically. After the run, the script prints the remaining manual commands (NOPASSWD grant, reboot, `setup-status.sh` to watch the bot-driven Steps 5–9).

The rest of this doc is the canonical reference: read along to know exactly what the script is doing, or use the prose blocks to do any step by hand.

## What you'll need before you start

- A Linux machine you can leave running (LXC container, spare laptop, small VPS — see [persistence-and-hardware.md](persistence-and-hardware.md) for the floor: 2 cores / 2 GB RAM / 8 GB disk).
- A Claude Code subscription (the CLI tool, not the API).
- A Telegram account with a phone (to talk to BotFather).
- About 30 minutes of focused time. You can stretch it over a weekend; nothing here is time-pressured.

### Where am I? (sanity check)

At any point — including right now, before you've started — you can run the kit's state probe to see what's installed, what's missing, and which manual step to do next:

```bash
BOT_NAME=<your-bot-name> bash <kit-clone>/runtime/setup-status.sh
```

It runs read-only and prints a column-aligned report of system prereqs, bot-user state, vault state, and (after the Step 4 reboot) bot-driven phase progress. Each missing item shows you the doc + step that addresses it. **You can re-run it any time you're unsure where you are.**

## Step 1 — Install Claude Code + prereqs (5 min)

On the Linux box, follow the official install: <https://claude.com/download>. Then log in once interactively:

```bash
claude
```

Follow the prompts, accept the TOS. **Do this at a real terminal, not in a tmux session you'll later detach** — the TOS gate doesn't render well in a detached pane and the persistent setup we'll build relies on having that gate already cleared.

Verify the rest of the prereqs:

```bash
claude --version
docker compose version
tmux -V
tailscale status
node --version
```

Each should print a version string. Notes:

- `docker compose version` needs the compose plugin (needed by SilverBullet in Step 5).
- `tailscale status` should show your tailnet — if it errors, run `sudo tailscale up`.
- `node --version` only matters if you're doing the optional web shell (Step 7); Node 20+.

Anything that fails: install the missing piece before continuing. `docker compose version` is the trickiest — modern installs use the compose plugin (`docker compose`, two words), not the old standalone binary (`docker-compose`, hyphen).

## Step 2 — Drop in the vault (5 min)

If you cloned the kit per `bootstrap.md`, the clone IS your vault — the kit files (`CLAUDE-nate.md`, `templates/`, `dot-claude/`, `runtime/`) sit alongside the vault files you're about to create (`journals/`, `handoffs/`, etc.). The clone directory's path depends on whatever name you cloned it under. Set it once as `VAULT` and everything below uses that variable:

```bash
VAULT=~/nlbot
cd $VAULT
```

If you cloned with a different directory name (e.g. `~/natebot` because your bot is called `natebot`), set `VAULT` to that path instead. Every subsequent code block in this doc uses `$VAULT`, so just changing this one line propagates everywhere.

Build the vault skeleton and copy the kit's seed files:

```bash
mkdir -p $VAULT/journals/fiction $VAULT/handoffs $VAULT/processes
KIT=$VAULT

cp $KIT/CLAUDE-nate.md       $VAULT/CLAUDE.md
cp -r $KIT/templates         $VAULT/templates
# NOTE the rename in the next command: dot-claude → .claude
cp -r $KIT/dot-claude        $VAULT/.claude

# Seed the bot's identity from the bundled templates
cp $VAULT/templates/identity.md     $VAULT/identity.md
cp $VAULT/templates/user-profile.md $VAULT/user-profile.md
cp $VAULT/templates/soul-loop.md    $VAULT/soul-loop.md

# Seed the SilverBullet vault — top-level index pages + process docs
cp $KIT/templates/vault-pages/*.md  $VAULT/
cp $KIT/templates/processes/*.md    $VAULT/processes/

touch $VAULT/journals/journal.md
```

Now open `CLAUDE.md` in your editor and replace every `[Nate]` and `[Your Bot's Name]` placeholder with your actual name and the bot's name. Same with `identity.md` and `user-profile.md` — fill in the canary phrase, your role, what you want from this bot. There's no "right" answer; first-pass guesses are fine, you'll edit later.

The vault-page copies above also contain `<BOT_NAME>` / `<USER_NAME>` / `<VAULT>` placeholders. If you're walking through this with the assisting CC and Phase 0 (see `setup-orchestrator.md`), those get substituted automatically when CC applies the Phase 0 map. If you're doing DIY install, run a one-shot `sed` over `$VAULT/*.md $VAULT/processes/*.md` once you've decided on the values.

**About the canary phrase:** in `identity.md`, you'll set a short string ("the lighthouse keeper waves at midnight" — anything memorable). The bot is supposed to remember it without re-reading the file. If at any point it can't recall the phrase, that's its signal it has lost context (post-restart, post-compaction) and needs to re-anchor by reading `identity.md` and `user-profile.md`. It's not a security secret; just an orientation anchor.

## Step 3 — Disable the keybindings that kill sessions (1 min)

Edit `~/.claude/keybindings.json`:

```json
{
  "disabled": ["ctrl+x ctrl+e", "ctrl+x ctrl+k"]
}
```

Skip this and you'll discover why on day three. See [persistence-and-hardware.md](persistence-and-hardware.md) for the story.

> ### ⚠ Heads-up: two `.claude/` directories
>
> By this point in setup you have **two distinct `.claude/` directories** doing different things. People confuse them; this is the most common kit-bring-up footgun after the locale issue.
>
> | Path | Scope | What it holds |
> |---|---|---|
> | `~/.claude/` (your `$HOME`) | Global — applies to every Claude Code session you start as this unix user | `keybindings.json` (the file you just edited), `settings.json`, `mcp.json`, `projects/<encoded-cwd>/` (history), and any agents/commands/hooks you want available everywhere |
> | `~/<bot-name>/.claude/` (inside the vault, the renamed `dot-claude/` from Step 2) | Project — applies **only** when Claude Code is launched with the vault as its CWD | The kit's `agents/*.md` (soul-loop-runner, secretary, etc.) and `commands/*.md` (`/soul-loop`, `/secretary`, …) |
>
> Three specific things that bite:
>
> 1. **Forgetting the `dot-claude` → `.claude` rename in Step 2.** If you copied it as `dot-claude/` instead of `.claude/`, Claude Code won't find the project agents or slash commands and they'll silently do nothing — `/soul-loop` will just return "unknown command." Verify: `ls -d ~/<bot-name>/.claude` should show the directory.
>
> 2. **Editing the wrong `.claude/`.** Want a slash command everywhere? Edit `~/.claude/commands/`. Want one only in this vault? Edit `~/<bot-name>/.claude/commands/`. Both directories accept the same kinds of files; the difference is scope.
>
> 3. **Project config wins on merge.** If both directories contain `agents/secretary.md`, the vault's version overrides the global one when Claude Code is running with the vault as CWD. If you ever wonder "why isn't my edit taking effect," you might be editing the loser.
>
> Also worth knowing: `~/.claude/projects/<encoded-cwd>/` stores per-CWD session history. If you ever move the vault (`mv ~/oldname ~/newname`), the bot's "recent sessions" go orphaned and a fresh project entry is created under the new path. The journal and the bot itself are unaffected — only `claude --continue`'s memory of "what was I doing in that other directory" resets.

## Step 4 — Wire up persistence (10 min)

Copy the runtime scripts from this kit into the vault, then drop the systemd unit:

```bash
cp $KIT/runtime/start-claude.sh $VAULT/start-claude.sh
chmod +x $VAULT/start-claude.sh
```

The script has a `cd` line near the top that hardcodes the vault path. Open `$VAULT/start-claude.sh` and update that line if it doesn't already point at `$VAULT`.

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

### Final action: grant the bot scoped sudo NOPASSWD (then reboot)

This is the privilege grant that lets the bot drive Steps 5–9 from inside the detached tmux session (where there's no terminal for sudo to prompt against). **Do this only after the steps above all worked** — by this point you have a working `claude-code.service`, a verified tmux session, and everything else from bootstrap.md sane. The NOPASSWD entry is the "I'm ready to hand the keys over" gate.

```bash
# Substitute $BOTUSER with your bot's unix username
# (the one from bootstrap.md Step 2)
sudo tee /etc/sudoers.d/$BOTUSER >/dev/null <<EOF
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/systemctl
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/crontab
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/docker
EOF
sudo chmod 440 /etc/sudoers.d/$BOTUSER
sudo visudo -cf /etc/sudoers.d/$BOTUSER

# Verify the bot user can actually use it
sudo -u $BOTUSER sudo -n /usr/bin/systemctl --version > /dev/null \
  && echo "NOPASSWD OK" \
  || echo "NOPASSWD FAILED"
```

Anything outside `systemctl / crontab / docker` still prompts for the password and stays your job. If something feels off here, **don't reboot yet** — debug first. If you want to undo: `sudo rm /etc/sudoers.d/$BOTUSER`. If you'd rather grant blanket `NOPASSWD: ALL` instead of scoped (bigger blast radius if the bot ever runs amok), substitute `NOPASSWD: ALL` for the comma-list above. The kit's recommended path is scoped.

### Reboot

**Reboot the box now and verify it comes back up.** This is non-negotiable — verify the persistence works before you start trusting it. After the reboot:

```bash
systemctl status claude-code.service     # active (running)
tmux attach -t claude                    # back in the session
```

## After the reboot — bot-driven setup (Steps 5–9)

After the Step 4 verification reboot, `claude-code.service` brings the bot online and the bot itself drives the rest of setup. The kit's `setup-runner` subagent reads `setup-state.md` Current phase on every soul-loop, executes the next phase, advances state, and posts progress to the journal. You can watch via `tmux attach -t claude` (and later via Telegram, once Step 6 finishes).

**Total elapsed:** ~5–10 minutes until you get a "Setup complete" Telegram message.

### What the bot does

| Phase | What runs |
|---|---|
| `step-5-cron` | **First bot phase, intentionally.** Installs crontab entries (soul-loop / secretary / wake-up / midnight-maintenance) for the bot's unix user so the heartbeat + journaling pipeline starts on minute one. Everything downstream becomes re-drivable from the heartbeat. |
| `step-6-silverbullet` | Generates SB_USER_PASSWORD + SB_AUTH_TOKEN (`openssl rand`), writes `docker-compose.yml`, `docker compose up -d`, `sudo tailscale serve --https=443`. |
| `step-7-web-shell` | `npm install`, generates `WEB_SESSION_SECRET` + `WEB_UI_PASSWORD`, writes `.env`, installs `<BOT_NAME>-web.service`, `sudo tailscale serve --https=8443`. |
| `step-8-memory` | Installs memorious-mcp as the baseline memory backend. |
| `step-9-telegram-daemon` | Copies `tg-bot.py` + `tg-post.sh` into `.telegram/`, drops the systemd unit, posts a BLOCKER asking for BotFather token. (Last phase — by the time you hit this, the rest of the bot is fully operational, so the BotFather handoff isn't gating anything else.) |
| `step-9-telegram-creds-blocker` | **Waits on you.** See "What you still do" below. |
| `step-9-telegram-activate` | Enables + starts `telegram-bot.service`, sends a test message round-trip. |
| `done` | Bot transitions to operational mode. |

Each phase is **idempotent** — re-running is safe if anything mid-fails. The bot's soul-loop will keep retrying until the phase succeeds or hits a blocker.

### What you still do

The bot writes `BLOCKER <name>: <instruction>` lines in `setup-state.md` `## Blockers` whenever it needs you. The soul-loop stops dispatching setup-runner until you remove (or `RESOLVED <name>:` the BLOCKER). Expected blockers:

1. **`BLOCKER telegram-botfather`** — happens during `step-9-telegram-daemon` (the *last* phase, intentionally — everything else is already running by this point). Open Telegram, message `@BotFather`, `/newbot`, save the token. DM your new bot once. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find your `chat.id`. Paste `TG_BOT_TOKEN`, `TG_BOT_USERNAME` (`@<name>_bot`), and `TG_CHAT_ID` into `setup-state.md` Values. Remove the BLOCKER line.

2. **`BLOCKER web-shell-credentials`** — informational, doesn't block progress. The bot generated a username + password for the web shell; write them down somewhere recoverable before continuing.

3. **`BLOCKER tailscale-cert`** *(may not appear)* — Tailscale's first `serve --https` triggers a cert provisioning. If Tailscale needs interactive approval, the bot will pause here.

### Watching it happen

```bash
tmux attach -t claude          # see the bot working in real time
# ctrl+b then d to detach (don't kill it)

# Or, just read the journal as the bot writes it:
tail -f <VAULT>/journals/journal.md
```

Once Step 6 completes, all further progress reports go to your Telegram.

### If something fails

The bot's setup is idempotent. If a phase fails:

```bash
# Reality check: what's actually running vs. what setup-state.md claims?
<VAULT>/runtime/setup-status.sh
```

This probes every phase (docker container, systemd service, crontab entry, MCP registration) and prints a recommendation: "declared phase X, reality reached Y, run /setup to advance." Run it from any shell — it's read-only.

Then watch the live session if needed:

```bash
tmux attach -t claude
tail -50 <VAULT>/journals/journal.md
```

Common causes of phase failures are usually a missing prereq from bootstrap.md (docker group not active in this login, sudo NOPASSWD entry wrong or missing for the bot user — covered in [bootstrap.md](bootstrap.md) Step 5 and first-time-setup.md Step 4's final action). Fix the underlying issue, then either wait for the next soul-loop fire or run `/setup` manually from the tmux pane to force a retry. The bot's setup-runner re-reads `setup-status.sh` at the start of every dispatch and trusts reality over the state file, so re-running is always safe.

---

## Reference: detailed Step 5–9 instructions (assisting-CC fallback)

The bot-driven flow above is the default. If you'd rather drive Steps 5–9 yourself or via the assisting CC instance (the `setup-orchestrator.md` flow before Step 4), the detailed instructions for each step follow.

### Step 5 detail — Cron the heartbeat (first bot phase, intentionally)

**Intentionally first.** Installing the heartbeat + journaling pipeline on minute one means soul-loop, secretary, wake-up, and midnight-maintenance all start running immediately. Every later phase becomes re-drivable from the heartbeat if it mid-fails; the journal silently auto-populates from minute one even if the rest of the install stalls.

⚠ **Do this AFTER the verification reboot from Step 4 — not before.** If cron fires before the tmux session exists, `inject-prompt.sh` will silently noop.

```bash
mkdir -p $VAULT/cron-prompts
cp $KIT/runtime/inject-prompt.sh $VAULT/cron-prompts/
cp $KIT/runtime/cron-prompts/*.md $VAULT/cron-prompts/
chmod +x $VAULT/cron-prompts/inject-prompt.sh
```

Then `crontab -e`:

```cron
*/10 7-23 * * * <VAULT>/cron-prompts/inject-prompt.sh /soul-loop
*/30 * * * *   <VAULT>/cron-prompts/inject-prompt.sh /secretary
30 7 * * 1-5   <VAULT>/cron-prompts/inject-prompt.sh /wake-up
5 0 * * *      <VAULT>/cron-prompts/inject-prompt.sh /midnight-maintenance
```

Within 10 minutes you should see soul-loop fires in `cron-prompts/job-log.md`, and the secretary fires every 30 minutes capturing journal-worthy moments from your conversations.

### Step 6 detail — SilverBullet (the vault editor)

This is your daily interface to the bot's brain. Walked through fully in [silverbullet-setup.md](silverbullet-setup.md). The condensed version:

1. Generate two random secrets:
   ```bash
   openssl rand -base64 24    # for SB_USER password
   openssl rand -base64 24    # for SB_AUTH_TOKEN
   ```
2. Drop a `docker-compose.yml` in `$VAULT/` with the silverbullet service block (template in [silverbullet-setup.md](silverbullet-setup.md)) — set `SB_USER=<bot-name>:<password>`, `SB_AUTH_TOKEN=<token>`, mount `$VAULT:/space`, bind `127.0.0.1:3001:3000`.
3. `docker compose up -d` and visit `http://localhost:3001`. Log in with the SB_USER credentials. You should see your vault.
4. Expose via Tailscale: `sudo tailscale serve --bg --https=443 http://127.0.0.1:3001`. Now reachable from your phone at `https://<host>.<tailnet>.ts.net`.
5. Install the **TreeView** plug — essential for vault navigation. In SilverBullet:
   1. Open the command palette (Ctrl/Cmd-K).
   2. Type `Plugs: Add Plug`.
   3. Paste: `github:silverbulletmd/silverbullet-treeview/treeview.plug.js`
   4. Run `Plugs: Update`, then reload (Ctrl/Cmd-R). The folder sidebar should appear.

   Other plugs (e.g., `silverbullet-tasks` for richer task views) install the same way. Defaults are fine for everything else; skip a `SETTINGS.md` unless you have a specific reason.

When you first land on SilverBullet, [[index]] is the entry point (created from `templates/vault-pages/index.md` in Step 2) and [[dashboard]] shows live queries for open handoffs / tasks / recent activity. You can now read `journals/journal.md` from your phone and leave handoff tasks (`- [ ] do X #handoff`) for the bot.

### Step 7 detail — Web shell

The web shell is a small Node.js server that attaches to your `claude` tmux session and renders it through xterm.js in the browser, login-protected and Tailscale-only. Walked through end-to-end in [web-shell.md](web-shell.md). The condensed version:

1. Copy `web-terminal/` into `$VAULT/web-terminal/`.
2. `cd $VAULT/web-terminal && npm install`.
3. Create `.env` with `PORT=3000`, `SESSION_SECRET=<random>`, `UI_USERNAME=<bot-name>`, `UI_PASSWORD=<random>`.
4. Drop `/etc/systemd/system/<BOT_NAME>-web.service` (template in the doc). Enable and start.
5. `sudo tailscale serve --bg --https=8443 http://127.0.0.1:3000`.
6. Visit `https://<host>.<tailnet>.ts.net:8443`, log in, watch Claude type.

On iOS, "Add to Home Screen" makes it behave like a native app (PWA manifest is included).

### Step 8 detail — Vector memory (memorious-mcp baseline)

Installed by default during bot-driven setup. Walked through in [memory.md](memory.md). The doc covers the secretary note-capture pattern (cron-driven background note-taker) — useful once your conversations get long enough that you'd appreciate Claude writing the journal for you. If you want to *skip* the memory layer entirely (grep-only), see the bottom of `memory.md`.

### Step 9 detail — Telegram

**Intentionally last** — every other piece of the bot is operational by now, so the BotFather handoff (the only mid-flow human BLOCKER in the whole setup) doesn't gate anything else. Walked through end-to-end in [telegram-integration.md](telegram-integration.md). The condensed version:

1. In Telegram, message `@BotFather`, send `/newbot`, follow prompts, save the token.
2. DM your new bot once. Then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find your `chat.id`.
3. Create `$VAULT/.telegram/config` with `BOT_TOKEN=`, `CHAT_ID=`, `BOT_USERNAME=`. `chmod 600` it.
4. Copy `tg-bot.py` and `tg-post.sh` from `runtime/` into `$VAULT/.telegram/`. Make them executable (`chmod +x`).
5. Drop `/etc/systemd/system/telegram-bot.service` (template in [telegram-integration.md](telegram-integration.md)). Enable and start.
6. DM your bot something — anything. `journalctl -u telegram-bot -f` should show the message arrive. The file `.telegram/new-messages.txt` should appear in your vault.

*Aware-of-but-recommended-against: [Portainer](portainer.md) is a popular browser Docker UI, but it doesn't play well with a Claude-managed bot — Claude edits `docker-compose.yml` directly via `docker compose up -d`, which causes Portainer's stack definition to drift from reality. See [portainer.md](portainer.md) for the full reasoning.*

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
