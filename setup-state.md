# Setup state

*This file tracks setup progress. Two readers:*

- *The **assisting Claude Code instance** (if you started one) walks Phase 0 + Steps 1–4 against this file. See `setup-orchestrator.md`.*
- *After the Step 4 reboot, the **bot itself** reads this file on every soul-loop, detects unfinished phases, and dispatches a `setup-runner` subagent to walk Steps 5–9. The bot stops dispatching once `Current phase: done`.*

*Replace the timestamp placeholders below when you start. Update `Last updated:` after every change.*

Started: <YYYY-MM-DD HH:MM>
Last updated: <YYYY-MM-DD HH:MM>
Current phase: phase-0

---

## Current phase reference

The bot's soul-loop reads the `Current phase:` line above and dispatches accordingly. Phase values, in order:

| Phase | Driven by | What runs |
|---|---|---|
| `phase-0` | Assisting CC (or human DIY) | Collect Values block (interview Nate) |
| `pre-step-5` | Assisting CC (or human DIY) | Steps 1–4 of `first-time-setup.md`: vault, keybindings, `claude-code.service`, verification reboot. **The bot doesn't exist yet.** |
| `step-5-silverbullet` | **Bot** (setup-runner) | Generate SB_USER_PASSWORD + SB_AUTH_TOKEN, write docker-compose.yml, `docker compose up -d silverbullet`, `tailscale serve` for HTTPS |
| `step-6-telegram-daemon` | **Bot** (setup-runner) | Copy `tg-bot.py` + `tg-post.sh` into `<VAULT>/.telegram/`, write `telegram-bot.service` (disabled). Post a BLOCKER asking for BotFather token. |
| `step-6-telegram-creds-blocker` | **Human** | Talk to BotFather, paste TG_BOT_TOKEN + TG_BOT_USERNAME + TG_CHAT_ID into the Values block. Remove the BLOCKER line. |
| `step-6-telegram-activate` | **Bot** (setup-runner) | `systemctl enable --now telegram-bot.service`, send a test message round-trip to verify. |
| `step-7-web-shell` | **Bot** (setup-runner) | `npm install` in `web-terminal/`, generate WEB_SESSION_SECRET + WEB_UI_PASSWORD, write `.env` and `claude-web.service`, enable, `tailscale serve` |
| `step-8-cron` | **Bot** (setup-runner) | Install the four crontab entries (soul-loop / wake-up / midnight-maintenance / brugs-diss if applicable) for the bot's unix user |
| `step-9-memory` | **Bot** (setup-runner) | Install memorious-mcp as the baseline memory backend; register in `~/.claude.json` |
| `done` | — | Soul-loop returns to its normal operational decision tree |

Idempotency: every step starts with a "is this already done?" probe (e.g. `docker compose ps silverbullet` shows running → skip). Safe to re-run.

---

## Values

*Populate these as you collect them. The orchestrator's Phase 0 walks the user through the upfront block conversationally; the just-in-time block is captured during the corresponding setup step (the bot writes to this section itself for openssl-generated secrets).*

### Collected at Phase 0 (upfront)

- **BOT_NAME**:                    <!-- e.g. nlbot -->
- **USER_NAME**:                   <!-- e.g. Nate -->
- **VAULT**:                       <!-- e.g. /home/nlbot/nlbot, default /home/$BOT_NAME/$BOT_NAME -->
- **OS_USER**:                     <!-- unix user; same as $BOT_NAME if you followed bootstrap.md -->
- **CANARY_PHRASE**:               <!-- 3–7 word memorable string -->
- **IDLE_PREFS**:                  <!-- reading / coding / writing / exploring -->
- **CREATIVE_OUTPUT**:             <!-- poems / stories / technical docs / music reviews / ... -->
- **COMM_STYLE**:                  <!-- direct / gentle / playful / formal -->
- **VALUES_CARES_ABOUT**:          <!-- quality / speed / creativity / accuracy -->
- **USER_ROLE**:                   <!-- free-form: what the user does / works on -->
- **USER_HOBBIES**:                <!-- free-form -->
- **USER_HOURS**:                  <!-- when the user is typically online -->
- **USER_PREFS**:                  <!-- non-negotiable preferences / always-do / never-do -->

### Collected just-in-time (bot writes these during Steps 5–7)

- **SB_USER_PASSWORD**:            <!-- Step 5: bot runs `openssl rand -base64 24` and writes here -->
- **SB_AUTH_TOKEN**:               <!-- Step 5: bot runs `openssl rand -base64 24` -->
- **TAILSCALE_HOSTNAME**:          <!-- Step 5: bot reads `tailscale status --json | jq -r .Self.HostName` -->
- **TG_BOT_TOKEN**:                <!-- Step 6: human pastes from BotFather -->
- **TG_BOT_USERNAME**:             <!-- Step 6: human pastes the @<botname>_bot handle -->
- **TG_CHAT_ID**:                  <!-- Step 6: human runs /getUpdates and pastes chat.id -->
- **WEB_SESSION_SECRET**:          <!-- Step 7: bot runs `openssl rand -hex 32` -->
- **WEB_UI_USERNAME**:             <!-- Step 7: defaults to $BOT_NAME unless human specifies otherwise -->
- **WEB_UI_PASSWORD**:             <!-- Step 7: bot runs `openssl rand -base64 24`, posts to user via BLOCKER for write-down -->

---

## Done

(none yet)

## In-progress

- Phase 0 — collect placeholder values (see "Values" above)

## Pending

- Steps 1–4 (human + assisting CC): prereqs check, vault skeleton, placeholder substitution, keybindings disable, `claude-code.service` install, **verification reboot**
- *After reboot, the bot picks up:*
- Step 5: SilverBullet container + Tailscale serve
- Step 6: Telegram daemon install + BotFather BLOCKER + activation
- Step 7: web shell
- Step 8: cron entries
- Step 9: memory backend (memorious-mcp baseline)
- final verification

## Blockers

*Format: each blocker is one line starting with `BLOCKER <short-name>:` followed by what the human needs to do to clear it. The bot reads this section every soul-loop and won't advance until the relevant blocker is removed (or replaced with `RESOLVED <short-name>:`). Examples will appear here once setup is running.*

(none)

## Notes

- (append one-liners here as you learn things worth remembering)
