# nate-bot-kit

A persistent Claude bot for one human. Self-contained — clone, follow [first-time-setup.md](first-time-setup.md), have a running assistant in ~30 minutes.

## What this is

A bundled kit for setting up a persistent Claude Code instance that runs 24/7 on a Linux box, journals to a Markdown vault, talks to you over Telegram, and keeps itself alive across reboots. Designed for personal use; sidechat-free.

If you have no idea what any of that means, start with **[INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md)**.

## Read order

0. [bootstrap.md](bootstrap.md) — pre-flight prereqs to run on a fresh EC2 (or any clean Linux box) **before** Claude Code is installed. Skip this if your machine already has Node 20, Docker, tmux, scoped sudo NOPASSWD, and Claude Code.
1. [INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md) — what you're getting into.
2. [first-time-setup.md](first-time-setup.md) — the walkthrough. Steps 1–4 are human + (optional) assisting-CC. After Step 4's reboot, **the bot drives Steps 5–9 itself.**
3. [setup-orchestrator.md](setup-orchestrator.md) — read this **first** if a Claude Code instance is helping you with Steps 1–4. Phase 0 (placeholder collection) and Steps 1–4 only; Steps 5–9 belong to the bot after the reboot.
4. **Core reference** (each is now bot-executed during Steps 5–9; you read them only if you want to know what the bot is doing): [persistence-and-hardware.md](persistence-and-hardware.md), [silverbullet-setup.md](silverbullet-setup.md), [telegram-integration.md](telegram-integration.md), [web-shell.md](web-shell.md), [memory.md](memory.md).
5. **Read-but-don't-install-by-default**: [portainer.md](portainer.md) — explains why a Claude-managed bot has specific friction with Portainer's stack-definition model. Skim before deciding.

**TL;DR of the setup flow:** you walk `bootstrap.md` end-to-end on a fresh box (~15 min), then `first-time-setup.md` Steps 1–4 (~15 min, ending in a reboot). The bot wakes up, drives Steps 5–9 itself (~5–10 min), and pings your Telegram when it's done. You handle BotFather mid-flow when the bot asks. Total: ~30–40 min of your attention.

## Repo layout

The clone you check out has three concerns separated at the directory level:

```
<repo_root>/
├── kit/              ← read-only kit source (this is what you pull from upstream)
│   ├── *.md          ← walkthrough docs (you're reading them now)
│   ├── runtime/      ← bash helpers, systemd-creds, hooks
│   ├── templates/    ← vault-page + identity seeds
│   ├── dot-claude/   ← source for the bot's .claude/ at install time
│   ├── web-terminal/ ← Express+xterm web shell
│   └── docker-compose.yml
├── vault/            ← SilverBullet space (docker mounts here as /space)
│   ├── CLAUDE.md, identity.md, user-profile.md, CONFIG.md
│   ├── journals/, handoffs/, processes/
│   └── _plug/, _templates/
└── .claude/          ← bot's slash commands + agents (kit-rendered, OVERWRITES on git pull)
    .telegram/        ← Telegram daemon state
    cron-prompts/     ← cron invocation files + bot logs
    setup-state.md    ← live setup phase + Phase-0 values
    start-claude.sh   ← rendered from kit/runtime/start-claude.sh
```

You only ever edit files under `vault/` (your bot's content) and bot-runtime state at the repo root (mostly `setup-state.md` and `CLAUDE.md`, the latter symlinkable). Everything under `kit/` is upstream-managed.

## What's bundled

- **Top-level docs** — the read-order above.
- **`runtime/`** — `start-claude.sh`, `inject-prompt.sh`, `tg-bot.py`, `tg-post.sh`, single-line `cron-prompts/*.md` invocations. These get copied into your vault during setup.
- **`dot-claude/`** — Claude Code config (custom agents + slash commands). The leading dot is dropped so it's not hidden by `ls`; `first-time-setup.sh` renders it into `<REPO_ROOT>/.claude/` via `runtime/refresh-claude-dir.sh`, applying Phase-0 substitution. A git `post-merge` hook re-runs the refresh on every `git pull`, so kit updates to slash commands and agents propagate automatically. **`.claude/` is kit-owned — don't hand-edit; the hook will overwrite. Fork the kit and edit `dot-claude/` at the source if you need to override.**
- **`web-terminal/`** — the optional browser shell (Express + WebSocket + node-pty + xterm.js, login-protected, Tailscale-only). Skip if you only want Telegram + SilverBullet.
- **`templates/`** — fresh copies of `identity.md`, `user-profile.md`, `soul-loop.md`, `secretary-agent.md` to seed your vault.
- **`templates/vault-pages/`** — SilverBullet index pages (`index.md`, `dashboard.md`, `handoffs.md`, `journals.md`, `processes.md`, `inbox.md`, `decisions.md`) copied to the vault root during Step 2. Without these the vault renders empty on first SB load.
- **`templates/processes/`** — canonical lifecycle docs (`soul-loop.md`, `journaling.md`, `handoffs.md`) copied to `<VAULT>/processes/`. The agents read these at runtime; edit the vault doc, not the agent prompt.

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
