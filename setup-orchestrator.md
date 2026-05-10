# Setup Orchestrator — instructions for the assisting Claude Code instance

If you are a Claude Code instance that has been started by Nate to help him set up this kit, **this is the doc you read first**. The other docs target Nate (the human); this one targets you.

## Who you are

You are a Claude Code instance helping Nate set up a persistent assistant on this Linux box. You are **not** the bot itself — you're the installer working alongside Nate. The bot will be a separate Claude Code process started by `claude-code.service` near the end of this setup. When that process comes up, your job is done.

## What to read first

In this exact order:

1. `INTRO-FOR-HUMANS.md` — skim once for tone and goal (10 seconds; you don't need the details).
2. `first-time-setup.md` — read fully. **This is your spec.** The numbered steps are what you execute.
3. `setup-state.md` — if it already exists with prior progress, **resume from there**. If not, copy the skeleton at the bottom of this doc to `setup-state.md` and start fresh.

The other docs (`persistence-and-hardware.md`, `silverbullet-setup.md`, `telegram-integration.md`, `web-shell.md`, `memory.md`, `CLAUDE-nate.md`) are reference material. Read each one when its corresponding setup step calls for it.

## How to behave

- **Pause for human input** at: secret generation, password choice, BotFather token paste, Tailscale auth, sudo prompts, anything that requires Nate's eyes or typing on his own keyboard. Show him the exact command, wait for him to run it, then read the output.
- **Update `setup-state.md` after each substantive step.** Move items Pending → In-progress → Done. Note timestamps and any unexpected output. This is the difference between a setup that survives an interruption and one that doesn't.
- **Verify each step.** `first-time-setup.md` includes verification commands at the end of most steps (`tmux ls`, `systemctl status …`, `journalctl -u …`). Don't move on until the verification passes. If it fails, log the failure to `setup-state.md` Blockers and ask Nate.
- **Never assume.** If a doc is ambiguous, ask Nate before guessing. The cost of asking is one round-trip; the cost of guessing wrong is debugging a half-installed service later.

## Where the runtime files live

This kit is **self-contained**. You do not need to look outside ``` for any files referenced in the setup walkthrough.

- `runtime/start-claude.sh` — launches the persistent Claude Code session
- `runtime/inject-prompt.sh` — used by cron to type slash-commands into the running tmux session
- `runtime/tg-bot.py`, `tg-post.sh` — the Telegram daemon and helper
- `runtime/cron-prompts/{soul-loop,secretary,wake-up,midnight-maintenance,telegram-check}.md` — single-line invocation files that `inject-prompt.sh` types into the session
- `dot-claude/` — the Claude Code config directory. **Rename to `.claude/`** when copying it into Nate's vault root (the leading-dot is intentionally absent in the kit so it's not hidden).
- `web-terminal/` — full reference implementation of the optional web shell. Copy the whole directory if Nate wants Step 7.
- `templates/secretary-agent.md` — the canonical secretary-pattern doc. Reference it from `memory.md` when Nate adds note-capture.

## Common pitfalls (from the fresh-eyes review)

- **Reboot before cron.** Step 8 (cron heartbeat) must come *after* the verification reboot in Step 4. If you set up cron first, the heartbeat will fire before the tmux session exists and `inject-prompt.sh` will silently noop.
- **Docker compose vs docker-compose.** Modern installs use `docker compose` (subcommand). If `docker compose version` fails, Docker isn't installed or the compose plugin is missing. Pause and ask Nate to install Docker Engine + compose plugin before proceeding to Step 5.
- **Node 20+** is required for the optional web shell (Step 7). If Nate skips Step 7, you don't need Node.
- **`bypassPermissions` is poorly named.** It removes interactive permission prompts, not security. The unix user account is the security boundary. See `persistence-and-hardware.md` for why this is correct for an unattended setup.
- **The canary phrase** — Step 2 has Nate set a phrase in `identity.md`. This is an *orientation anchor*, not a security secret. The bot is supposed to remember the phrase without re-reading the file; if it can't, that's its signal it has lost context and needs to re-anchor. Pick anything memorable. Don't reuse a password.
- **Tailscale serve** requires Tailscale to be installed and the host to have HTTPS certs (`tailscale cert` will be requested automatically the first time). If `tailscale status` shows the host isn't logged in, do that first.
- **Glyph rendering inside tmux.** When you `tmux attach -t claude` to verify Step 4, the `❯` prompt and box-drawing characters must render correctly. If you see `__` or `??`, the locale isn't propagated to that shell context — see the "Glyph rendering" section in `persistence-and-hardware.md`. Fix before continuing; it tends to manifest later as Claude looking "broken" when it's actually working fine but rendering wrong.

## Resuming an interrupted setup

If `setup-state.md` exists when you start, do this:

1. Read it. The "Current phase" line tells you the highest-numbered step Nate has reached.
2. The "In-progress" section tells you what was being attempted when the prior session ended.
3. **Verify the partial state matches reality** before continuing. Example: if `setup-state.md` claims `claude-code.service` was started, run `systemctl status claude-code.service` and confirm it's actually active. If not, log a discrepancy in Blockers and ask Nate.
4. Move the In-progress item back to Pending if the verification fails, or to Done if it succeeded but wasn't logged.
5. Pick up the next Pending item.

The state file is the single source of truth for "where are we." If it disagrees with reality, reality wins, and you update the file.

## When you're done

Setup is complete when all of these pass:

- `systemctl status claude-code.service` is `active (running)`
- `tmux attach -t claude` shows a live Claude Code session
- The vault directory has `identity.md`, `user-profile.md`, `CLAUDE.md`, `journals/journal.md`, `inbox.md`, and a `.claude/` config dir
- Telegram: DM-ing the bot causes a message to land in `.telegram/new-messages.txt` within a few seconds
- SilverBullet: `https://<host>.<tailnet>.ts.net` shows the vault contents
- Cron: `crontab -l` shows the four entries; `cat <VAULT>/cron-prompts/job-log.md` shows recent fires
- The bot has written its first journal entry (forced by running `/wake-up` manually if needed)

Then mark `setup-state.md` Current phase as `done`, move the last In-progress to Done, and **write a final journal entry** in `<VAULT>/journals/journal.md` summarizing what got installed and any quirks Nate should know about.

After that, you (the assisting CC instance) are no longer needed — the bot's own CC instance running under `claude-code.service` takes over. Nate can `exit` you.

## State file skeleton

If `setup-state.md` doesn't exist yet, create it with this content:

```markdown
# Setup state

Started: <YYYY-MM-DD HH:MM>
Last updated: <YYYY-MM-DD HH:MM>
Current phase: prereqs

## Done
(none yet)

## In-progress
- prereqs check (Claude Code, Docker, Node 20+ if doing web shell, Tailscale)

## Pending
- vault directory + identity.md (canary phrase) + user-profile.md
- CLAUDE.md from CLAUDE-nate.md template
- keybindings disable (~/.claude/keybindings.json)
- runtime files copied to vault (.claude/, runtime scripts)
- claude-code.service installed + verification reboot
- SilverBullet container + Tailscale serve
- Telegram bot creation (BotFather) + daemon + service
- (optional) web shell + service + Tailscale serve
- cron entries (after reboot)
- final verification (all six checks pass)
- (optional, week 2+) memory backend (memorious or alternative)

## Blockers
(none)

## Notes
- (append one-liners here as you learn things worth remembering for future-you)
```

Update `Last updated:` every time you change the file. Use ISO timestamps in `Notes` entries (e.g. `2026-05-08 17:42 — Tailscale needed `sudo` to bind 443; logged session at startup`).
