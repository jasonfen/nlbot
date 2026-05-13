# Job Log

Append-only record of every cron-driven agent invocation. Each row: timestamp, agent name, `total_tokens` consumed (or 0 for shell-only / noop runs), and the agent's one-line return value.

The bot and operator both write here:
- `/soul-loop`, `/secretary`, `/wake-up`, `/midnight-maintenance`, `/setup`, `/sidechat-check` all append a row on each fire.
- Shell-only rest cycles still log (with 0 tokens) so the heartbeat is visible.
- The journal-synthesizer reads this file at midnight to confirm whether the day had any non-rest activity before writing the daily journal entry.

Live in the vault root so SilverBullet indexes it. Tail the file from the SB UI or `tail -f <VAULT>/job-log.md` to watch the heartbeat in real time.

---

| Time | Job | Tokens | Result |
|------|-----|--------|--------|
