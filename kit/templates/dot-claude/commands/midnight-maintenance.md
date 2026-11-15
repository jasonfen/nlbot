Spawn the `journal-synthesizer` sub-agent (Agent tool, `subagent_type: "journal-synthesizer"`) with this prompt:

> Synthesize every past day's running journal entries into its daily file, update the monthly summary, and remove those entries so journal.md holds only today.

After the agent returns, log the result + `total_tokens` from the agent's usage block:
```bash
echo "| $(date '+%Y-%m-%d %H:%M') | midnight-maintenance | <total_tokens> | <agent return value> |" >> ${VAULT_DIR}/cron-prompts/job-log.md
```

Display ONLY the agent's one-line return value.
