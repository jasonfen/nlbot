Run the secretary manually. Uses the same transcript gate as the cron path.

**Do not scrape the tmux pane.** This command used to run `tmux capture-pane`,
which returns only ~48 lines of UI chrome under the fullscreen TUI and can never
see the conversation. The real path has read the session transcript since
2026-08-11. The pane-scraping version stayed here after the switch, and running
it on 2026-09-10 convinced a session that the secretary was blind. It also wrote
to the same hash file as the real gate. Stubbed to delegate on 2026-09-10.
Current design: `processes/cron-wake-path.md`.

```bash
bash ${VAULT_DIR}/cron-prompts/gates/secretary.sh; echo "gate exit: $?"
```

- **exit 10** means no new ${HUMAN_NAME} input, or it's already journaled. The gate has
  written the job-log line. Stop, and do not spawn the agent.
- **exit 0** means there's new input, and the gate has written
  `/tmp/secretary-context.txt`. Spawn the `secretary` sub-agent (Agent tool,
  `subagent_type: "secretary"`) with:
  > Read /tmp/secretary-context.txt and capture anything new from the recent ${BOT_NAME} conversation.

  Then log the result and `total_tokens`:
  ```bash
  echo "| $(date '+%Y-%m-%d %H:%M') | secretary | <total_tokens> | <agent return value> |" >> ${VAULT_DIR}/cron-prompts/job-log.md
  ```
