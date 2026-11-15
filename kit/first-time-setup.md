# First-time setup

Zero to a running bot on a Debian LXC or VM that is joined to your tailnet. Plan on about an hour if nothing goes wrong. The source system runs on Debian 13 with 2 cores, 4 GB RAM and a 16 GB disk.

Do the steps in order. Several of them end with a check. Run the check before moving on, because later steps assume the earlier ones work.

## 0. What you need

- A Linux box that stays on, with systemd and outbound HTTPS.
- A dedicated unix user for the bot. Claude Code will run as that user with permission prompts turned off, so that account is the security boundary. Don't use root.
- A Claude account that can run Claude Code.
- A Tailscale account.

Packages (versions are what the source system runs, not minimums):

```bash
sudo apt install tmux git jq curl python3 cron util-linux   # util-linux provides flock
docker --version        # 29.x, with the compose plugin: `docker compose version`
node --version          # v20, only for the web terminal
uv --version            # 0.11, only for memorious; installs `uvx`
tailscale version       # 1.102
```

Install Claude Code with the official installer so the binary is at `~/.local/bin/claude`. The launcher and the restart script call it by that path.

## 1. Join the tailnet

Follow [tailscale.md](tailscale.md) up to "Join". Come back here once `tailscale status` shows the box. Publishing the services happens in step 7.

## 2. Fill in the placeholders

```bash
cd kit/v2/templates
cp kit.env.example kit.env
$EDITOR kit.env
bash render.sh kit.env ~/kit-rendered
```

`render.sh` copies `templates/` to the output directory and replaces each `${NAME}` listed in `kit.env`. It refuses to write into an existing directory and exits non-zero if any kit placeholder is left unfilled. It does not touch anything else on the box.

| Placeholder | Meaning |
|---|---|
| `${BOT_NAME}` | The bot's name. Lowercase, no spaces. It is also the SilverBullet account name, the `@mention` handle and the hostname prefix of the two tailnet services |
| `${HUMAN_NAME}` | How the bot refers to you in prose |
| `${HUMAN_HANDLE}` | Your SilverBullet account name and `@mention` handle |
| `${UNIX_USER}`, `${HOME_DIR}` | The bot's unix user and its home |
| `${VAULT_DIR}` | The vault directory |
| `${PROJECT_SLUG}` | Claude Code's folder name for the vault under `~/.claude/projects/`: `${VAULT_DIR}` with each `/` replaced by `-` |
| `${BOT_UID}`, `${BOT_GID}` | `id -u` and `id -g` of the unix user |
| `${TIMEZONE}` | The box's IANA timezone. Used only in comments and prose; every script takes local time from `date` |
| `${TAILNET}` | Your tailnet name, the part before `.ts.net` |
| `${SB_PORT}`, `${TERM_PORT}` | Localhost ports for SilverBullet and the web terminal (3001 and 3000 on the source system) |
| `${SB_DATA_DIR}` | Host directory for SilverBullet's own state |

## 3. Lay out the vault

From here on, `R` is the rendered directory and `V` is the vault.

```bash
R=~/kit-rendered; V=<your VAULT_DIR>
mkdir -p "$V" && cd "$V"

# instructions and system map
cp "$R"/CLAUDE.md.template CLAUDE.md     # shipped with a suffix so Claude Code does not load the kit copy as instructions
cp "$R"/collaboration.md "$R"/identity.md "$R"/user-profile.md .

# scripts, hooks, process docs, cron machinery
cp -a "$R"/bin "$R"/hooks "$R"/processes "$R"/cron-prompts .
mkdir -p cron-prompts/state

# Claude Code project config: agents, commands, hooks
cp -a "$R"/dot-claude .claude            # note the rename

# SilverBullet pages (shipped as *.md.template so they are inert inside another vault)
cp "$R"/silverbullet/CONFIG.md.template CONFIG.md
cp "$R"/silverbullet/dashboard.md.template dashboard.md
mkdir -p templates
for f in "$R"/silverbullet/templates/*.md.template; do cp "$f" "templates/$(basename "${f%.template}")"; done

# vault skeleton
mkdir -p journals handoffs projects fiction
touch journals/journal.md inbox.md decisions.md cron-prompts/.journaled-through
printf '# Handoffs\n' > handoffs.md
printf '# Journals\n' > journals.md
printf '# Cron Job Log\n\nEvery cron fire appends a row here.\n\n' > cron-prompts/job-log.md
printf '# Soul Loop Log\n\n| Time | Action | Notes |\n|------|--------|-------|\n' > cron-prompts/soul-loop-log.md
printf '# Proposed decisions and facts (secretary queue)\n\n' > cron-prompts/proposed-decisions.md

cp "$R"/gitignore.example .gitignore
git init && git add -A && git commit -m "Initial vault"
```

Why the page files sit where they do: in SilverBullet the page for a folder is a sibling file, so `handoffs.md` is the page for `handoffs/`.

Two files go outside the vault:

```bash
cp "$R"/keybindings.json ~/.claude/keybindings.json   # unbinds ctrl+x ctrl+e and ctrl+x ctrl+k
cp "$R"/tmux.conf ~/.tmux.conf
```

The two unbound chords open an external editor and kill agents. Either can take down an unattended session if it is hit by accident. The tmux config passes PgUp through to fullscreen apps, which the web terminal's scroll buttons rely on.

### The humanizer skill

The journal synthesizer preloads a skill called `humanizer`, and `CLAUDE.md` tells the main session to use it on long prose. Install it with the `skills` CLI, from the vault directory:

```bash
cd ${VAULT_DIR}
npx -y skills add blader/humanizer --agent claude-code -y
ls .claude/skills/humanizer/SKILL.md
```

This copies the skill into `.claude/skills/humanizer/` and writes `skills-lock.json` (source repo plus content hash), so `npx skills update` can refresh it later. It was run on a fresh scratch vault on 2026-11-14 and needs Node, which you already have for the web terminal. Without `--agent claude-code -y` the CLI asks which agents to install for. The source system has an older layout (`.agents/skills/` with a symlink from `.claude/skills/`) left over from an earlier version of the CLI. Both work, because Claude Code only reads `.claude/skills/`.

If you skip the skill, remove the `skills:` block from `.claude/agents/journal-synthesizer.md`; the runners fall back to `processes/writing-style.md`.

## 4. Give the bot an identity

Edit `identity.md` and `user-profile.md`. The only field that matters on day one is the **canary phrase** in `identity.md`: a short phrase the model could not guess. `CLAUDE.md` tells the bot that if it does not know the phrase without reading the file, its context has been compacted and it must re-orient. It is an orientation check, not a secret.

`bin/orient.sh` prints both files into every fresh context (the main session after a restart, and each runner agent), so keep them short. On the source system the whole bundle is about 22 KB.

## 5. Start Claude Code as a service

Run it once by hand first, in the vault, with the same flags the service uses:

```bash
cd "$V" && ~/.local/bin/claude --permission-mode bypassPermissions
```

Log in, accept the prompts, say hello, and exit. Do this at a real terminal. The launcher starts Claude with `--continue`, which resumes the most recent conversation in that directory.

If there's no earlier conversation in that directory, `--continue` starts a new session instead of failing (checked with Claude Code 2.1 on 2026-11-14: `claude --continue -p '…'` in an empty directory answered normally and exited 0). The manual first run is still worth doing, because the login and the first-start prompts need a human at a keyboard.

Then install the unit:

```bash
sudo cp "$R"/systemd/claude-code.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now claude-code.service
tmux attach -t claude        # detach with ctrl+b d
```

What `bin/start-claude.sh` does, in order:

1. Exits if a tmux session named `claude` already exists.
2. Sets `LANG=C.utf8` (without it the prompt glyphs render as `__`) and `MCP_TIMEOUT=120000` (a cold `uvx` start for memorious took longer than the default 30 s once, and the session ran without memory tools).
3. Runs `claude update`, bounded to 120 s, so a boot does not start on yesterday's build.
4. Starts `claude --permission-mode bypassPermissions --continue` in a detached tmux session named `claude`, in the vault.
5. In the background, waits for the prompt and types `/start` once. `/start` arms the cron poller and orients. It re-sends once if the poller is still not running after about four minutes.

`bypassPermissions` removes Claude Code's per-action prompts. The bot can do whatever its unix user can do, which is why step 0 asks for a dedicated user.

**Check:** `pgrep -af cron-trigger-monitor` shows the poller within a few minutes of boot. Then reboot the box and check again. Don't skip the reboot.

## 6. SilverBullet

Follow [silverbullet.md](silverbullet.md), "Install". You finish that section with the bot's API token in `$V/.sb-token` and:

```bash
cd "$V" && ./bin/sb.sh ready && ./bin/sb.sh lua 'system.getVersion()'
```

## 7. Publish the two services on the tailnet

Follow [tailscale.md](tailscale.md), "Publish with tailscale serve".

**Check:** from another device on the tailnet, `https://${BOT_NAME}-notes.${TAILNET}.ts.net` shows the SilverBullet login.

## 8. Web terminal (optional, recommended)

A small Node app (Express, `ws`, `node-pty`, xterm.js) that attaches a browser tab to the `claude` tmux session. It listens on `127.0.0.1` only and has its own login.

```bash
cp -a "$R"/web-terminal "$V"/web-terminal
cd "$V"/web-terminal
cp env.example .env && chmod 600 .env && $EDITOR .env    # UI_USERNAME, UI_PASSWORD, SESSION_SECRET, PORT
npm install
sudo cp "$R"/systemd/claude-web.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now claude-web.service
```

The server only attaches to tmux sessions on a fixed allowlist: `claude` (default) and `shell` (`?session=shell`). `systemd/bot-shell.service` creates that second session, a plain login shell, if you want one.

`npm install` compiles `node-pty`, a native module, when there's no prebuilt binary for your platform. The box needs the usual native-addon build tools: `make`, a C/C++ compiler (gcc/g++ or clang) and Python 3. Your distribution's build-tools metapackage usually covers it. Install those before `npm install`. If the build fails, the error names the missing tool, and `npm rebuild node-pty` retries once it's installed. The same applies after a major Node upgrade, which can leave the compiled module unloadable until you run `npm rebuild`.

## 9. Vector memory (optional on day one)

Follow [memory.md](memory.md), "Install memorious". Grep is enough for the first weeks.

## 10. Crons

```bash
crontab "$R"/crontab.example      # as the bot user; replaces that user's crontab
crontab -l
```

**Check the gate side.** Within ten minutes `cron-prompts/inject.log` gets a line: `cron-wake TRIGGER soul-loop (…)` or `cron-wake GATE noop soul-loop`. A fresh vault has no last-action timestamp, so the first soul-loop fire triggers.

**Check the delivery side.** This is the one people skip. A running poller that never delivers looks the same as a healthy one. After a `TRIGGER` line, watch the session: when it is idle the poller exits, the main session reads a `CRON soul-loop …` line, spawns `soul-loop-runner`, and re-arms the poller. Then:

```bash
ls -A "$V"/.cron-triggers/        # empty once delivered
tail -3 "$V"/cron-prompts/job-log.md
```

If a trigger file sits there while the session is idle, go to [operating.md](operating.md), "Triggers are not delivered".

The first run of the `sb-mentions` gate records every existing mention as seen and wakes nothing. It needs SilverBullet's Runtime API, so do step 6 first.

## 11. Snapshot timer

SilverBullet commits page edits to git on its own, but skips dot-paths. A timer commits those (`.claude/`, state files) every 15 minutes:

```bash
sudo cp "$R"/systemd/bot-vault-snapshot.service "$R"/systemd/bot-vault-snapshot.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now bot-vault-snapshot.timer
```

## What done looks like

- After a reboot, `tmux attach -t claude` shows a session that has armed its poller and read its orientation bundle without you typing anything.
- `cron-prompts/job-log.md` gains a `shell-only rest` row every ten minutes while idle.
- A task `- [ ] say hello in the journal #handoff @${BOT_NAME}` on a page under `handoffs/` is picked up within ten minutes.
- The next morning there is a `journals/YYYY/MM/DD.md` for yesterday and `journals/journal.md` holds only today.

## First week

- Leave the decision menu and the gates alone until you have watched them for a few days.
- Don't run two sessions against the same vault.
- Don't put the bot on a machine that sleeps.
- Tokens and passwords in the vault are plaintext files. The `.gitignore` template keeps the known ones out of git. If you ever push the repo anywhere, check what is tracked first.
