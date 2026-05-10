Handle new Telegram messages from the user. The polling daemon has already written
incoming messages to `.telegram/new-messages.txt`.

## Instructions

1. Read `.telegram/new-messages.txt`. If it doesn't exist or is empty, say "No new Telegram messages" and stop.
2. For each line (format: `[YYYY-MM-DD HH:MM:SS] User: content`), classify and handle:

### Read-only response (reply via Write to `.telegram/message.txt`)
- Pings, status checks, "are you there?" → reply with current status
- Questions about what you're working on → check recent context and reply with real summary
- Informational questions → answer from context (git history, file state, journal)
- Thanks/acknowledgments → brief friendly reply

### Action proposal (queue for user approval)
- Requests to change code, fix bugs, deploy, refactor, create files, run commands
- Anything that would modify the repo, infrastructure, or external state

For proposals:
1. Reply via `.telegram/message.txt`: `Understood — drafting a proposal for review.`
2. Append to `.telegram/pending-actions.txt`:
```
=== PROPOSAL [YYYY-MM-DD HH:MM:SS] ===
REQUEST: their original message
ANALYSIS: what you think they want and how you'd approach it
PLAN:
- step 1
- step 2
STATUS: pending
===
```
3. Tell the user (in your output, not on Telegram) that a new proposal is pending.

## After processing

4. Delete `.telegram/new-messages.txt` so fresh messages can arrive.
5. Briefly summarize what you handled.

## Important
- Use Write tool for `.telegram/message.txt` — the hook posts automatically.
- Do NOT call tg-post.sh directly.
- This is a private 1:1 channel — no @mentions needed, responses can be conversational.
- Keep replies to 1–3 sentences for normal exchanges; longer responses belong in the journal where Nate can read them deliberately.
