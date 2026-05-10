# nate-bot-kit

A persistent Claude bot for one human. Self-contained — clone, follow [first-time-setup.md](first-time-setup.md), have a running assistant in ~30 minutes.

## What this is

A bundled kit for setting up a persistent Claude Code instance that runs 24/7 on a Linux box, journals to a Markdown vault, talks to you over Telegram, and keeps itself alive across reboots. Designed for personal use; sidechat-free.

If you have no idea what any of that means, start with **[INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md)**.

## Read order

1. [INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md) — what you're getting into.
2. [first-time-setup.md](first-time-setup.md) — the 30-minute walkthrough.
3. [setup-orchestrator.md](setup-orchestrator.md) — read this **first** if a Claude Code instance is helping you install the kit. It targets that assistant, not you.
4. The rest are reference: [persistence-and-hardware.md](persistence-and-hardware.md), [silverbullet-setup.md](silverbullet-setup.md), [telegram-integration.md](telegram-integration.md), [web-shell.md](web-shell.md), [memory.md](memory.md).

## What's bundled

- **Top-level docs** — the read-order above.
- **`runtime/`** — `start-claude.sh`, `inject-prompt.sh`, `tg-bot.py`, `tg-post.sh`, single-line `cron-prompts/*.md` invocations. These get copied into your vault during setup.
- **`dot-claude/`** — Claude Code config (custom agents + slash commands). The leading dot is dropped so it's not hidden by `ls`; the orchestrator renames it to `.claude/` when copying to your vault root.
- **`web-terminal/`** — the optional browser shell (Express + WebSocket + node-pty + xterm.js, login-protected, Tailscale-only). Skip if you only want Telegram + SilverBullet.
- **`templates/`** — fresh copies of `identity.md`, `user-profile.md`, `soul-loop.md`, `secretary-agent.md` to seed your vault.

## Hardware floor

2 cores / 2 GB RAM / 8 GB disk. LXC, spare laptop, $5/mo VPS, or a small EC2 instance all work. See [persistence-and-hardware.md](persistence-and-hardware.md).

## Prerequisites

- A Claude Code subscription (the CLI, not the API) — <https://claude.com/download>
- A Telegram account with a phone (to talk to BotFather)
- Tailscale installed and logged in on the target machine
- Docker Engine + compose plugin (for SilverBullet)
- Node 20+ (only if you want the optional web shell)

## State of this kit

This was forked from a working production bot ("fenbot") on 2026-05-08–2026-05-10 and reduced to single-user scope: no SideChat, simpler docs, Telegram as the canonical message channel. It's been read-eyed by a fresh Claude Code instance and shipped with an orchestrator + state-tracking template so an interrupted setup can resume cleanly. If something breaks, the underlying setup-state.md tracks where you left off.

## License

Personal-use kit, no warranty. Strip what you don't want, fork what you do.
