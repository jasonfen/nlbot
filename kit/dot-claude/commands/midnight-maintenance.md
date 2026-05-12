Spawn the `journal-synthesizer` sub-agent (Agent tool, `subagent_type: "journal-synthesizer"`) with this prompt:

> Synthesize today's running journal entries into a daily file, update the monthly summary, and compact journal.md.

After the agent returns, log the result + `total_tokens` from the agent's usage block:
```bash
echo "| $(date '+%Y-%m-%d %H:%M') | midnight-maintenance | <total_tokens> | <agent return value> |" >> <REPO_ROOT>/cron-prompts/job-log.md
```

Display ONLY the agent's one-line return value.
