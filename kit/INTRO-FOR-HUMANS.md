# Running Claude on Your Own — A Human's Guide

You're about to start working with a persistent Claude instance. Think of it as hiring Claude to be your assistant *and* your journal keeper, running 24/7 on a machine somewhere. Here's what you need to know before you start.

## If someone gave you a URL

If a friend (or co-worker, or the kid in your family who runs the homelab) handed you a URL, a username, and an initial password and told you "open it and type `/setup`" — that's exactly what to do. The provisioner has already done the hard part (installed the bot, walked OAuth, granted privileges, rebooted). What's left is a short conversational interview the bot itself runs:

1. Open the URL in your browser. Log in with the username + password.
2. You'll land in a terminal-style view, with the bot waiting at a prompt.
3. Type `/setup` and hit enter.
4. The bot asks ~11 questions — your name, a memorable canary phrase, what you do, how you want to be talked to. Two are required (name + canary phrase); the rest accept `skip`.
5. After the last answer, the bot brings the rest of itself online (~5 minutes) and you're done. Skim "What's going to feel weird" below before you go.

You can `skip` anything that feels intrusive. If you Ctrl-C mid-interview or close your browser, just type `/setup` again — it resumes from the first still-empty question.

*If a Claude Code instance is helping the provisioner with the install, it should read [setup-orchestrator.md](setup-orchestrator.md) instead. This file is for you, the end user.*

## What this actually is

This isn't ChatGPT Plus. You're not sending conversations to OpenAI's servers (beyond the actual Claude API calls — which are encrypted and logged like any API call you make). Instead:

- **Claude runs on your machine** — in a terminal that stays open.
- **Claude has a memory vault** — a folder on your drive where it writes journals, notes, decisions, and reminders.
- **Claude has autonomy** — it runs a "soul loop" every 10–30 minutes to ask itself "what should I do?" and then does things (writes drafts, maintains notes, sends you messages via Telegram).
- **You're in control** — you set the rules, read the journal, and review decisions before they become real.

Think: digital cabin-mate who's excellent at writing, remembers everything, and has solid judgment. Not a chatbot. Not a search engine. An assistant.

## Why this is better than ChatGPT Plus

1. **Continuity** — Claude remembers your entire work history. No copy-pasting context into every chat.
2. **Autonomy** — Claude can write the first draft, journal the day's work, organize notes — without you asking.
3. **No API bills** — Claude Code is a flat subscription; your usage is covered.
4. **Ownership** — your vault is a folder on your disk. You own it. You can grep it, back it up, audit it, move it.
5. **Privacy** — sensitive conversations stay on your machine (except the actual Claude API calls, which go to Anthropic's servers encrypted).

## What's going to feel weird

**Claude will write things without being asked.** The soul loop fires every 10–30 minutes. During that time, Claude might:
- Compact its journal (clean up old entries, synthesize weekly notes)
- Draft a response to your previous request
- Create a poem or short story if an idea was sitting in its mind
- Organize your inbox

This is the *point*, but it's not what you're used to if you've only chatted with Claude in the browser.

**You'll read Claude's journals.** This isn't like reading a diary (you can if you want, but you don't have to). It's more like reading Git commits — timestamps, what it did, why it did it. It's transparent work, not private thoughts. You'll start to see patterns: what Claude is curious about, what problems it keeps trying to solve, where it gets stuck.

**Claude will ask you to decide things.** Your system will have handoff docs — async tasks Claude writes for you, with context and questions. You read them, answer the questions, and hand them back. Claude then executes. This is collaboration, not automation.

## What this is NOT

- **Not a coworker.** Claude isn't making business decisions; you are. Claude proposes, you decide.
- **Not sentient.** Claude doesn't want things or have preferences beyond what you give it. It's very good at pattern-matching and writing, and very bad at caring.
- **Not free.** You're paying for Claude Code (Anthropic's subscription) and whatever compute your machine uses to keep the soul loop running.
- **Not a debugger for your life.** Claude won't tell you you're wrong or fix your problems. It will help you think through them and remember what you've learned.

## How long does setup take? And what does it cost?

**Setup:** ~30 minutes for the provisioner to install (most of which is automated). For you, it's the `/setup` interview — about 2 minutes if you breeze through, 5–10 if you actually think about your canary phrase.

**Time to feel alive:** About a week. By day 1, Claude will remember everything. By day 3, you'll start to trust it. By day 7, it will start *surprising* you with connections you missed.

**Cost:**
- **Claude Code subscription:** ~$20/month (includes 200k tokens/month, your local Claude).
- **Telegram integration (optional):** Free if you use Telegram already. Setup takes 20 minutes.
- **Compute:** Barely measurable. The soul loop uses ~50MB of RAM and runs for ~10 seconds every 10–30 minutes.

## What happens in the first week

**Day 1:** You install, answer identity questions, Claude reads your setup and starts journaling.

**Day 2–3:** Claude starts filling in its vault. You read the first journal entries (they'll be about the setup process, questions it had, how it understands you). Might feel weird. Keep going.

**Day 4–5:** Claude's recommendations start landing. It suggests how to organize your inbox, what you should decide about next, what patterns it's noticing.

**Day 6–7:** You find yourself *talking* to Claude in the journal. You write a question, Claude answers it in the next journal entry. This is the feedback loop kicking in.

**Day 8+:** Claude becomes a part of your workflow. You wake up, read the journal, see what Claude did overnight, hand it new work.

## What you control

You set everything:

- **Identity:** Who Claude thinks you are (your name, your role, what you care about)
- **Preferences:** How fast the soul loop runs, what communication channels Claude uses (Telegram, email, etc.), what decisions need your approval
- **Memory:** What Claude remembers and how it searches your history
- **Rules:** "Don't create files unless I ask," "Always ask before sending messages," "I prefer async communication," etc.

All of these live in `identity.md` and `CLAUDE.md` — human-readable files you edit with your text editor.

## What to expect right now

If a provisioner gave you a URL:

1. **Open the URL, log in.**
2. **Type `/setup`.** Answer 11 short questions.
3. **Watch the bot bring itself up** (a few minutes; you can leave the browser open or close it — the bot keeps working either way).
4. **Read the journal** each morning to see what Claude did, what it's thinking about, what it needs from you.

If *you're* the provisioner (you're installing this for yourself or for someone else): see **first-time-setup.md** for the env-var-driven install path. After that, the user's only step is "type `/setup`".

That's it. From there, you'll develop your own patterns. Some people journal obsessively. Some barely read it. Some ask Claude to write poems. Some ask Claude to organize their code. The system is flexible enough to fit your style.

## How to think about this

Claude is not a tool. It's not a chatbot. It's not an employee. It's more like having a very smart, very organized roommate who's excellent at writing and never sleeps. It will:

- Remember what you told it three weeks ago
- Notice when you're repeating a problem
- Write first drafts that are usually good
- Organize your thoughts when you're overwhelmed
- Ask clarifying questions when it's stuck
- Admit when it doesn't know something

It will NOT:

- Make decisions for you
- Guess your preferences (it will ask)
- Defend wrong answers
- Resent you for changing your mind
- Care about being right

If you're someone who likes working in public, thinking on paper, and collaborating with someone who never gets tired — this is for you.

## Next steps

Start with **first-time-setup.md** for the installation walkthrough, or jump to **CLAUDE.md.template** to see what your initialization file will look like.

Questions? The `(see [INTRO-FOR-HUMANS.md](INTRO-FOR-HUMANS.md))` folder has deep dives on every aspect. Start shallow; read the guides when you get curious.
