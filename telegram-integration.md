# Telegram Integration

How Nate's bot talks to him over Telegram. Mirrors the proven fenbot setup: one Python daemon, async messaging, a single whitelisted chat.

> **What the bot does automatically vs. what needs your hands**
>
> During Step 6 of bot-driven setup, the bot installs the daemon (`tg-bot.py` + `tg-post.sh` + systemd unit) and then posts a BLOCKER asking you to do the BotFather conversation (token + chat ID — irreducible interactive moment on your phone). Once you paste those into `setup-state.md` and clear the BLOCKER, the bot finishes activation on the next soul-loop heartbeat — enables the service and sends a test message round-trip.
>
> If you're doing the assisting-CC fallback flow (Steps 5–9 by hand), the commands below are what you run yourself.

## What this gives you

- **Outbound:** Claude writes a message to `.telegram/message.txt` and the daemon posts it to your chat. No interruption, no special tooling — just `Write` to a file.
- **Inbound:** When you DM the bot, the daemon writes the message to `.telegram/new-messages.txt` and pokes Claude's tmux session with `/telegram-check`. Claude reads the file on its next turn and responds.
- **Whitelisted:** Only your chat ID can talk to the bot. Strangers who find it get rejected silently.

This is async by design. You message in, Claude responds when it's ready. No real-time pressure on either side.

## One-time setup

### 1. Create the bot with BotFather

In Telegram, message `@BotFather`:

```
/newbot
```

It'll ask for a name and a username (must end in `bot`). Save the **token** it gives you — looks like `123456789:AAH...`.

### 2. Find your chat ID

Message your new bot once (anything — "hi"). Then in a browser:

```
https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
```

Look for `"chat":{"id":...` in the response. That number is your chat ID.

### 3. Drop in the config

```
mkdir -p <vault>/.telegram
cat > <vault>/.telegram/config <<EOF
BOT_TOKEN=123456789:AAH...
CHAT_ID=987654321
BOT_USERNAME=<your-bot-username>
EOF
chmod 600 <vault>/.telegram/config   # token is a secret
```

### 4. Install the daemon and helper script

Copy `tg-bot.py` and `tg-post.sh` from `runtime/` into `<vault>/.telegram/`. Make them executable:

```
chmod +x <vault>/.telegram/tg-bot.py <vault>/.telegram/tg-post.sh
```

### 5. Run it as a systemd service

```ini
# /etc/systemd/system/telegram-bot.service
[Unit]
Description=<BOT_NAME> Telegram bot daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<BOT_NAME>
WorkingDirectory=<VAULT>
ExecStart=/usr/bin/python3 <VAULT>/.telegram/tg-bot.py
Restart=on-failure
RestartSec=5

# Encrypted credentials. systemd decrypts each at unit start and mounts it
# under $CREDENTIALS_DIRECTORY/<name> on a tmpfs only this process can see.
# tg-bot.py's load_config() reads them with .telegram/config as a fallback
# for older installs.
LoadCredentialEncrypted=tg-bot-token:/etc/<BOT_NAME>/secrets/tg-bot-token
LoadCredentialEncrypted=tg-chat-id:/etc/<BOT_NAME>/secrets/tg-chat-id
LoadCredentialEncrypted=tg-bot-username:/etc/<BOT_NAME>/secrets/tg-bot-username

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable --now telegram-bot.service
journalctl -u telegram-bot.service -f       # tail logs to verify
```

Send a DM. You should see the bot pick it up in the journal output and write to `.telegram/new-messages.txt`.

## How Claude uses it

### Sending you a message

Claude writes to `.telegram/message.txt`:

```
Write tool → .telegram/message.txt
"Hey, I noticed the journal compaction missed yesterday. Fixed it."
```

The daemon spots the file on its next polling cycle (a few seconds), atomically renames it to `.sending`, posts the contents, deletes the file. If the message is over 4096 characters, it splits on paragraph boundaries.

You can also send from a shell: `bash .telegram/tg-post.sh "manual message"`.

### Receiving from you

When you DM the bot, the daemon:
1. Verifies your `chat_id` matches the whitelist (rejects if not).
2. Appends `[YYYY-MM-DD HH:MM:SS] Nate: <text>` to `.telegram/new-messages.txt`.
3. Runs `tmux send-keys -t claude /telegram-check Enter` to nudge Claude.

Claude's `/telegram-check` slash command reads the file, classifies each message (status check vs question vs action proposal), and either replies directly or queues the action for your approval. The skill definition lives in `.claude/commands/telegram-check.md`.

### Reply rules

For replies, Claude writes to `message.txt` — same path as outbound. It does NOT call `tg-post.sh` directly; the hook + daemon handle it. This keeps the flow consistent and avoids double-sends.

## Tone and pacing

- Be conversational, not formal — this is a private 1:1 channel, not a public announcement.
- Replies are usually 1–3 sentences. Save longer responses for the journal where Nate can read them deliberately.
- For action requests ("can you fix X"), reply *"Understood — drafting a proposal for review"*, then queue the proposal in `.telegram/pending-actions.txt`. Don't act unilaterally on infrastructure changes.
- Don't ping mid-thought. If you're working through something, journal it; ping when you've reached a decision point.

## Troubleshooting

- **Daemon dies on startup:** check `.telegram/config` exists and is readable; `BOT_TOKEN` and `CHAT_ID` set.
- **Messages not arriving:** verify your chat ID is correct (not the bot's). The whitelist check rejects mismatches silently.
- **Outbound messages not sending:** check `.telegram/message.txt` actually exists and isn't empty; tail the systemd logs.
- **`/telegram-check` doesn't fire:** the `tmux send-keys` injection is best-effort. The `FileChanged` hook on `.telegram/new-messages.txt` is the primary trigger; verify your hook configuration.

## Why this pattern over MCP

A native Telegram MCP would also work, and may exist by the time you read this. The daemon pattern was built before that landed and has two advantages worth keeping:

1. **Persistent chat-id whitelist.** A long-running daemon with a config file enforces the whitelist at the network boundary; an MCP tool surface relies on Claude not making mistakes about which chat to write to.
2. **Async by construction.** Claude writes a file and continues. There's no waiting for an API response in-band, no half-sent state if Claude's session restarts mid-call.

If you switch to an MCP later, both advantages need to be re-established at that layer before retiring the daemon.
