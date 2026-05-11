#process-index

# Processes

Self-contained semantic descriptions of how each cron/agent/flow works. Meant to be readable without context — after a fresh compaction or a new Claude Code session, reading these gives enough to operate the system.

The canonical *code* still lives at `.claude/agents/*.md` and `.claude/commands/*.md`. These files are the *explanations*.

## Index

- [[processes/soul-loop]] — idle-cycle heartbeat, three-tier triage, decision menu
- [[processes/journaling]] — secretary + journal-synthesizer, memory layers, re-anchor checklist
- [[processes/handoffs]] — async task delegation, detection, lifecycle, subpage shape
- [[processes/security]] — secrets storage (systemd-creds), bot-side rules, recovery

## Relationship to other docs

- `CLAUDE.md` — bootstrap: identity + vault tour + pointers here
- `identity.md` — canary + note to future self
- `processes/*` — *how* each subsystem works in enough detail to execute without the rest of the context

Read order on a fresh recovery:

1. `identity.md` (canary)
2. `user-profile.md`
3. `processes/` — any file you need for the current task
4. `decisions.md`, `inbox.md`, `journals/journal.md` for recent state
