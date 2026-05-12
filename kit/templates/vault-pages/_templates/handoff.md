---
tags: template
description: "Daily handoff page — async tasks <BOT_NAME> picks up on the next soul-loop"
hooks.newPage:
  suggestedName: "handoffs/{{|date(today, '%Y/%m/%d')|}}"
---

# Handoff for {{|date(today, '%Y-%m-%d')|}}

## Tasks

- [ ] #handoff <one-line description; <BOT_NAME>'s soul-loop will pick this up within 10 min>

## Context

(What changed, what needs eyes, what's in flight. The bot reads this — be terse but specific.)

## Done

(<BOT_NAME> moves checkboxes here once it ships. Leave empty at file creation.)
