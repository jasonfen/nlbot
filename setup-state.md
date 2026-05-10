# Setup state

*This is the state-tracking file the assisting Claude Code instance uses to track setup progress. The full instructions for using it are in `setup-orchestrator.md`.*

*Replace the placeholders below when you start. Update `Last updated:` after every change.*

Started: <YYYY-MM-DD HH:MM>
Last updated: <YYYY-MM-DD HH:MM>
Current phase: phase-0

## Values

*Populate these as you collect them. The orchestrator's Phase 0 walks the user through the upfront block conversationally; the just-in-time block is captured during the corresponding setup step.*

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

### Collected just-in-time

- **TG_BOT_TOKEN**:                <!-- Step 6: from BotFather -->
- **TG_BOT_USERNAME**:             <!-- Step 6: @<botname>_bot -->
- **TG_CHAT_ID**:                  <!-- Step 6: from /getUpdates -->
- **SB_USER_PASSWORD**:            <!-- Step 5: openssl rand -base64 24 -->
- **SB_AUTH_TOKEN**:               <!-- Step 5: openssl rand -base64 24 -->
- **TAILSCALE_HOSTNAME**:          <!-- Step 5: tailscale status --json | jq -r .Self.HostName -->
- **WEB_SESSION_SECRET**:          <!-- Step 7 (optional): openssl rand -hex 32 -->
- **WEB_UI_USERNAME**:             <!-- Step 7 (optional): default $BOT_NAME -->
- **WEB_UI_PASSWORD**:             <!-- Step 7 (optional): openssl rand -base64 24 -->

## Done

(none yet)

## In-progress

- Phase 0 — collect placeholder values (see "Values" above)

## Pending

- prereqs check (Claude Code, Docker, Node 20+ if doing web shell, Tailscale)
- vault directory created; substitute Phase 0 values into all template files (`CLAUDE.md`, `identity.md`, `user-profile.md`, `soul-loop.md`, `dot-claude/agents/*.md`, `dot-claude/commands/*.md`, `web-terminal/claude-web.service`, etc.)
- keybindings disable (`~/.claude/keybindings.json`)
- runtime files copied to vault (`runtime/` and renamed `.claude/`)
- `claude-code.service` installed + verification reboot
- SilverBullet container running + Tailscale serve
- Telegram bot created via BotFather + daemon running + service
- (optional) web shell + service + Tailscale serve
- cron entries installed (run AFTER the Step 4 verification reboot)
- final verification — all six "done" checks pass
- (optional, week 2+) memory backend (memorious or chosen alternative)

## Blockers

(none)

## Notes

- (append one-liners here as you learn things worth remembering)
