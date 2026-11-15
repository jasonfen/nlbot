# Operating

Day-two matters: restarts, upgrades, snapshots, and the failures that have actually happened.

## The services

| Unit | What | Depends on |
|---|---|---|
| `claude-code.service` | `Type=forking`. Runs `bin/start-claude.sh`, which creates the tmux session `claude`. `ExecStop` kills that session. `Restart=on-failure` | |
| `claude-web.service` | The web terminal, `node server.js` on `127.0.0.1:${TERM_PORT}` | attaches to the `claude` tmux session |
| `bot-shell.service` | Optional. A second tmux session `shell` in the same tmux server, a plain login shell | the tmux server from `claude-code.service` |
| `bot-vault-snapshot.timer` | Runs `bin/vault-snapshot.sh` 5 minutes after boot and every 15 minutes | |
| `silverbullet` (Docker) | `restart: unless-stopped` | |
| `tailscaled` | Holds the `serve` configuration | |
| cron | The user crontab | |

The tmux server started by `claude-code.service` is that unit's main process. If the last tmux session ends, the server exits and systemd considers the unit stopped. `bin/claude-restart` works around this, as described below.

## Restarting Claude Code

**By hand:** `sudo systemctl restart claude-code`. The session is killed and relaunched with `--continue`, so the conversation resumes. `/start` is typed automatically, and it re-arms the poller and re-orients.

**Onto a new version, unattended:** `bin/claude-restart --if-update`, from cron at 03:40.

Claude Code downloads updates while running and shows "Restart to update" in its footer. The built-in `/restart` refuses while a background task is running, and the cron poller always is. So the script does it from outside:

1. With `--if-update`, it exits unless the last 8 lines of the pane contain "Restart to update".
2. It re-executes itself under `tmux run-shell -b`, so the worker outlives the Claude session. A process started from Claude's own Bash tool would be killed with it.
3. It waits for five consecutive idle seconds, for up to ten minutes, then gives up. Busy means a spinner line in the footer or a running background agent. One idle sample is not enough: it can land between two tool calls of the same turn.
4. It creates a throwaway tmux session `restart-keepalive` so the tmux server, and with it the systemd unit, survives the gap.
5. It types `/exit`, confirms the "Exit and stop tasks" prompt if one appears, and kills the session after 30 seconds if it is still there.
6. It runs `bin/start-claude.sh` and waits up to five minutes for the poller to be re-armed.

It logs to `cron-prompts/claude-restart.log`. The log is in the vault and not in `/tmp` because a reboot once wiped it during the investigation that needed it.

The busy check reads the footer text. A change to the spinner format in a future Claude Code release will break it, and the script's comments say so.

## Upgrading SilverBullet

1. Read the release notes for every version between yours and the target. Check them against the code at that tag when something matters, not against forum threads.
2. Copy the compose file to a dated backup.
3. Change the image tag. Never rely on `:latest`.
4. `docker compose pull && docker compose up -d`.
5. `docker logs silverbullet 2>&1 | grep -i 'boot mode'` should still say multi-space.
6. `./bin/sb.sh ready`, then `./bin/sb.sh lua 'system.getVersion()'`.
7. Reload your browser tabs. Open CONFIG and check the browser console for a validation error.
8. Check the gate still works: `bash cron-prompts/gates/sb-mentions.sh; echo $?` should print 10 on a quiet vault, and `tail cron-prompts/inject.log` should show no `sb-mentions` error line.

Things that changed under the source system between 2.10 and 2.12, as a sample of what an upgrade can do: the space mount point moved from `/space` to `/data`; `.gitignore` stopped hiding files from SilverBullet; the screenshot endpoint was removed; single-space variables started forcing legacy mode; a `taskStates` schema change rejected the whole CONFIG.

## Snapshots and rollback

The vault is a git repo with two committers:

- **SilverBullet, managed revisions.** Commits page edits about 30 seconds after they settle, authored by the editing account. Skips dot-paths.
- **`bin/vault-snapshot.sh`, every 15 minutes.** Commits only dot-paths (`.claude/`, state files), as `snapshot-timer`. It is restricted to dot-paths on purpose: when it used to `git add -A`, it sometimes fired inside SilverBullet's 30-second window and committed page edits under the wrong author.

Before a multi-file edit, the bot runs `./bin/sb.sh snapshot`, which commits everything outstanding immediately. `./bin/sb.sh revlog 10` lists recent commits. To undo, use `Revision: Page History` → Restore in SilverBullet, or plain git.

Not in git, by the `.gitignore` template: tokens, `.telegram/`, `.memorious/`, the Chrome profile, and ephemeral cron state. **Back those up some other way** if you care about them. The vector store can be rebuilt only by re-storing.

## Off-box backup

Everything above lives on one disk. Git history protects you from bad edits, not from losing the box. Pick at least one of these. Doing both is better, because they cover different things.

### What has to survive

| What | Where | In the vault repo? |
|---|---|---|
| Journals, tasks, decisions, the bot's instructions | `${VAULT_DIR}` | yes |
| SilverBullet accounts and space settings | `${SB_DATA_DIR}` (`spaces.json`, account store) | no |
| MCP registrations, Claude Code project state | `~/.claude.json` | no |
| Auto-memory, session transcripts | `~/.claude/projects/` | no |
| Vector memory | `${VAULT_DIR}/.memorious/` | no (gitignored) |
| Tokens, Telegram config | the gitignored files listed above | no |

Claude Code's login and the Tailscale node state can be redone in minutes, so they don't need a backup. Everything else in the table is slow or impossible to recreate.

### Option A: a private git remote for the vault

This gives you an off-box copy of the vault with full history, and it's cheap. It doesn't cover the rows marked "no".

1. Create an **empty private** repository on GitHub, or Gitea/Forgejo if you self-host. Don't make it public. Journals end up holding hostnames, account names and sometimes credentials, and the gitignore can't catch what's written in a page.
2. Give the box its own key with write access to that one repository only (a GitHub *deploy key* with "Allow write access"), not your personal key:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/vault_backup -N '' -C "${BOT_NAME}-vault-backup"
   cat ~/.ssh/vault_backup.pub        # paste into the repo's Deploy keys, write access on
   cd ${VAULT_DIR}
   git remote add backup git@github.com:<you>/<vault-repo>.git
   git config core.sshCommand "ssh -i ~/.ssh/vault_backup -o IdentitiesOnly=yes"
   git push -u backup HEAD
   ```

3. Push on a schedule. SilverBullet's managed revisions only commit locally, and nothing in this kit pushes. An hourly crontab line is enough:

   ```
   17 * * * * cd ${VAULT_DIR} && git push -q backup HEAD >> cron-prompts/backup-push.log 2>&1
   ```

   The box is the only writer, so a push never needs a merge. If it starts failing, the log says why (usually a revoked key or a renamed repo).

4. Before the first push, check that nothing secret is tracked: `git ls-files | grep -iE 'token|secret|\.env|key'` should print nothing you'd mind leaving the box. If it does print something, remove it from git (`git rm --cached`), add it to `.gitignore` and commit. Files already in history stay there, so on a brand-new remote it's simpler to start from a fresh `git init` than to rewrite history.

### Option B: back up the whole machine

This covers every row in the table, including the ones git doesn't.

- **The box is a Proxmox LXC or VM:** schedule a `vzdump` backup job (Datacenter → Backup) to a Proxmox Backup Server or to storage on a *different* physical disk or host. Use snapshot mode so the bot keeps running. Daily, keeping a week or two, is plenty.
- **Any other Linux box:** use `restic` (or `borg`) to an off-box target, such as another machine over SFTP or an S3-compatible bucket. Back up `${VAULT_DIR}`, `${SB_DATA_DIR}`, `~/.claude.json` and `~/.claude/`. Exclude `node_modules/` and browser profiles. Run it from a systemd timer, and keep the restic password somewhere that isn't the box.

Whichever you pick, **do one restore** before you rely on it: restore to a scratch directory or a spare container and open a journal page. A backup you've never restored from is only a hope.

## Logs

| Question | Look at |
|---|---|
| Did cron fire, and what did the gate decide? | `cron-prompts/inject.log` |
| Did a runner run, what did it return, what did it cost? | `cron-prompts/job-log.md` |
| What did the soul loop actually do? | `cron-prompts/soul-loop-log.md` |
| Did the nightly restart run? | `cron-prompts/claude-restart.log` |
| Is SilverBullet's headless client healthy? | `./bin/sb.sh logs 50`, `docker logs silverbullet` |
| Why are the memory tools missing? | `~/.cache/claude-cli-nodejs/${PROJECT_SLUG}/mcp-logs-memorious-mcp/` |

Nothing in this kit rotates `inject.log` or `job-log.md`. On the source system they reached 1.7 MB and 1.1 MB.

For liveness checks use `pgrep -af <pattern>`, not `ps aux | grep`, and pass `--no-pager` to `systemctl` and `journalctl` when the bot runs them.

## Troubleshooting

Each of these happened on the source system.

### Triggers are not delivered

Symptom: files sit in `.cron-triggers/`, `inject.log` shows `TRIGGER` lines, and nothing happens in the session.

- **Is the poller running?** `pgrep -af cron-trigger-monitor`. If not, type `/start`.
- **Is it a stale one?** A poller from a previous session holds the lock and prints into nothing. `/start` kills it before arming for this reason.
- **Does the idle check ever pass?** The poller treats the session as busy unless it finds a pane in tmux session `claude` running `claude`, directly or as a child of the pane's shell. A changed launcher, a renamed tmux session, or a pane title that keeps changing will hold every trigger with no log line. This went unnoticed for 36 hours once, because every check looked only at whether the process existed.

After any change to the launcher, tmux, or the restart path, wait for one real `CRON` notification before calling it done.

### The soul loop fires every 10 minutes and always rests

An open `#handoff` line bypasses the backoff by design. If that handoff is waiting on you and is not tagged `#blocked-on-human`, every fire spawns a runner that returns `rest`. Tag it. The same goes for a `[due: …]` task that cannot be done yet: re-date it or tag it.

Repeated identical results from a runner mean the trigger is wrong, not the runner. Read the gate.

### A due date never fired

The line carried `#blocked-on-human`. The gate skips those. Or the task was not in `inbox.md`, `handoffs/` or `projects/`. Or its checkbox was not `[ ]`.

### The secretary keeps saying "nothing new" while you are talking

Check `job-log.md` for the gate's reason.

- `noop (no new … input)`: the latest human message has the same hash as last time.
- `noop (journaled through #N >= transcript #M)`: the main session's marker says it already journaled this far. If that is wrong, delete `cron-prompts/.journaled-through`.
- `noop (no transcript found)`: `${PROJECT_SLUG}` in the gate does not match the folder under `~/.claude/projects/`.

Do not diagnose the secretary from a tmux pane capture. It has not read the pane since the transcript gate was written, and a pane capture is empty under the fullscreen interface.

### `bridge_unavailable` from `sb.sh`

The headless client is not up. Run `./bin/sb.sh ready`. If it never becomes ready: `docker logs silverbullet 2>&1 | grep -i chrome`. Seen causes: no writable `HOME` for the container uid (set `HOME=/tmp`); a stale Chrome profile lock after the container hostname changed (pin `hostname:`).

### A query or widget shows nothing

In order: the client has not finished indexing (wait, or test a page you know works); the widget is outside the viewport; CONFIG was rejected by one bad key (browser console); a `space-lua` block threw partway and everything after it in that block was skipped. Space Lua errors appear only in the browser console, never in the container log.

### A task shows up in someone's Mention Inbox and will not go away

Something wrote a bare `@name` in prose. Wrap it in backticks or remove the at-sign. The runner prompts each carry a "mention hygiene" section for this reason.

### Files written at the wrong path after a move

After moving or renaming files on disk, an open browser tab can write a page back to its old path. Reload tabs after big moves.

### The memory tools are missing

See [memory.md](memory.md), "When the tools are missing".

### `tailscale serve` hostnames stopped working

`tailscale serve status`. If the config is gone, something ran `tailscale up --reset`. Re-add both services. If names do not resolve at all, see the MagicDNS section of [tailscale.md](tailscale.md).

### The session came back but does not know who it is

It should not happen: the SessionStart hook injects the orient instruction on startup, resume, clear and compact. If it does, type `/start`. Check that `.claude/settings.local.json` still lists `hooks/sessionstart-orient.sh` and that the script is executable.

### Wrong dates in journals

Every script takes time from `date`, so check the box's timezone (`timedatectl`). The one component that used UTC regardless was memorious, which `bin/memorious-localtime.py` patches.

### The disk fills up

The source box has a 16 GB disk and was at 83% in November 2026, with a much larger vault than a new one will have. Nothing in this kit watches disk space; the source system runs a separate watcher for it. `du -sh` the vault, `docker system df`, and the logs under `cron-prompts/` are the places to look.

## Habits that prevented repeats

The first four are in `CLAUDE.md` under "Diagnostic discipline". The last is from the source system's own notes. They are worth reading as an operator too.

- **Absent, or just unmatched?** When data is missing, check whether it is not there or the filter is not selecting it.
- **Measure the input before theorising about cost.**
- **A passing check is not a passing mechanism.** Force the failure case.
- **Verify the effect, not the action.** Check the far end.
- **A negative result needs a known positive.** Show the instrument can report a hit before believing its silence.
