# Security — secrets handling

How <BOT_NAME> stores credentials and the rules the bot must follow when interacting with them.

## Where secrets live

| Credential | Encrypted blob | Loaded by |
|---|---|---|
| Telegram bot token | `/etc/<BOT_NAME>/secrets/tg-bot-token` | `telegram-bot.service` via `LoadCredentialEncrypted=` |
| Telegram chat id | `/etc/<BOT_NAME>/secrets/tg-chat-id` | same |
| Telegram bot username | `/etc/<BOT_NAME>/secrets/tg-bot-username` | same |
| SilverBullet user password | `/etc/<BOT_NAME>/secrets/sb-user-password` | `runtime/silverbullet-up.sh` (wrapper around `docker compose up`) |
| SilverBullet auth token | `/etc/<BOT_NAME>/secrets/sb-auth-token` | same |
| Web shell session secret | `/etc/<BOT_NAME>/secrets/web-session-secret` | `<BOT_NAME>-web.service` |
| Web shell UI username | `/etc/<BOT_NAME>/secrets/web-ui-username` | same |
| Web shell UI password | `/etc/<BOT_NAME>/secrets/web-ui-password` | same |

Each blob is a `systemd-creds` ciphertext, encrypted with the host's TPM (or host-key if no TPM is available). The blobs are bound to this host — they can't be copied to another machine and decrypted.

The `/etc/<BOT_NAME>/secrets/` directory is owned by root, mode 700. The bot user can `ls` (via sudo) to see *names*, but cannot read the blobs.

At service start, systemd opens each `LoadCredentialEncrypted=` blob and mounts the plaintext on a tmpfs at `$CREDENTIALS_DIRECTORY/<name>`. That tmpfs is visible only to the loading process — `cat /proc/<pid>/root/$CREDENTIALS_DIRECTORY/...` would require root and is unreachable from other services or from the bot user's shell.

## Bot-side rules

These are non-negotiable when you're the bot:

1. **Never echo, cat, grep, or print a plaintext secret to stdout.** Not in a journal entry. Not in a soul-loop-log line. Not in a sidechat reply. Not in a Telegram message. The blob's whole point is that no human-readable value ever lands somewhere a backup, a screenshot, or a log scrape could see it.

2. **Never read `/etc/<BOT_NAME>/secrets/` directly.** Those files are encrypted blobs; reading them yields ciphertext you'd then have to ask `systemd-creds decrypt` to open. Don't do that — there's no reason to.

3. **Do not grep across the vault for "BOT_TOKEN" / "SB_USER" / "PASSWORD" / etc.** The `setup-state.md` Values block contains pointers like `(systemd-creds: tg-bot-token)`, not values. Older installs may still have plaintext; if you find any, run `runtime/migrate-secrets.sh` to encrypt them and don't paste them into your reasoning.

4. **If you need to use a credential, you don't — a service does.** The architecture is queue-based: write to `.telegram/message.txt`, the daemon picks it up and sends. Write to a docker-compose service that's already up; don't fetch the token yourself. The only process that should ever see a plaintext token is the daemon that needs it.

5. **`runtime/bot-secrets.sh` is the only tool you call.** It exposes `generate`, `store`, `list`, `verify`, and `path` subcommands. There is **no `get`** by design — the script will refuse to print a plaintext value. If a workflow seems to require `bot-secrets get`, you've misread the architecture.

## Setting a new secret (setup-runner phases)

For credentials the bot generates (random tokens, passwords, session secrets):

```bash
<VAULT>/runtime/bot-secrets.sh generate <name> <length>
```

`generate` pipes `openssl rand` directly into `systemd-creds encrypt` — the plaintext never lands in a shell variable, a `setup-state.md` line, or a temp file.

For credentials the human types in (BotFather token, etc.):

```bash
read -rs token
printf '%s' "$token" | <VAULT>/runtime/bot-secrets.sh store tg-bot-token
unset token
```

The `read -rs` keeps the value out of `bash` history. The `unset` releases it from the current shell as soon as the pipe completes.

## Recovering a value (human, not bot)

If the human needs to recover a credential (e.g., to type a web-shell password into a phone), the value can be decrypted by root **on this host only**:

```bash
sudo systemd-creds decrypt /etc/<BOT_NAME>/secrets/web-ui-password -
```

This is a deliberate friction step: it requires shell access as a sudoer, can't be done by the bot, and prints to stdout exactly once. The human should record the value in a password manager and never display it again.

## Migration from plaintext

`runtime/migrate-secrets.sh` is a one-shot for boxes that were set up before this layout existed. It:

1. Reads existing plaintext from `setup-state.md` Values, `web-terminal/.env`, `.telegram/config`.
2. Encrypts each via `bot-secrets.sh store`.
3. Verifies the encrypted blob decrypts.
4. Redacts the plaintext lines in the source files (replaces with pointers).

Run once per box. Re-running is safe — `bot-secrets.sh store` skips names already encrypted.

## What you can verify without reading values

These are all safe for the bot to do:

- `<VAULT>/runtime/bot-secrets.sh list` — shows credential names only.
- `<VAULT>/runtime/bot-secrets.sh verify <name>` — confirms the blob can be decrypted on this host. Prints `ok: <name> decrypts on this host` or an error; never the value.
- `systemctl show <unit> -p LoadCredentialEncrypted` — confirms a unit's credential bindings.
- `bash <VAULT>/runtime/setup-status.sh` — reports phase state and credential presence by name.
