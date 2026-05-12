Spawn the `wake-up-runner` sub-agent (Agent tool, `subagent_type: "wake-up-runner"`) with this prompt:

> Run the morning wake-up routine: re-anchor, health check, journal a morning entry, count open handoffs.

After the agent returns, log the result + `total_tokens` from the agent's usage block:
```bash
echo "| $(date '+%Y-%m-%d %H:%M') | wake-up | <total_tokens> | <agent return value> |" >> <REPO_ROOT>/cron-prompts/job-log.md
```

Display ONLY the agent's one-line return value.
