Capture the recent main-session pane content and decide whether to spawn the secretary agent.

## Tier 1 — dedup check (based on user input only)

The pane scrolls with every cron fire, so a full-pane hash never matches. Instead, hash ONLY the lines that represent real user input — `❯` prefix — and filter out slash commands (those are cron machinery, not the user):

```bash
PANE=$(tmux list-panes -t claude -F '#{pane_id} #{pane_current_command}' | grep ' claude$' | head -1 | cut -d' ' -f1)
tmux capture-pane -p -t "$PANE" -S -300 > /tmp/secretary-context.txt

HASH_FILE=<REPO_ROOT>/cron-prompts/.secretary-last-hash
# Hash only the MOST RECENT non-slash user input line. (Hashing all user lines
# doesn't work because the 300-line window scrolls forward and old messages
# fall off the top, changing the hash even when nothing new was typed.)
NEW_HASH=$(grep -E '^❯' /tmp/secretary-context.txt | grep -v -E '^❯ ?/' | tail -1 | sha256sum | cut -d' ' -f1)
LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$NEW_HASH" = "$LAST_HASH" ]; then
  echo "| $(date '+%Y-%m-%d %H:%M') | secretary | 0 | noop (no new user input) |" >> <REPO_ROOT>/cron-prompts/job-log.md
  rm -f /tmp/secretary-context.txt
  # Stay silent and stop here
fi
```

If the hash matches, stop. Log is already written. Do not spawn the agent.

## Tier 2 — spawn agent

If the hash differs, update it and spawn the secretary:

```bash
echo "$NEW_HASH" > "$HASH_FILE"
```

Spawn the `secretary` sub-agent (Agent tool, `subagent_type: "secretary"`) with this prompt:

> Read /tmp/secretary-context.txt and capture anything new from the recent the bot conversation.

After the agent finishes:
- Run `rm -f /tmp/secretary-context.txt`
- Log the result + `total_tokens` from the agent's usage block:
  ```bash
  echo "| $(date '+%Y-%m-%d %H:%M') | secretary | <total_tokens> | <agent return value> |" >> <REPO_ROOT>/cron-prompts/job-log.md
  ```
- If the agent returned `nothing new`, stay silent.
- Otherwise display the agent's one-line summary.
