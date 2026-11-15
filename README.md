# nlbot: persistent Claude Code bot kit

A setup kit for a persistent Claude Code bot: a vault of Markdown files, SilverBullet 2.x on top of it, Tailscale as the only way in, and system crons that wake the session without typing into it. Drafted 2026-11-14 from the running system.

No shared chat channel and nothing multi-bot. Telegram is optional. ClaudeBerry is a stub.

## Read in order

1. [README](kit/README.md): what it is, the moving parts, what it costs idle
2. [First-time setup](kit/first-time-setup.md): zero to running
3. [Tailscale](kit/tailscale.md): join, `tailscale serve`, tags, gotchas
4. [SilverBullet](kit/silverbullet.md): install, Runtime API, mentions, due dates, handoffs
5. [The wake path](kit/wake-path.md): crons, gates, poller, runner agents, `/start`
6. [Memory](kit/memory.md): vault, memorious, auto-memory
7. [Operating](kit/operating.md): restarts, upgrades, snapshots, troubleshooting
8. [Telegram](kit/telegram.md) (optional)
9. [ClaudeBerry](kit/claudeberry.md) (stub)

## Templates

`kit/templates/` holds copies of the live files with names, hosts and paths replaced by `${PLACEHOLDER}`s. `kit.env.example` lists the placeholders and `render.sh` fills them in.

| Folder | Becomes |
|---|---|
| `CLAUDE.md.template`, `collaboration.md`, `identity.md`, `user-profile.md` | vault root (`CLAUDE.md.template` becomes `CLAUDE.md`) |
| `bin/`, `hooks/`, `processes/`, `cron-prompts/` | same paths in the vault |
| `dot-claude/` | `.claude/` (agents, commands, `settings.local.json`) |
| `silverbullet/` | `CONFIG.md`, `dashboard.md` and `templates/` in the vault (shipped as `*.md.template` so this vault's SilverBullet does not run them); the compose file goes outside it |
| `systemd/` | `/etc/systemd/system/` |
| `web-terminal/` | `web-terminal/` in the vault |
| `telegram/` | `.telegram/` and one command file, if used |
| `crontab.example`, `gitignore.example`, `keybindings.json`, `tmux.conf` | the user crontab, `.gitignore`, `~/.claude/keybindings.json`, `~/.tmux.conf` |

## Status

- **2026-11-14:** first draft, written by a Fable subagent from the live system and reviewed against it. The privacy grep is clean.
- **2026-11-14:** verification pass:
  - humanizer installed via `npx skills add`
  - memorious registered via `claude mcp add-json`
  - `claude --continue` checked in an empty directory
  - node-pty build requirements written up
  - SilverBullet first-run walked on a throwaway 2.12.0 instance. This added the bot's space-access step and the `.gitignore`-first warning.
  - Tailscale Services and the access policy filled in from a read-only API readout
  - off-box backup section added
- **2026-11-15:** secrets moved out of the vault. SilverBullet serves any vault file to any logged-in account, dotfiles included, and `spaceIgnore` doesn't block a direct read. A new `${SECRETS_DIR}` placeholder (outside `VAULT_DIR`) holds the SilverBullet token, the web terminal's env file and the Telegram config. `sb.sh`, `server.js`, `tg-bot.py` and `tg-post.sh` read from it, and `render.sh` checks it.
- **Open:** `telegram.md` still has one `TODO(verify)`: the trigger-file rewire has never been run. Deferred by Jason.
- The previous kit (May 2026) is tagged `v1`.
