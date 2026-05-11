Manually dispatch the setup-runner.

Normally the soul-loop calls setup-runner automatically when `<VAULT>/setup-state.md` Current phase != done. Use this command to:
- Resume after editing setup-state.md (e.g., resolving a BLOCKER and wanting to retry immediately instead of waiting for the next soul-loop fire).
- Force a re-run of a phase that mid-failed and needs a do-over.
- Debug.

```bash
# Show the current setup state
grep -E '^(Current phase|## (Done|In-progress|Blockers))' <VAULT>/setup-state.md 2>/dev/null || echo "(no setup-state.md — bot is already done)"
```

If `Current phase: done` and you still want to re-run a specific phase, edit `<VAULT>/setup-state.md` to set Current phase to the phase name (e.g., `step-5-cron`) before invoking this command.

Spawn the `setup-runner` sub-agent (Agent tool, `subagent_type: "setup-runner"`) with this prompt:

> Read /home/<BOT_NAME>/<VAULT>/setup-state.md, find the Current phase, and execute that phase. One phase per dispatch. Update state when done. Return one line.

After the agent returns, log the result + `total_tokens` from the agent's usage block:
```bash
echo "| $(date '+%Y-%m-%d %H:%M') | setup | <total_tokens> | <agent return value> |" >> <VAULT>/cron-prompts/job-log.md 2>/dev/null || true
```

Display only the agent's one-line return value.
