# Telegram (optional)

A private one-to-one channel between you and the bot, for when you are away from a browser. Nothing else in the kit depends on it.

**Read this first: the Telegram path on the source system has not been moved to the cron wake path.** It still pokes the tmux pane, which is the thing the rest of the system stopped doing. This page documents what is running, then describes the change that would bring it in line. The change is untested.

## What is running

One Python daemon, `.telegram/tg-bot.py`, under `bot-telegram.service`. It uses only the standard library.

**Inbound.** The daemon long-polls Telegram's `getUpdates` with a 5-second timeout. For each text message:

1. It checks the chat id against `CHAT_ID` in `.telegram/config`. Anything else is rejected and logged to stderr.
2. It appends `[YYYY-MM-DD HH:MM:SS] <first name>: <text>` to `.telegram/new-messages.txt`. The timestamp is UTC.
3. It runs `tmux send-keys -t claude /telegram-check Enter`.

The session then runs `.claude/commands/telegram-check.md`: read the file, answer read-only questions directly, turn anything that would change files or systems into a proposal in `.telegram/pending-actions.txt` for your approval, and delete `new-messages.txt`.

The daemon's own comment calls the keystroke "best-effort" and names a `FileChanged` hook as the primary trigger. That hook is configured (`.telegram/hooks/on-new-messages.sh`), but Claude Code's `FileChanged` fires on the agent's own writes and not on writes by an outside process such as this daemon. That finding is recorded in the wake-path design notes as the reason a file-watching hook was rejected for crons. So in practice the keystroke is what delivers the message. If you are typing when it arrives, `/telegram-check` lands in your input.

**Outbound.** The bot writes its reply to `.telegram/message.txt` with the Write tool. Two things can send it:

- A `PostToolUse` hook on Write (`.telegram/hooks/post-message.sh`) runs `tg-post.sh` in the background. `tg-post.sh` reads the file, deletes it, and posts.
- The daemon also checks for `message.txt` on every loop. It renames the file to `.sending` before reading, so the two cannot both send the same message.

Messages over 4096 characters are split on paragraph or line breaks. The reply must be written with the Write tool. A shell redirect does not fire the hook, though the daemon's own check would still pick the file up within a few seconds.

## Install

1. In Telegram, message `@BotFather`, send `/newbot`, and keep the token.
2. Send your new bot any message. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` and find `"chat":{"id":…}`. That number is your chat id.
3. Copy the files from the rendered templates (`R` as in [first-time-setup.md](first-time-setup.md)):

   ```bash
   cd ${VAULT_DIR}
   mkdir -p .telegram/hooks
   cp "$R"/telegram/tg-bot.py "$R"/telegram/tg-post.sh .telegram/
   cp "$R"/telegram/hooks/*.sh .telegram/hooks/
   cp "$R"/telegram/config.example .telegram/config && chmod 600 .telegram/config
   $EDITOR .telegram/config                      # BOT_TOKEN, CHAT_ID, BOT_USERNAME
   chmod +x .telegram/tg-bot.py .telegram/tg-post.sh .telegram/hooks/*.sh
   cp "$R"/telegram/telegram-check.md .claude/commands/
   ```

4. Merge the two hook entries from `telegram/settings-hooks.json` into the `hooks` object of `.claude/settings.local.json`. Restart the session afterwards to be sure the hooks are loaded.
5. Install the service:

   ```bash
   sudo cp "$R"/systemd/bot-telegram.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now bot-telegram.service
   journalctl --no-pager -u bot-telegram -n 20
   ```

`.telegram/` is in the `.gitignore` template because the config holds the token.

**Check:** message the bot. `.telegram/new-messages.txt` appears, `/telegram-check` runs in the session, and a reply arrives.

## Moving it to the wake path

`TODO(verify)`: nobody has run this. It follows from reading `bin/cron-trigger-monitor.sh`, which prints `CRON <filename> <contents>` for any file in `.cron-triggers/` whose name does not start with a dot, once the session is idle.

The change is to make the daemon drop a trigger file where it now sends keys. In `tg-bot.py`, replace the body of `inject_telegram_check()`:

```python
def inject_telegram_check():
    """Drop a cron-style trigger; the poller delivers it when the session is idle."""
    trigger_dir = SCRIPT_DIR.parent / ".cron-triggers"
    trigger_dir.mkdir(exist_ok=True)
    tmp = trigger_dir / ".telegram.tmp"
    tmp.write_text("NEW=1")
    tmp.rename(trigger_dir / "telegram")
```

Then add a row to the routing table in `processes/cron-wake-path.md`:

| Notification | Agent | Afterwards |
|---|---|---|
| `CRON telegram NEW=1` | none; the main session runs `/telegram-check` | nothing to log |

What changes for you: a message is answered when the session is next idle, not in the middle of whatever it is doing. If the bot is in a long turn, the reply waits. What to test before trusting it: that a message sent while the session is busy is delivered afterwards, and that two messages in quick succession are both in `new-messages.txt` when the single trigger arrives.

## Conventions for the bot

From `telegram-check.md`:

- Replies are conversational and short. Longer material goes in the vault, with a pointer.
- A request that would change code, files or infrastructure gets "Understood — drafting a proposal for review" and an entry in `.telegram/pending-actions.txt`. The bot does not act on it from Telegram alone.
- It writes to `message.txt` and never calls `tg-post.sh` itself.

## Troubleshooting

- **The daemon exits at start.** `.telegram/config` is missing or lacks `BOT_TOKEN` or `CHAT_ID`.
- **Your messages are ignored.** Wrong `CHAT_ID`. The rejection is in `journalctl -u bot-telegram`.
- **Messages arrive in the file but the session does not react.** The tmux session is not named `claude`, or the keystroke was dropped. Type `/telegram-check` yourself.
- **Replies do not send.** Check the hook is in `settings.local.json` and that the reply was written with the Write tool.
