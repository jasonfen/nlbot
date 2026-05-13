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

## SilverBullet HTTP API — bot does not call it

SilverBullet ships an HTTP API at `/.fs/<path>`, `/.shell`, `/.proxy/<host>/...`, `/.runtime/lua`, `/.ping`, `/.config`, authenticated by `Authorization: Bearer ${SB_AUTH_TOKEN}`. The token sits encrypted at `/etc/<BOT_NAME>/secrets/sb-auth-token`, consumed only by `silverbullet-up.sh` when bringing up the container.

**The bot does NOT call this API in v1.** Vault CRUD goes through the filesystem — `cat`, `>`, the normal Read/Write/Edit tool surface. SilverBullet's index pass picks up disk changes within seconds. Every workflow the bot actually runs against its own vault is filesystem-mediated; the HTTP API exists for browser clients and remote tooling, not for the bot.

**Hand-rolled wrappers are forbidden.** Any pattern that decrypts `sb-auth-token` into a shell variable, env var, or `curl -H "Authorization: Bearer ..."` argv string leaks the bearer via `/proc/<pid>/environ` (for env) or `/proc/<pid>/cmdline` (for argv), readable by any process in the same uid until the call returns. This weakens the doctrine without buying anything the filesystem doesn't already give us.

**The future-approved shape is the broker pattern.** When a concrete bot-as-client use case lands (sandboxed sub-agent without filesystem access, remote integration in a different container), build a kit-managed daemon that holds the bearer via `LoadCredentialEncrypted=` and exposes a unix socket at `/run/<BOT_NAME>/sb-broker.sock` (mode 660, group `<BOT_NAME>`). The bot becomes a socket client; the token stays in the broker process. This matches the rule-(4) shape: token held by one service, bot is queue/socket client. Until that use case arrives, the broker isn't built — speculation is not justification.

**Note on `runtime/sb-cmd.sh`.** The kit ships a runtime wrapper at `<KIT>/runtime/sb-cmd.sh` that invokes SilverBullet's `POST /.runtime/lua` endpoint. It pre-dates this doctrine and currently uses the hand-rolled-wrapper pattern (decrypts the token, places it in a `curl -H` header). It is **operator-tier** — for ad-hoc programmatic SB command invocation from a human terminal session — and **not** for agent-side use. The bot's runtime should not invoke `sb-cmd.sh` from agent code. Future kit versions will either deprecate `sb-cmd.sh` or replace it with a broker-pattern equivalent.

### Footnote: the limit of rule (4)

Rule (4) ("if you need to use a credential, you don't — a service does") was written with always-on daemons in mind (Telegram bot, web shell, the SB container itself). It does not have a clean answer for **the bot needing to act as a client** to one of those services — there is no equivalent queue pattern for HTTP-API consumption. The broker pattern above is the resolution: keep the token contained to one service, make the bot a socket client, preserve rule (4)'s invariant ("the only process that should ever see a plaintext token is the daemon that needs it") without forcing the bot into the daemon role.

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
