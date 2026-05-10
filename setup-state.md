# Setup state

*This is the state-tracking file the assisting Claude Code instance uses to track setup progress. The full instructions for using it are in `setup-orchestrator.md`.*

*Replace the placeholders below when you start. Update `Last updated:` after every change.*

Started: <YYYY-MM-DD HH:MM>
Last updated: <YYYY-MM-DD HH:MM>
Current phase: prereqs

## Done

(none yet)

## In-progress

- prereqs check (Claude Code, Docker, Node 20+ if doing web shell, Tailscale)

## Pending

- vault directory + `identity.md` (with canary phrase) + `user-profile.md`
- `CLAUDE.md` filled in from `CLAUDE-nate.md` template
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
