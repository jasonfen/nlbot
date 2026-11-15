---
description: Compact writing checklist for ${BOT_NAME}'s runners, distilled from the humanizer skill
---
# Writing style for vault prose

A short version of the **humanizer** skill (`.agents/skills/humanizer/SKILL.md`, v3.1.0, based on Wikipedia's "Signs of AI writing") for the runners that write often and can't afford to load the full skill every run. Where the full skill is used:

| Writer | How it gets humanizer |
|---|---|
| `journal-synthesizer` (nightly, sonnet) | full skill preloaded (`skills: [humanizer]` frontmatter) |
| main session | invokes the `humanizer` skill before finishing long vault prose meant for ${HUMAN_NAME}: handoff responses, proposals, project/design pages |
| `secretary`, `wake-up-runner`, `soul-loop-runner` (haiku) | this page |

## Before you write the entry, check it

Every sentence has to add a fact the reader didn't already have. Keep every supported claim, and never add a fact, name, number or date that isn't in your source. (Fiction is the exception: invented detail is the job.)

Cut or rewrite these on sight:

1. **"Not X, but Y" contrasts** where nobody claimed X. State Y.
2. **One-line closers** that restate the point ("That's the lesson." "Clean."). End on the last fact.
3. **Sayings that sound deep** and staged run-ups ("Here's the thing:", "The short version:"). Say the point.
4. **Forced triads**: three items because three sounds finished. Use however many there really are.
5. **Dashes as the all-purpose connector.** Use a full stop, a comma or a colon.
6. **Inflation**: pivotal, crucial, key, robust (figurative), seamless, testament, landscape, showcase, underscore, delve, meticulous, quietly, vibrant, additionally. Use the plain word or drop it.
7. **Shallow -ing riders** ("…, ensuring reliability", "…, highlighting the need"). Make it its own sentence with a subject, or cut it.
8. **Bold as decoration.** Bold only the one thing a skimmer must not miss.
9. **Re-explaining what ${HUMAN_NAME} already knows.** He was there or can click the link. The new information goes first.
10. **Chat residue** in a vault file: "I hope this helps", "Let me know", "Great question".

Keep: technical words used literally (a `robust` parser, a cron `gate`), code, paths, commands, quotes, timestamps. Vary sentence length. Plain, specific and slightly uneven reads as a person.
