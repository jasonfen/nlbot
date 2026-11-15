# Handoffs

Async task delegation from ${HUMAN_NAME} to ${BOT_NAME}. Lives in the vault; tagged, checkbox-tracked, reply-documented.

## File layout

- `handoffs/YYYY/MM/DD.md` — the daily handoff page, one per day
  - Each task is a native SilverBullet checkbox with an `#handoff` tag
  - Context, reasoning, links live inline on the same page
- `handoffs/YYYY/MM/DD/*.md` — response subpages, one per task
  - Named by short slug, linked as a wikilink from the checkbox
  - Contain the work product (plan, diff, test results, post-mortem)

Per SilverBullet convention: the index file `handoffs/YYYY/MM/DD.md` is a **sibling** of its folder `handoffs/YYYY/MM/DD/`, not inside it.

## Detection

Grep for open handoffs in the two canonical locations (the same scope the soul-loop gate uses):

```bash
grep -rhn "\- \[ \].*#handoff" ${VAULT_DIR}/handoffs/ ${VAULT_DIR}/inbox.md \
  | grep -v "#blocked-on-human" | grep -v "\.conflicted"
```

Don't grep the whole vault: docs that describe the syntax contain example checkboxes, and counting those inflates the number.

## Mentions, anchors and authorship (SilverBullet 2.11, since 2026-09-24)

Each behaviour below was verified on a live SilverBullet 2.11+ instance.

- **New handoff tasks carry `@${BOT_NAME}`**: `- [ ] <ask> #handoff @${BOT_NAME}`. The templates
  (`${BOT_NAME}: New Handoff`, `/handoff-task`) insert it. That puts the task in ${BOT_NAME}'s Mention Inbox
  and wakes ${BOT_NAME} through the `sb-mentions` gate as well as the soul-loop handoff count.
  **Ticking the task closes the mention.** Older tasks without `@${BOT_NAME}` still work via the grep.
  (Templates build the at-sign with `${"@" .. "${BOT_NAME}"}` so the template pages themselves aren't mentions.)
- **On pickup, ${BOT_NAME} anchors the task**: it inserts `$h-YYYY-MM-DD-<slug>` right after the checkbox,
  e.g. `- [ ] $h-2026-09-23-backup-options Analyze these options… #handoff @${BOT_NAME}`. The anchor becomes
  the task's stable ref; `[[$h-…]]` links to it from anywhere and `![[$h-…]]` transcludes just the task.
  Anchors must be unique across the space; the date prefix keeps them so.
- **The response subpage is signed and points back**: frontmatter `tags: handoff-response` and
  `authors: ${BOT_NAME}` (an `authored` relation to ${BOT_NAME}), and a first line `Answers [[$h-…]].`
  The day page still links the response under the task (`  - Response: [[handoffs/…/<slug>]]`).
- **Questions back to ${HUMAN_NAME}** go on the response page as an `@${HUMAN_HANDLE}` task or comment, which lands in his
  Mention Inbox, and the day-page task gets `#blocked-on-human` as before (that tag is the soul-loop's brake).
- **No `recipients:` frontmatter on day pages** (a deliberate deviation from the research): a page-level
  recipient never auto-closes, while a per-task `@${BOT_NAME}` closes when ticked.

## Lifecycle

| State | Tag | Meaning |
|---|---|---|
| Pending | `#handoff` with `- [ ]` | Task queued, not started |
| In flight | same, add sub-notes | Working on it, WIP subpage |
| Complete | `- [x]` | Done, subpage has the deliverable |
| Blocked | `#handoff` + `#blocked-on-human` + note inline | Waiting on the human; say what for on the line. Remove the tag when answered |

## Response subpage shape

Minimum structure for a `handoffs/YYYY/MM/DD/<slug>.md` response:

```markdown
---
tags: handoff-response
authors: ${BOT_NAME}
---

# <Task title>

Answers [[$h-YYYY-MM-DD-<slug>]].

## Context
<what ${HUMAN_NAME} asked + why>

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
- Convert a #handoff to `#review` when the work is complete but awaiting external confirmation (e.g. someone else's review).
- Don't check off the box until the deliverable is actually present. No premature closure.
