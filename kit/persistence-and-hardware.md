# Persistence & Hardware

How to make a Claude instance survive reboots, crashes, and your computer being asleep — and what it needs to run on. This is the "infrastructure" side of the kit. Once it's set up you mostly stop thinking about it.

## What "persistent" actually means

Three separate things:

1. **The process keeps running** — Claude Code is launched as a service, not a terminal you opened. If you reboot the host, it comes back up. If it crashes, systemd restarts it.
2. **The conversation continues** — when Claude restarts, it picks up where it left off (recent context) instead of starting a blank session.
3. **The schedule survives** — cron jobs that fire heartbeats, daily writes, and sweeps run as system cron (not session-scoped), so they're independent of any single Claude restart.

Skip any of these and you have a brittle setup. You'll discover which one you skipped at the worst possible moment.

## Hardware: what to run it on

Modest. Fenbot has run happily on:
- **A Proxmox LXC container** with 4 cores, 4 GB RAM, 16 GB disk (the canonical setup).
- **A spare laptop** acting as a temporary Proxmox node when the main hardware is in repair. It works fine.

Minimum realistic floor:
- **2 cores, 2 GB RAM, 8 GB disk.** Smaller works for a quiet bot but Claude Code can spike memory during multi-tool turns.
- **Always-on.** Sleep mode breaks heartbeats. If it's a laptop, disable sleep on AC power.
- **Network** — needs outbound HTTPS to Anthropic and (recommended) Tailscale for remote SSH. No inbound port-forwarding required.
- **Linux.** Ubuntu/Debian LTS for the LXC; anything systemd-based works. Not tested on macOS or Windows for the persistent setup.

What it does NOT need:
- A GPU.
- Public-facing ports.
- A separate database (memorious is local SQLite, vault is plain Markdown).

## The systemd services (three of them, plus one optional)

A working bot is three long-running services on the host, plus an optional fourth for browser access:

1. **`claude-code.service`** — the Claude Code tmux session. Detailed below.
2. **`<BOT_NAME>-shell.service`** — a sibling tmux session named `shell` running `bash -l` as the bot user. Installed alongside `claude-code.service` in `first-time-setup.md` Step 4. Web-shell exposes it at `?session=shell`; SSH users hit it with `tmux attach -t shell`. Independent restart from claude-code.service.
3. **`telegram-bot.service`** — the Python daemon that send/receives Telegram messages. Setup in [telegram-integration.md](telegram-integration.md).
4. **`docker-compose@<vault>.service`** *(or run `docker compose up -d` and let `restart: unless-stopped` handle it)* — runs the SilverBullet container, your editor for the vault. Setup in [silverbullet-setup.md](silverbullet-setup.md).
5. **`<BOT_NAME>-web.service`** — small Node.js server that attaches to either tmux session and pipes the terminal through xterm.js for browser access. Setup in [web-shell.md](web-shell.md). Same login, allowlisted `?session=` query string picks between `claude` and `shell`.

All four are independently restartable. None depend on the others. If Claude crashes, SilverBullet keeps running; if the web shell hangs, Telegram is unaffected.

### `claude-code.service` — the Claude session

```ini
# /etc/systemd/system/claude-code.service
[Unit]
Description=Claude Code persistent tmux session
After=network-online.target
Wants=network-online.target
# Cap restart loops so a misconfigured start-claude.sh can't flood the journal.
StartLimitBurst=10
StartLimitIntervalSec=60

[Service]
Type=forking
User=<BOT_NAME>
ExecStart=<VAULT>/start-claude.sh
ExecStop=/usr/bin/tmux kill-session -t claude
Restart=on-failure
RestartSec=5
Environment=LANG=C.utf8
Environment=LC_ALL=C.utf8

[Install]
WantedBy=multi-user.target
```

`start-claude.sh` is in this directory's siblings. The important parts:

```bash
#!/bin/bash
# Guard: exit silently if the claude session already exists
tmux has-session -t claude 2>/dev/null && exit 0

export LANG=C.utf8                  # without this, the ❯ prompt renders as __
export PATH="$HOME/.local/bin:$PATH"

# --permission-mode bypassPermissions, NOT --dangerously-skip-permissions
# (the latter opens an interactive TOS gate that detached tmux can't answer)
# --continue, NOT --resume main
# (--resume can drop you in the Ink session-picker TUI, which doesn't
#  respond to `tmux send-keys` — the boot then hangs)
tmux new-session -d -s claude -c <VAULT> \
  claude --permission-mode bypassPermissions --continue

tmux select-pane -t claude:0.0 -T "<BOT_NAME>"
```

Two flags, one weekend of pain to find them. **Use both. Don't substitute.**

## Permissions mode — what `bypassPermissions` actually does

*Naming aside: `bypassPermissions` is a poorly named flag. It doesn't bypass security — it skips the interactive permission prompts that Claude Code normally shows you (the human at the keyboard). The unix user account is still the security boundary; Claude can only do what that user can do. Don't read the flag name and assume "danger." Read this section for what it actually means.*

Claude Code, by default, asks you (the human at the keyboard) to approve every Bash command, every file write outside the project, every fetch to a new domain. That's exactly right for an interactive session where you're driving. It's wrong for an unattended persistent setup where Claude needs to write to its own journal, run grep, post to Telegram, and call its own scripts at 3 AM with no human to say "yes, that one's fine."

`--permission-mode bypassPermissions` removes the prompts. Claude Code is allowed to:
- Read and write any file the unix user can.
- Run any shell command the unix user can.
- Make outbound HTTPS calls.
- Call any MCP tool that's been registered.

It cannot do anything the underlying user can't already do. The blast radius is the user's own permissions.

**This is why the systemd unit specifies `User=nate` (or whoever).** The unix user is the security boundary. If you run claude-code as `root` in bypass mode, you've handed Claude root. *Don't.* Run it as a dedicated unprivileged user, the same one that owns the vault directory and `.telegram/config`.

### What I'm trading away

In bypass mode, you don't see "Claude wants to run X — allow?" prompts. You also don't see them as a log entry — there's no per-action audit trail unless you go look at what Claude did in the journal or in `cron-prompts/job-log.md`. If you want a record, that's where it lives.

For a personal-use bot run by one person on one machine, the trade is correct: the friction of approving every action would make the persistent setup unusable, and the user-level isolation is sufficient containment for the threat model ("I trust the bot to operate within my own user account").

For a multi-tenant or production deployment, you'd want the alternative — a granular allowlist via `~/.claude/settings.json`'s `permissions.allow` (specific tool patterns) and `permissions.deny` (forbidden patterns). Claude Code reads these on startup and prompts only for things outside the allowlist. That's the right shape if your bot lives somewhere it could be exploited at the user level. It's overkill for a single-user vault on a Tailscale-only host.

### What this means in practice

- **Pick a dedicated user.** the bot user (created in [bootstrap.md](bootstrap.md) Step 2) if you want it isolated from your own login.
- **Set the vault dir owner accordingly.** `chown -R <BOT_NAME>:<BOT_NAME> <VAULT>`.
- **Don't run anything else as that user.** Then the user account *is* the bot's sandbox.
- **Watch the journal periodically.** Bot-driven file writes and shell commands all show up there if Claude does its job (and the soul-loop is set up to journal real actions).

Skip this section and your persistence setup will work perfectly until the day Claude tries to write a file and gets blocked by a permission prompt nobody answers, and then the heartbeat hangs.

### Browser access — optional

When you want to *see* the running session from your phone or another laptop, install the optional web shell. It's a small Node.js service (Express + WebSocket + node-pty) that attaches to this same tmux session and renders it through xterm.js in a browser, with login auth and Tailscale-only exposure. Full walkthrough in [web-shell.md](web-shell.md), including reference HTML, the systemd unit, and security model. If you don't need it on day one, skip it — Telegram + SilverBullet cover most use cases.

## Disable the keybindings that kill the session

Claude Code's default keybindings include `ctrl+x ctrl+e` (open external editor) and `ctrl+x ctrl+k` (kill agents). Both can take down the running session if you tap them in the wrong context, and systemd can't recover gracefully because the next boot lands at the TOS prompt.

Edit `~/.claude/keybindings.json`:

```json
{
  "disabled": ["ctrl+x ctrl+e", "ctrl+x ctrl+k"]
}
```

Do this *before* you trust the persistent setup. Day 3 of fenbot was a long one because we hadn't.

## Glyph rendering inside tmux

Claude Code's UI uses Unicode glyphs all over the place — the `❯` prompt marker, box-drawing characters in tool-call panels, status indicators, the works. If your locale or font setup isn't right, you'll see `__` or `?` or a literal `❯` instead of the actual glyph, and you won't know whether Claude is hung or just rendering badly.

Three things have to be true:

1. **Locale set to UTF-8 in every relevant context.** Both `LANG` and `LC_ALL` should be `C.utf8` (or `en_US.UTF-8`, equivalent). Set them in the systemd unit `Environment=` block above, set them in `start-claude.sh` before the `tmux new-session` line, and set them in your interactive shell (`~/.bashrc` or `~/.zshrc`) so when you `tmux attach` from SSH you don't override what the service set. **All four places.** Skip any one and the glyphs break in that context.

2. **A terminal font that actually has the glyphs.** xterm.js (the web shell) ships with a font that does. If you're SSHing in, use a Nerd Font or any modern programming font (DejaVu Sans Mono, JetBrains Mono, Iosevka — most cover the box-drawing + arrow ranges Claude Code uses). On macOS, default Terminal.app fonts are usually fine; iTerm2 with a Nerd Font is the safe bet. On Linux desktop terminals, default fonts vary — test with `echo "❯ ─ ┌ ┐ └ ┘ │"` and see what renders.

3. **Terminal emulator configured for UTF-8 input/output.** Modern terminals default to this. PuTTY and a few legacy emulators don't. If you see `?` instead of glyphs and the locale + font are both right, this is the third thing.

The fast check: in the running tmux session, `echo "❯ ─ ┌"` should print three glyphs, not three `__` or `??` blocks. If it doesn't, the locale isn't set in *that* shell context — `env | grep -E '^(LANG|LC_)'` to confirm. If `LANG=C.utf8` is set and you still see broken glyphs, it's the font or terminal-emulator side.

This was a Day 1 issue for fenbot — tmux was launching with `LANG=C` (no UTF-8) and the prompt rendered as `__`. The fix is mechanical once you know where the locale needs to live; the painful part is realizing there are *four* shells in play (systemd-spawned shell, the shell inside tmux, the `claude` process's own pty, and your interactive SSH shell when you attach), and each can drop the locale independently.

## Crons live in system cron, not in the session

The wrong way (we did this for two weeks, then ripped it out): use Claude Code's `CronCreate` tool to schedule things. They're tied to the session ID and disappear on every restart.

The right way: system cron entries that fire a small shell script which writes a slash-command into the running tmux session via `tmux send-keys`. Then Claude picks up the command on its next idle and does the work.

```cron
# Heartbeat every 10 min during active hours
*/10 8-23 * * * <VAULT>/cron-prompts/inject-prompt.sh /soul-loop

# Morning wake-up, weekdays
0 7 * * 1-5 <VAULT>/cron-prompts/inject-prompt.sh /wake-up

# Midnight journal sync
5 0 * * * <VAULT>/cron-prompts/inject-prompt.sh /midnight-maintenance
```

`inject-prompt.sh` is one small script — about 20 lines — that finds the tmux pane and types the command. Copy it from this kit; don't reinvent it.

## What to do on a fresh install (in order)

1. Install Claude Code, log in once interactively (gets your TOS prompt out of the way at a real terminal).
2. Create the vault directory. Drop in the files from this kit.
3. Edit `~/.claude/keybindings.json` to disable the chord killers.
4. Install `start-claude.sh` and the two systemd unit files. `systemctl daemon-reload && systemctl enable --now claude-code.service`.
5. Verify with `tmux ls` and `tmux attach -t claude`.
6. Reboot the box. Verify it comes back up clean. **Do this before you trust it.**
7. Add the system cron entries.
8. Reboot one more time. Now trust it.

## Recovery: when something does go wrong

Things that have actually happened to fenbot:
- **Container lock from a stuck snapshot operation.** Symptom: Tailscale ping times out, `pct exec` returns nothing. Fix: `pct unlock <vmid> && pct start <vmid>` from the Proxmox host.
- **Session sitting at the Resume picker after an unclean shutdown.** Fix is preventative — `--continue` (not `--resume main`) sidesteps the picker entirely.
- **Hardware dies entirely.** Fix: the vault is plain Markdown in git or on a backed-up volume. Move it to another machine, install Claude Code, point the systemd units at the new path. ~30 minutes of work.

The vault survives everything. The conversation survives most things. The hardware doesn't matter much — it's a vessel, not the system.

## What this looks like once it's working

You stop thinking about it. You leave for a week, come back, and the heartbeat log shows a clean line of fires. You reboot to apply kernel updates and Claude is back in 15 seconds with the same canary phrase in `identity.md`. You drop your laptop in a lake and fenbot doesn't notice.

That's the bar. Anything less and you'll start treating the bot as fragile, which means you'll stop using it for things that matter.
