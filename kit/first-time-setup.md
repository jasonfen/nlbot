# First-time setup walkthrough

A 30-minute path from "I want one of these" to "the box is running and ready to hand over." Read [INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md) first if you haven't — it explains *why* this is a thing. This doc is the *how*.

**Audience:** the *provisioner* — the technical person standing the box up. The end user (call them Nate) doesn't see this doc; they receive a URL and a one-line instruction ("open it, log in, type `/setup`") and the bot walks them through the rest of identity setup conversationally inside the web shell.

*If a Claude Code instance is helping you with the install, it should read [setup-orchestrator.md](setup-orchestrator.md) first. That doc covers the assisting-CC flow as a fallback to the env-var-driven path described here.*

## TL;DR — run the script with env vars, then hand over

`runtime/first-time-setup.sh` automates Steps 1–4 end-to-end: vault skeleton, identity seed, placeholder substitution, keybindings, `start-claude.sh`, the systemd unit, the parallel `<BOT_NAME>-shell.service`, and bringing up both tmux sessions. It stops at the kit's explicit "hand over the keys" gate — the NOPASSWD sudoers grant and verification reboot stay with the provisioner. After reboot, *Nate's only step* is to open the web shell URL and type `/setup`.

**Provisioner order of operations** (all run as the bot's unix user, e.g. `nlbot`):

```bash
cd ~/nlbot                                                  # <REPO_ROOT>
claude                                                      # 1. OAuth walk — REQUIRED before the script runs
                                                            #    (accept TOS, exit). The script aborts at a
                                                            #    pre-flight gate if ~/.claude/.credentials.json
                                                            #    is missing.
BOT_NAME=nlbot BOT_PASSWORD=Welcome2026 \
  bash kit/runtime/first-time-setup.sh --non-interactive    # 2. Env-var provisioner — Steps 1–4.
sudo visudo -f /etc/sudoers.d/$BOT_NAME                     # 3. NOPASSWD sudoers grant (template printed by
                                                            #    the script's end-of-run banner).
sudo reboot                                                 # 4. Verification reboot.
```

That four-line sequence is the canonical happy path. Step 1 (OAuth) is non-skippable: Claude Code's CLI stores credentials at `$HOME/.claude/.credentials.json`, and the kit's pre-flight checks for that file before doing anything destructive — partly to fail loud rather than fail silent on a misconfigured box, partly because step 2 renders the systemd unit that immediately tries to launch `claude`, which will crashloop if creds are missing. The OAuth walk has to happen at a real interactive TTY (it opens a browser flow), so the provisioner does it once at the console before the env-var-driven phase.

The script no longer prompts for `USER_NAME`, `CANARY_PHRASE`, hobbies, communication style, or any of the eight personality values — those get collected by the bot during Nate's `/setup` interview after he logs in. The bash phase only collects what's truly load-bearing for getting the box up to the point where Nate can connect:

- **`BOT_NAME`** — required; unix user, systemd `User=`, secrets dir at `/etc/<BOT_NAME>/secrets/`, vault dirname.
- **`VAULT`** — defaults to `$REPO_ROOT/vault`; rarely overridden.
- **`BOT_PASSWORD`** — required at Phase 0.5 (or supply via env). Stored as a systemd-creds blob at `/etc/<BOT_NAME>/secrets/{sb-user-password,web-ui-password}` (one shared blob if `PASSWORD_MODE=unified`, the default; two separate blobs if `separate`). Plaintext never lands on disk.

Everything else gets a default in `setup-state.md`'s Values block (`USER_NAME=`, `CANARY_PHRASE=`, the eight personality values, `TELEGRAM_ENABLED=` all blank). The seeded vault files keep their bracket placeholders (`[Nate]`, `[CHOOSE YOUR CANARY PHRASE]`) visible — they read as legible template prose pre-interview, and `/setup` re-substitutes them with Nate's real answers when he runs it.

### `--non-interactive` mode

With the flag set, the script fails fast (with a clear error) if any required value is unset. Without it, the script falls back to `read -rp` for `BOT_NAME` and `VAULT` (handy if you're driving the install at a console). `BOT_PASSWORD` always either reads from env or prompts no-echo + confirm at the terminal; non-TTY without `BOT_PASSWORD` is a hard fail — the script refuses to silently auto-generate an unreadable password.

The `--reinstall-services-only` flag is unchanged: it re-renders the two systemd units from their templates and is the way to apply unit-template fixes from `git pull` without re-running the whole bootstrap.

### `HANDOFF-TO-NATE.txt`

End of run, the script writes `<REPO_ROOT>/HANDOFF-TO-NATE.txt` (mode 600) containing the web shell URL, login username, initial password hint, and the single instruction for Nate (`Open <URL>, log in, then type /setup`). The script also prints a banner reminding you to `shred -u HANDOFF-TO-NATE.txt` after Nate has read it. The file exists so you have a clean text artifact to send Nate over whatever channel you trust; the banner exists so you don't forget to wipe it.

### Linux login password opt-in

After Phase 0.5 the script offers an optional `[y/N]` to also set the Linux user's `/etc/shadow` login password via `chpasswd`; default `N` keeps the box SSH-key-only, which is the recommended posture for a tailnet-only LXC.

The rest of this doc is the canonical reference: read along to know exactly what the script is doing, or use the prose blocks to do any step by hand.

## What you'll need before you start

- A Linux machine you can leave running (LXC container, spare laptop, small VPS — see [persistence-and-hardware.md](persistence-and-hardware.md) for the floor: 2 cores / 2 GB RAM / 8 GB disk).
- A Claude Code subscription (the CLI tool, not the API).
- A Telegram account with a phone (to talk to BotFather).
- About 30 minutes of focused time. You can stretch it over a weekend; nothing here is time-pressured.

### Where am I? (sanity check)

At any point — including right now, before you've started — you can run the kit's state probe to see what's installed, what's missing, and which manual step to do next:

```bash
BOT_NAME=<your-bot-name> bash <repo-root>/kit/runtime/setup-status.sh
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

The kit clone lives at `<REPO_ROOT>` (e.g. `~/nlbot`). After the restructure, the clone has a clean three-way split:

- `<REPO_ROOT>/kit/` — kit source (read-only after install; pulled from upstream).
- `<REPO_ROOT>/vault/` — the SilverBullet space (where `journals/`, `handoffs/`, `CLAUDE.md`, identity files live).
- `<REPO_ROOT>/` itself — bot-runtime state (`.claude/`, `.telegram/`, `cron-prompts/`, `setup-state.md`, `start-claude.sh`).

Set three shell variables once and every later code block uses them:

```bash
REPO_ROOT=~/nlbot         # change to wherever you cloned the kit
KIT=$REPO_ROOT/kit
VAULT=$REPO_ROOT/vault
cd $REPO_ROOT
```

Build the vault skeleton and copy the kit's seed files:

```bash
mkdir -p $VAULT/journals/fiction $VAULT/handoffs $VAULT/processes

# Bot identity at the vault root (user-edited daily through SilverBullet)
cp $KIT/CLAUDE-nate.md            $VAULT/CLAUDE.md
cp $KIT/templates/identity.md     $VAULT/identity.md
cp $KIT/templates/user-profile.md $VAULT/user-profile.md
cp $KIT/templates/soul-loop.md    $VAULT/soul-loop.md

# SilverBullet vault — top-level index pages + process docs + handoff template
cp -n $KIT/templates/vault-pages/*.md  $VAULT/
cp -n $KIT/templates/processes/*.md    $VAULT/processes/
cp -rn $KIT/templates/vault-pages/_templates $VAULT/_templates 2>/dev/null || true

touch $VAULT/journals/journal.md

# Render .claude/ from kit/dot-claude/ — substitutes placeholders, lives at
# the REPO_ROOT (bot CWD) so Claude Code finds it.
bash $KIT/runtime/refresh-claude-dir.sh
```

Now open `CLAUDE.md` in your editor and replace every `[Nate]` and `[Your Bot's Name]` placeholder with your actual name and the bot's name. Same with `identity.md` and `user-profile.md` — fill in the canary phrase, your role, what you want from this bot. There's no "right" answer; first-pass guesses are fine, you'll edit later.

The vault-page copies above also contain `<BOT_NAME>` / `<USER_NAME>` / `<VAULT>` / `<KIT>` / `<REPO_ROOT>` placeholders. `runtime/first-time-setup.sh` handles substitution automatically. If you skipped that and are running this entirely by hand, the substitution table lives in `setup-orchestrator.md` — six tokens total. A one-shot `sed` over `$VAULT/*.md $VAULT/processes/*.md` covers the most important seeded files; `$REPO_ROOT/.claude/agents/*.md` and `$REPO_ROOT/.claude/commands/*.md` are regenerated by `bash $KIT/runtime/refresh-claude-dir.sh`.

**About the canary phrase:** in `identity.md`, you'll set a short string ("the lighthouse keeper waves at midnight" — anything memorable). The bot is supposed to remember it without re-reading the file. If at any point it can't recall the phrase, that's its signal it has lost context (post-restart, post-compaction) and needs to re-anchor by reading `identity.md` and `user-profile.md`. It's not a security secret; just an orientation anchor.

## Step 3 — Disable the keybindings that kill sessions (1 min)

Edit `~/.claude/keybindings.json`:

```json
{
  "bindings": [
    { "keys": "ctrl+x ctrl+e", "action": "none" },
    { "keys": "ctrl+x ctrl+k", "action": "none" }
  ]
}
```

The `"action": "none"` form is the current Claude Code schema. (Older docs and older kit versions used a top-level `"disabled": [...]` array — that's now rejected with a `keybindings.json must have a "bindings" array` warning. If you see that error on `claude` startup, your file is in the legacy format; replace it with the block above.)

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

Render the launcher script into the repo root (bot CWD), then drop the systemd unit:

```bash
cp $KIT/runtime/start-claude.sh $REPO_ROOT/start-claude.sh
chmod +x $REPO_ROOT/start-claude.sh
```

The script has a `cd` line near the top that hardcodes the bot's CWD. Open `$REPO_ROOT/start-claude.sh` and update that line if it doesn't already point at `$REPO_ROOT`.

Then drop two sibling systemd units at `/etc/systemd/system/`:

- `claude-code.service` (template in [persistence-and-hardware.md](persistence-and-hardware.md) — change `User=` and the path).
- `<BOT_NAME>-shell.service` (parallel unit running `tmux new-session -d -s shell -c %h /bin/bash -l` as the bot user). The web shell exposes both tmux sessions; `?session=shell` lands here, `tmux attach -t shell` over SSH gets the same thing.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now claude-code.service
sudo systemctl enable --now <BOT_NAME>-shell.service
tmux ls                         # should show "claude" AND "shell" sessions
tmux attach -t claude           # see Claude Code running
# Check that the ❯ prompt renders correctly. If you see __ or ?? instead,
# the locale isn't set right in some shell context. See the "Glyph rendering"
# section in persistence-and-hardware.md — fix it before continuing.
# detach with ctrl+b then d (don't kill it)
```

`first-time-setup.sh` automates both `claude-code.service` and `<BOT_NAME>-shell.service` together — Step 4 of the script writes both heredocs, enables both, and verifies both tmux sessions came up.

### Final action: grant the bot scoped sudo NOPASSWD (then reboot)

This is the privilege grant that lets the bot drive Steps 5–9 from inside the detached tmux session (where there's no terminal for sudo to prompt against). **Do this only after the steps above all worked** — by this point you have a working `claude-code.service`, a verified tmux session, and everything else from bootstrap.md sane. The NOPASSWD entry is the "I'm ready to hand the keys over" gate.

```bash
# Substitute $BOTUSER with your bot's unix username
# (the one from bootstrap.md Step 2)
sudo tee /etc/sudoers.d/$BOTUSER >/dev/null <<EOF
# Service + container + cron management
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/systemctl
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/crontab
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/docker
# Service-file + log inspection (setup-runner step-7 step-9)
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/tee
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/journalctl
# Tailscale serve (setup-runner step-6 + step-7)
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/tailscale
# systemd-creds + secret-blob ops (runtime/bot-secrets.sh,
# migrate-secrets.sh, silverbullet-up.sh — the encrypted-secrets
# path needs all of these to run unattended from the soul-loop)
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/systemd-creds
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/install
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/mktemp
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/rm
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/test
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/ls
EOF
sudo chmod 440 /etc/sudoers.d/$BOTUSER
sudo visudo -cf /etc/sudoers.d/$BOTUSER

# Verify the bot user can actually use it
sudo -u $BOTUSER sudo -ln | grep NOPASSWD
```

Anything outside the list above still prompts for the password and stays your job. The list pairs to specific bot operations: `systemctl/crontab/docker` for service + cron + container management; `tee/journalctl` for writing service files and tailing logs during steps 7 and 9; `tailscale` for the `tailscale serve` publishes in steps 6 and 7; `systemd-creds + install/mktemp/rm/test/ls` for the encrypted-secrets path (bot-secrets.sh, migrate-secrets.sh, silverbullet-up.sh) that needs root to write/read `/etc/$BOTUSER/secrets/`. If something feels off here, **don't reboot yet** — debug first. If you want to undo: `sudo rm /etc/sudoers.d/$BOTUSER`. If you'd rather grant blanket `NOPASSWD: ALL` instead of scoped (bigger blast radius if the bot ever runs amok), substitute `NOPASSWD: ALL` for the comma-list above. The kit's recommended path is scoped.

### Reboot

**Reboot the box now and verify it comes back up.** This is non-negotiable — verify the persistence works before you start trusting it. After the reboot:

```bash
systemctl status claude-code.service     # active (running)
tmux attach -t claude                    # back in the session
```

## After the reboot — hand the URL to Nate

At this point the box is running. `claude-code.service` is up, the tmux `claude` session has the bot at its prompt, and `<BOT_NAME>-shell.service` is hosting the web-shell-accessible bash session. `Current phase: phase-0-interview-pending` — the soul-loop will fire on its 10-minute cadence but `setup-runner` short-circuits with `interview pending — user must type /setup` and does nothing else until Nate connects.

**What you do:** read `HANDOFF-TO-NATE.txt`, copy its contents over whatever channel you trust (email, SMS, in-person), then `shred -u HANDOFF-TO-NATE.txt` once Nate confirms receipt.

**What Nate does:**

1. Opens the web shell URL in his browser.
2. Logs in with the username + initial password from the handoff.
3. Lands in the tmux `claude` pane, sees the bot's prompt.
4. Types `/setup`.

The bot's `/setup` slash command runs a short conversational interview (USER_NAME, CANARY_PHRASE, 8 optional personality values, TELEGRAM opt-in). Each answer persists to `setup-state.md` immediately, so Nate can Ctrl-C / close his browser / lose the network mid-interview and resume from the first still-empty question on his next `/setup`. After the last answer, `/setup` re-substitutes the seeded vault files with Nate's real values, advances the phase to `phase-0-interview-complete`, and falls through to the bot-driven Step 5–9 walk.

### What the bot drives after the interview

`setup-runner` reads `setup-state.md` Current phase on every soul-loop, executes the next phase, advances state, and posts progress to the journal. Nate can watch via the web shell (or, after Step 7 finishes, via Telegram — only if he opted in at the interview's last question).

**Total elapsed from Nate's first `/setup`:** ~5–10 minutes, or longer if he opted in to Telegram (the BotFather BLOCKER pauses there).

### What the bot does

| Phase | What runs |
|---|---|
| `step-5-cron` | **First bot phase, intentionally.** Installs crontab entries (soul-loop / secretary / wake-up / midnight-maintenance) for the bot's unix user so the heartbeat + journaling pipeline starts on minute one. Everything downstream becomes re-drivable from the heartbeat. |
| `step-6-silverbullet` | Generates the machine-only `sb-auth-token` (`bot-secrets.sh generate`), runs `silverbullet-up.sh` which reads `sb-user-password` (typed by operator in Phase 0.5) + `sb-auth-token` from systemd-creds blobs and brings up the container, `sudo tailscale serve --https=443`. |
| `step-7-web-shell` | `npm install`, generates the machine-only `web-session-secret` (`bot-secrets.sh generate`), reads `web-ui-password` (typed by operator in Phase 0.5) from the systemd-creds blob, installs `<BOT_NAME>-web.service`, `sudo tailscale serve --https=8443`. |
| `step-8-memory` | Installs memorious-mcp as the baseline memory backend. |
| `step-9-telegram-daemon` | Copies `tg-bot.py` + `tg-post.sh` into `.telegram/`, drops the systemd unit, posts a BLOCKER asking for BotFather token. (Last phase — by the time you hit this, the rest of the bot is fully operational, so the BotFather handoff isn't gating anything else.) |
| `step-9-telegram-creds-blocker` | **Waits on you.** See "What you still do" below. |
| `step-9-telegram-activate` | Enables + starts `telegram-bot.service`, sends a test message round-trip. |
| `done` | Bot transitions to operational mode. |

Each phase is **idempotent** — re-running is safe if anything mid-fails. The bot's soul-loop will keep retrying until the phase succeeds or hits a blocker.

### What you still do

The bot writes `BLOCKER <name>: <instruction>` lines in `setup-state.md` `## Blockers` whenever it needs you. The soul-loop stops dispatching setup-runner until you remove (or `RESOLVED <name>:` the BLOCKER). Expected blockers:

1. **`BLOCKER telegram-botfather`** — happens during `step-9-telegram-daemon` (the *last* phase, intentionally — everything else is already running by this point). Open Telegram, message `@BotFather`, `/newbot`, save the token. DM your new bot once. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find your `chat.id`. Paste `TG_BOT_TOKEN`, `TG_BOT_USERNAME` (`@<name>_bot`), and `TG_CHAT_ID` into `setup-state.md` Values. Remove the BLOCKER line.

2. ~~**`BLOCKER web-shell-credentials`**~~ — no longer fires. The web-shell password is the one the operator typed in Phase 0.5 of `first-time-setup.sh`, so there's nothing to "write down" — they already have it.

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
<KIT>/runtime/setup-status.sh
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
mkdir -p $REPO_ROOT/cron-prompts
cp $KIT/runtime/inject-prompt.sh $REPO_ROOT/cron-prompts/
cp $KIT/runtime/cron-prompts/*.md $REPO_ROOT/cron-prompts/
chmod +x $REPO_ROOT/cron-prompts/inject-prompt.sh
```

Then `crontab -e`:

```cron
*/10 7-23 * * * <REPO_ROOT>/cron-prompts/inject-prompt.sh /soul-loop
*/30 * * * *   <REPO_ROOT>/cron-prompts/inject-prompt.sh /secretary
30 7 * * 1-5   <REPO_ROOT>/cron-prompts/inject-prompt.sh /wake-up
5 0 * * *      <REPO_ROOT>/cron-prompts/inject-prompt.sh /midnight-maintenance
```

Within 10 minutes you should see soul-loop fires in `cron-prompts/job-log.md`, and the secretary fires every 30 minutes capturing journal-worthy moments from your conversations.

### Step 6 detail — SilverBullet (the vault editor)

This is your daily interface to the bot's brain. Walked through fully in [silverbullet-setup.md](silverbullet-setup.md). The condensed version:

1. `sb-user-password` was already typed by the operator in Phase 0.5 (or pre-set via `BOT_PASSWORD`) and stored as a systemd-creds blob; nothing to do. Generate the machine-only `sb-auth-token`:
   ```bash
   bash $KIT/runtime/bot-secrets.sh generate sb-auth-token 24
   ```
   If you're doing the fully-manual fallback flow (no Phase 0.5 was run), `openssl rand -base64 24` for the password works too — just save it somewhere you can recover, since SB on a phone will ask for it.
2. The kit's `docker-compose.yml` at `$KIT/docker-compose.yml` already references `${BOT_NAME}` / `${SB_USER_PASSWORD}` / `${SB_AUTH_TOKEN}` as env vars. Bring the stack up via `bash $KIT/runtime/silverbullet-up.sh`, which decrypts both blobs into process env before invoking `docker compose up -d silverbullet` — plaintext stays in memory only.
3. `docker compose up -d` and visit `http://localhost:3001`. Log in with the SB_USER credentials. You should see your vault.
4. Expose via Tailscale: `sudo tailscale serve --bg --https=443 http://127.0.0.1:3001`. Now reachable from your phone at `https://<host>.<tailnet>.ts.net`.
5. Install the seeded plugs. `first-time-setup.sh` Step 2 already wrote `CONFIG.md` at the vault root with `config.set("plugs", {…})` declaring TreeView. In SilverBullet:
   1. Open the command palette (Ctrl/Cmd-K).
   2. Run `Plugs: Update`. SB reads `CONFIG.md`, downloads + compiles each plug, writes them to `_plug/`.
   3. Reload (Ctrl/Cmd-R). The TreeView folder sidebar should appear on the left.

   Want more plugs later? Edit the `config.set("plugs", {…})` table in `CONFIG.md` and re-run `Plugs: Update` — no `Plugs: Add` flow needed. Other config defaults (`taskStates`, `treeview.position`) live in the same file.

6. The kit also seeded a daily-handoff template at `_templates/handoff.md`. To create a new handoff page from SilverBullet: `Page: From Template` → pick `handoff`. SB stamps out `handoffs/YYYY/MM/DD.md` with the canonical structure (tasks, context, done). The bot's soul-loop sees the new `- [ ] … #handoff` checkboxes within 10 minutes.

When you first land on SilverBullet, [[index]] is the entry point (created from `templates/vault-pages/index.md` in Step 2) and [[dashboard]] shows live queries for open handoffs / tasks / recent activity. You can now read `journals/journal.md` from your phone and leave handoff tasks (`- [ ] do X #handoff`) for the bot.

### Step 7 detail — Web shell

The web shell is a small Node.js server that attaches to your `claude` tmux session and renders it through xterm.js in the browser, login-protected and Tailscale-only. Walked through end-to-end in [web-shell.md](web-shell.md). The condensed version:

1. `cd $KIT/web-terminal && npm install` (the directory already exists in the kit; no copy needed).
2. Create `$KIT/web-terminal/.env` with `PORT=3000`. The other values (`SESSION_SECRET`, `UI_USERNAME`, `UI_PASSWORD`) are loaded from systemd-creds blobs at service start:
   - `web-ui-password` was typed by the operator in Phase 0.5 (or pre-set via `BOT_PASSWORD`) — nothing to do.
   - `web-session-secret` is machine-only; generate via `bash $KIT/runtime/bot-secrets.sh generate web-session-secret 32`.
   - `web-ui-username` defaults to `$BOT_NAME`; override via `echo "<name>" | bash $KIT/runtime/bot-secrets.sh store web-ui-username` if needed.
3. Drop `/etc/systemd/system/<BOT_NAME>-web.service` (template at `$KIT/web-terminal/claude-web.service`; `WorkingDirectory=$KIT/web-terminal`). Enable and start.
5. `sudo tailscale serve --bg --https=8443 http://127.0.0.1:3000`.
6. Visit `https://<host>.<tailnet>.ts.net:8443`, log in, watch Claude type.

On iOS, "Add to Home Screen" makes it behave like a native app (PWA manifest is included).

### Step 8 detail — Vector memory (memorious-mcp baseline)

Installed by default during bot-driven setup. Walked through in [memory.md](memory.md). The doc covers the secretary note-capture pattern (cron-driven background note-taker) — useful once your conversations get long enough that you'd appreciate Claude writing the journal for you. If you want to *skip* the memory layer entirely (grep-only), see the bottom of `memory.md`.

### Step 9 detail — Telegram

**Intentionally last** — every other piece of the bot is operational by now, so the BotFather handoff (the only mid-flow human BLOCKER in the whole setup) doesn't gate anything else. Walked through end-to-end in [telegram-integration.md](telegram-integration.md). The condensed version:

1. In Telegram, message `@BotFather`, send `/newbot`, follow prompts, save the token.
2. DM your new bot once. Then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find your `chat.id`.
3. Create `$REPO_ROOT/.telegram/config` with `BOT_TOKEN=`, `CHAT_ID=`, `BOT_USERNAME=`. `chmod 600` it. (Token + chat id are loaded from systemd-creds at service start; the config file is a fallback for older installs and a place to record the bot username.)
4. Copy `tg-bot.py` and `tg-post.sh` from `$KIT/runtime/` into `$REPO_ROOT/.telegram/`. Make them executable (`chmod +x`).
5. Drop `/etc/systemd/system/telegram-bot.service` (template at `$KIT/runtime/telegram-bot.service`; `WorkingDirectory=$REPO_ROOT`, `ExecStart=/usr/bin/python3 $REPO_ROOT/.telegram/tg-bot.py`). Enable and start.
6. DM your bot something — anything. `journalctl -u telegram-bot -f` should show the message arrive. The file `$REPO_ROOT/.telegram/new-messages.txt` should appear.

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
