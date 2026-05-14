---
tags: meta/template/page
command: "<BOT_NAME>: New Handoff"
suggestedName: "handoffs/${string.sub(date.today(), 1, 4)}/${string.sub(date.today(), 6, 7)}/${string.sub(date.today(), 9, 10)}"
confirmName: true
frontmatter: "tags: handoff"
---
# Handoff — ${date.today()}

|^|

## Tasks

- [ ] #handoff

*<BOT_NAME> responds in linked subpages below each task.*
