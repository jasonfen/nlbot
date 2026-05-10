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

## Phase 0 — Collect placeholder values upfront

Before running any setup step, sit with Nate for ~5 minutes and gather the values you'll need throughout the install. The kit's templates have `[bracket]` and `<angle>` placeholders that get substituted in many places — collecting them once at the start beats interrupting Nate twelve times mid-setup.

**How to do this:** ask each question conversationally. When Nate gives an answer, store it in `setup-state.md` under a `## Values` block (see updated skeleton below). As you walk through `first-time-setup.md`, apply each value via the `Edit` tool to every file that references the corresponding placeholder. Don't ask Nate to grep and edit by hand — that's what you're for.

### Values to collect at Phase 0 (no external dependencies)

| Variable | Placeholder pattern | Where it's used | Question to ask |
|---|---|---|---|
| `BOT_NAME` | `[Your Bot's Name]` | `CLAUDE-nate.md` heading; reference throughout | "What name do you want this bot to go by? (Lowercase preferred — it'll also be the system username and the directory name.)" |
| `USER_NAME` | `[Nate]`, `[Nate's]` | `CLAUDE-nate.md` body | "What should the bot call you?" |
| `VAULT` | `<VAULT>` | `dot-claude/agents/*.md`, `dot-claude/commands/*.md`, `web-terminal/claude-web.service` | "Where do you want the vault directory? Default: `/home/$BOT_NAME/$BOT_NAME`" — derive automatically. |
| `OS_USER` | `<USER>` (in `claude-web.service`) | systemd unit `User=` | Same as `BOT_NAME` from Step 2 of bootstrap.md. |
| `CANARY_PHRASE` | `[CHOOSE YOUR CANARY PHRASE]`, `[YOUR CANARY PHRASE]` | `templates/identity.md`, `templates/soul-loop.md` | "Pick a memorable phrase the bot will use as an orientation anchor — anything 3–7 words. Examples: 'the lighthouse keeper waves at midnight', 'flat earth society for ants', 'green socks blue keyboard'." |
| `IDLE_PREFS` | `[reading/coding/writing/exploring]` | `templates/identity.md` | "What does the bot prefer to do during idle time? Pick one or write your own." |
| `CREATIVE_OUTPUT` | `[poems/stories/technical docs/music reviews]` | `templates/identity.md` | "What does the bot write when it has something to say?" |
| `COMM_STYLE` | `[direct/gentle/playful/formal]` | `templates/identity.md` | "How should the bot talk to you?" |
| `VALUES_CARES_ABOUT` | `[quality/speed/creativity/accuracy]` | `templates/identity.md` | "What should the bot prioritize?" |
| `USER_ROLE` | (free-form) | `templates/user-profile.md` "Who I am" section | "What do you do? What are you working on?" |
| `USER_HOBBIES` | (free-form) | `templates/user-profile.md` "Hobbies" | "What do you do for fun?" |
| `USER_HOURS` | (free-form) | `templates/user-profile.md` "When I work" | "Roughly when are you usually online? Helps the bot pick its idle moments." |
| `USER_PREFS` | (free-form) | `CLAUDE-nate.md` line "[Nate: Fill this in...]"; `templates/user-profile.md` "Anything else" | "Any non-negotiable preferences? Things you definitely don't want, or strong yes-do-this-always rules?" |

### Values to collect just-in-time (require external action first)

These you can't know up front; capture them when their setup step runs and store them in the same `Values` block.

| Variable | Captured at | How |
|---|---|---|
| `TG_BOT_TOKEN` | Step 6 — Telegram | After Nate runs `/newbot` with `@BotFather`, paste the token. |
| `TG_BOT_USERNAME` | Step 6 — Telegram | The `@<botname>_bot` handle BotFather assigns. |
| `TG_CHAT_ID` | Step 6 — Telegram | After Nate DMs the bot once, fetch from `https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates`, grep `chat.id`. |
| `SB_USER_PASSWORD` | Step 5 — SilverBullet | `openssl rand -base64 24` — generate, store, confirm with Nate. |
| `SB_AUTH_TOKEN` | Step 5 — SilverBullet | `openssl rand -base64 24` — generate, store. |
| `TAILSCALE_HOSTNAME` | Step 5 — SilverBullet (first Tailscale serve) | `tailscale status --json \| jq -r .Self.HostName` — auto-detect, confirm. |
| `WEB_SESSION_SECRET` | Step 7 — Web shell (optional) | `openssl rand -hex 32` — generate, store. |
| `WEB_UI_USERNAME` | Step 7 — Web shell | "What username for the web shell login?" Default: `BOT_NAME`. |
| `WEB_UI_PASSWORD` | Step 7 — Web shell | `openssl rand -base64 24` — generate, show to Nate, store in `Values`, confirm he wrote it down. |

### How to apply collected values

For each file copied into the vault, use the `Edit` tool with `replace_all: true` to substitute every placeholder. Run substitutions in this order:

| Find (old_string) | Replace with | Files affected |
|---|---|---|
| `[Your Bot's Name]` | `$BOT_NAME` | `CLAUDE.md` |
| `[Nate's]` | `$USER_NAME's` | `CLAUDE.md` |
| `[Nate]` | `$USER_NAME` | `CLAUDE.md` |
| `[Nate: Fill this in. ...]` (whole bracketed block) | the answer Nate gave to USER_PREFS | `CLAUDE.md` |
| `[CHOOSE YOUR CANARY PHRASE]` | `$CANARY_PHRASE` | `identity.md` |
| `[YOUR CANARY PHRASE]` | `$CANARY_PHRASE` | `soul-loop.md` |
| `[reading/coding/writing/exploring]` | `$IDLE_PREFS` | `identity.md` |
| `[poems/stories/technical docs/music reviews]` | `$CREATIVE_OUTPUT` | `identity.md` |
| `[direct/gentle/playful/formal]` | `$COMM_STYLE` | `identity.md` |
| `[quality/speed/creativity/accuracy]` | `$VALUES_CARES_ABOUT` | `identity.md` |
| `<BOT_NAME>` | `$BOT_NAME` | `runtime/start-claude.sh` (after copying), systemd unit examples in `persistence-and-hardware.md` if cribbing from there, `web-shell.md` if doing the web shell |
| `<USER>` | `$BOT_NAME` | `web-terminal/claude-web.service` |
| `<VAULT>` | full vault path (e.g. `/home/nlbot/nlbot`) | `dot-claude/agents/*.md`, `dot-claude/commands/*.md`, `runtime/start-claude.sh`, `web-terminal/claude-web.service`, the docker-compose.yml you write for SilverBullet, the cron entries from Step 8 of `first-time-setup.md` |
| `~/natebot` (literal in narrative examples) | `~/$BOT_NAME` or `$VAULT` | `first-time-setup.md`, `silverbullet-setup.md`, `telegram-integration.md`, `web-shell.md` — but **only** in commands you're about to run; you don't need to rewrite the source docs in place |

After each substitution batch, confirm with `grep`:

```bash
# Should return no [bracket] or stray <USER>/<VAULT>/<BOT_NAME> in the vault
grep -rE '\[Your Bot|\[Nate\]|\[CHOOSE YOUR|<USER>|<VAULT>|<BOT_NAME>' $VAULT/ \
  --include='*.md' --include='*.service' --include='*.sh' \
  | grep -v '\[ \]'   # ignore unchecked checkboxes
```

(Some `<bracket>` patterns are legitimate code — e.g. `https://api.telegram.org/bot<TOKEN>/...` is a URL placeholder Nate fills with his real token at Step 6, not a kit placeholder. Use judgment.)

After each file, add a one-line note in `setup-state.md` `## Notes`: "Filled placeholders in `CLAUDE.md`, `identity.md`, `soul-loop.md`."

## How to behave

- **Don't make Nate fill in placeholders manually.** Do Phase 0 first (see above), store collected values in `setup-state.md`, then apply them with the `Edit` tool as you walk through each step. Nate should never have to grep for `[Your Bot's Name]` and edit a file in vim.
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
- **Two `.claude/` directories, easy to confuse.** `~/.claude/` is Claude Code's global per-user config (where `keybindings.json` from Step 3 goes). `<VAULT>/.claude/` is the project-scoped config — the **renamed** `dot-claude/` from this kit. If Step 2 copied the kit's directory as `dot-claude/` (literal, not renamed), the kit's agents and slash commands will silently fail to load — `/soul-loop` will return "unknown command." Verify the rename happened: `ls -d <VAULT>/.claude` should show the directory. The full callout box is in `first-time-setup.md` Step 3; refer Nate there if he asks.
- **Run the interactive `claude` TOS login as the bot user, not the cloud-default user.** The OAuth token lands in `$HOME/.claude/` of whoever ran the command. If you did `claude` as `admin` and then `sudo su - nlbot`, nlbot's first run will gate on OAuth again. The bootstrap.md Step 7 should run after the user-switch in Step 2d.

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
Current phase: phase-0

## Values

### Collected at Phase 0 (upfront)
- BOT_NAME:
- USER_NAME:
- VAULT:                     # default /home/$BOT_NAME/$BOT_NAME
- OS_USER:                   # same as $BOT_NAME
- CANARY_PHRASE:
- IDLE_PREFS:
- CREATIVE_OUTPUT:
- COMM_STYLE:
- VALUES_CARES_ABOUT:
- USER_ROLE:
- USER_HOBBIES:
- USER_HOURS:
- USER_PREFS:

### Collected just-in-time
- TG_BOT_TOKEN:              # step 6 (Telegram)
- TG_BOT_USERNAME:           # step 6
- TG_CHAT_ID:                # step 6
- SB_USER_PASSWORD:          # step 5 (SilverBullet) — generate openssl rand -base64 24
- SB_AUTH_TOKEN:             # step 5 — generate openssl rand -base64 24
- TAILSCALE_HOSTNAME:        # step 5 — derive from `tailscale status`
- WEB_SESSION_SECRET:        # step 7 (Web shell, optional) — openssl rand -hex 32
- WEB_UI_USERNAME:           # step 7 (default $BOT_NAME)
- WEB_UI_PASSWORD:           # step 7 — openssl rand -base64 24

## Done
(none yet)

## In-progress
- Phase 0 — collect placeholder values (see "Values" above)

## Pending
- prereqs check (Claude Code, Docker, Node 20+ if doing web shell, Tailscale)
- vault directory + apply BOT_NAME/USER_NAME/CANARY_PHRASE/etc to all template files
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
