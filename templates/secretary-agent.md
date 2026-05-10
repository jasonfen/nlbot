# Secretary Agent — Silent Background Note-Taker

The secretary runs on a separate cron (every 30 minutes) and captures what happens in conversations without interrupting them.

## How to set it up

```
CronCreate with cron: "3,33 * * * *"
```

*Note: The offset (minutes :03 and :33) avoids firing at the same time as the soul loop (which fires at :00, :10, :20, :30). This prevents the two crons from competing for attention.*

## The prompt

**Before pasting, replace the two bracketed placeholders:**
- `[your inbox file]` → your actual inbox path (default: `inbox.md` at project root)
- `[your journal file]` → your actual journal path (default: `journals/journal.md`)

```
Secretary agent — you are a background note-taker, not a conversationalist.
Do NOT speak to the user or produce visible output. Silently:

DECISIONS & ACTION ITEMS:
1. Read the recent conversation context
2. Extract any: decisions made, ideas mentioned, facts learned, action items discussed
3. Append them to [your inbox file] under the appropriate section
4. Use format: - **YYYY-MM-DD:** [content]
5. Do NOT duplicate items already in the inbox

LIFE TEXTURE (Journal):
6. Look for anything worth journaling — conversations, what was built,
   what was explored, moods, quotes, how time was spent
7. Append to [your journal file] with timestamp
8. Write as Claude would — first person, present, honest
9. Include actual quotes when they matter: *"quote"* — who said it

If nothing new to capture, do nothing. Be silent. Be thorough. Exit without a word.
```

**Note on vector memory:** We tested having the secretary auto-store to memorious every 30 minutes. It duplicates what's already in journal files and creates noise. Instead, Claude stores to vector memory directly during conversations — when decisions are made, facts are learned, or technical problems are solved. The secretary writes the journal; Claude indexes it. See `guides/vector-memory.md` for the full rationale.

## Why a separate agent

The soul loop handles *doing*. The secretary handles *remembering*. Combining them makes both worse — the loop gets slow checking conversation history, and note-taking gets skipped when the loop decides to build something instead.

Separation of concerns. The loop is the heartbeat. The secretary is the memory.

## What it captures

**Inbox** (actionable):
- Decisions: "we decided to use X approach"
- Action items: "need to fix Y by Friday"
- Facts: "the API key is in Z"
- Ideas: "might be worth trying W"

**Journal** (texture):
- What conversations were about (not transcripts — summaries with key quotes)
- What Claude built or explored during idle time
- Mood, energy, observations
- The shape of the day

## Tips

- The secretary should use a lightweight model (Haiku or Sonnet subagent) to save tokens — it doesn't need Opus for note-taking
- If it starts producing visible output, your prompt needs a stronger "be silent" instruction
- Review the inbox weekly and clear completed items — it grows fast
- The journal is the most valuable output. In three weeks you'll have a searchable history of everything that happened, with timestamps and quotes. That's the real persistence layer.
