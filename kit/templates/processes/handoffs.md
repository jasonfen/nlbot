# Handoffs

Async task delegation from <USER_NAME> to <BOT_NAME>. Lives in the vault; tagged, checkbox-tracked, reply-documented.

## File layout

- `handoffs/YYYY/MM/DD.md` — the daily handoff page, one per day
  - Each task is a native SilverBullet checkbox with an `#handoff` tag
  - Context, reasoning, links live inline on the same page
- `handoffs/YYYY/MM/DD/*.md` — response subpages, one per task
  - Named by short slug, linked as a wikilink from the checkbox
  - Contain the work product (plan, diff, test results, post-mortem)

Per SilverBullet convention: the index file `handoffs/YYYY/MM/DD.md` is a **sibling** of its folder `handoffs/YYYY/MM/DD/`, not inside it.

## Detection

Grep for open handoffs anywhere in the vault:

```bash
grep -rn "\- \[ \].*#handoff" <VAULT>/ \
  | grep -v templates/ | grep -v node_modules \
  | grep -v CLAUDE.md
```

Filter out template pages (`templates/`) and process docs (`CLAUDE.md`). What's left is real work.

## Lifecycle

| State | Tag | Meaning |
|---|---|---|
| Pending | `#handoff` with `- [ ]` | Task queued, not started |
| In flight | same, add sub-notes | Working on it, WIP subpage |
| Complete | `- [x]` | Done, subpage has the deliverable |
| Blocked | `#handoff` + `#blocked-on-human` inline | Waiting on <USER_NAME>; soul-loop short-circuits to avoid re-acking the blocker |

## Response subpage shape

Minimum structure for a `handoffs/YYYY/MM/DD/<slug>.md` response:

```markdown
---
tags: handoff response
---

# <Task title>

## Context
<what <USER_NAME> asked + why>

## Approach
<how I'm tackling it>

## Work
<diffs, commands, findings, decisions>

## Status
<done / blocked on X / in progress, with concrete next step>
```

## Invariants

- Handoffs are **urgent** — ramp the soul-loop heartbeat and start immediately; don't wait for the next scheduled fire.
- Always journal handoff work in `journal.md` too, even when the handoff doc exists. The handoff doc is the *deliverable*; the journal entry is the *narrative*.
- Convert a `#handoff` to `#review` when the work is complete but awaiting external confirmation.
- Don't check off the box until the deliverable is actually present. No premature closure.
- Tag with `#blocked-on-human` once waiting solely on <USER_NAME>'s input — keeps the soul-loop from burning tokens re-acking it every hour.
