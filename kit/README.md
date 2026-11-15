# Persistent Claude Code bot kit, v2

This kit sets up a Claude Code session that runs all the time on a small Linux box, keeps its memory in a folder of Markdown files, and is reached over a private Tailscale network. It is a genericised copy of a system called fenbot that has run this way since March 2026. The files under `templates/` are copies of that system's real scripts and prompts with names, hosts and paths replaced by `${PLACEHOLDER}`s.

It is written for someone comfortable with Linux, systemd, Docker and cron who has not seen this system before.

## What you end up with

- **A Claude Code session in tmux**, started by systemd, resumed with `--continue` after a restart.
- **A vault**: one directory that is the bot's working directory, a git repo, and a SilverBullet space at the same time. Journals, tasks, decisions and the bot's own instructions live there as plain files.
- **SilverBullet 2.x** as the browser interface to the vault. You read the journal there, leave tasks there, and ask the bot questions inline on any page.
- **Tailscale** as the only way in. SilverBullet and a web terminal are published with `tailscale serve` under their own HTTPS hostnames, visible only on your tailnet.
- **System crons** that wake the session without typing into it. A shell script decides whether there is work. Only then is a subagent spawned, on a cheaper model, in its own context.
- **Three memory layers**: the vault with grep, a local vector store (memorious), and Claude Code's own auto-memory.

## The moving parts

```
 cron (system crontab)
   └─ cron-prompts/cron-wake.sh <name>
        └─ cron-prompts/gates/<name>.sh        shell only, 0 tokens
             ├─ exit 10 → rest. One line in job-log.md. Nothing else happens.
             └─ exit 0  → writes .cron-triggers/<name>  (stdout = context)
                              │
 bin/cron-trigger-monitor.sh  │  background task inside the Claude session
   polls .cron-triggers/ every 5 s
   session busy → leave the file, try again next pass
   session idle → print "CRON <name> <context>", delete the file, exit
                              │
 main Claude session  ◄───────┘  the exit is a notification, not keystrokes
   └─ routes by name (processes/cron-wake-path.md)
        ├─ soul-loop            → soul-loop-runner     (haiku)
        ├─ secretary            → secretary            (haiku)
        ├─ wake-up              → wake-up-runner       (haiku)
        ├─ midnight-maintenance → journal-synthesizer  (sonnet)
        └─ sb-mentions          → no runner; the main session reads the mention
```

```
 you (browser, phone)                     the box
   │                                        │
   │  https://${BOT_NAME}-notes.${TAILNET}.ts.net ──► tailscale serve ──► 127.0.0.1:${SB_PORT}  SilverBullet
   │  https://${BOT_NAME}-shell.${TAILNET}.ts.net ──► tailscale serve ──► 127.0.0.1:${TERM_PORT}  web terminal ──► tmux "claude"
   │                                        │
   └─ tailnet only, HTTPS certs from Tailscale        SilverBullet ◄──► ${VAULT_DIR} ◄──► Claude Code
                                                       (bind mount)      (plain files)   (cwd)
```

Both services listen on localhost only. There is no reverse proxy and nothing is exposed to the internet.

## What it costs to run idle

Measured on the source system from its `cron-prompts/job-log.md`, 2026-10-01 to 2026-11-14. Token figures are the `total_tokens` each subagent reported. They leave out the main session's own cost of routing a notification, which the log does not record.

| Job | Cron fires | Subagent runs | Average tokens per run |
|---|---|---|---|
| soul-loop | 6,389 | 51 | 35,700 |
| secretary | 2,108 | 83 | 46,700 |
| wake-up | 29 | 24 | 45,700 |
| midnight-maintenance | 39 | 33 | 50,000 |

A cron fire that the gate turns away costs no tokens. That is 99% of soul-loop fires and 96% of secretary fires in that window. When nobody is talking to the bot and no tasks are open, the soul loop backs off to one run a day, the secretary does not run, and the fixed cost is the morning wake-up and the midnight journal job.

The box is a Debian 13 LXC with 2 cores, 4 GB RAM and a 16 GB disk. The SilverBullet container sat at about 470 MB with its headless Chrome running. You need a Claude subscription or API billing that covers a long-lived Claude Code session; this kit does not measure that side.

## Read in this order

1. [first-time-setup.md](first-time-setup.md): zero to running on a Debian LXC or VM.
2. [tailscale.md](tailscale.md): joining the tailnet, `tailscale serve`, tags, gotchas.
3. [silverbullet.md](silverbullet.md): install, the Runtime API, and the vault conventions (mentions, due dates, handoffs).
4. [wake-path.md](wake-path.md): crons, gates, the trigger poller, runner agents, `/start`.
5. [memory.md](memory.md): the three layers and when to use each.
6. [operating.md](operating.md): restarts, upgrades, snapshots, troubleshooting.
7. [telegram.md](telegram.md): optional phone channel.
8. [claudeberry.md](claudeberry.md): a stub for a project that is not built yet.

## What is not in this kit

- Anything multi-bot. The source system also runs a shared chat channel between several bots. None of that is here, and the launcher template starts Claude Code directly.
- Monitoring, metrics and homelab scripts.
- A daily creative runner. The source system has one more scheduled agent that writes a short piece every night from yesterday's journal. If you want something like it, add a crontab line with no gate, an agent file under `.claude/agents/`, and a row in the routing table. Make sure it checks that yesterday's daily file exists first, because the idle gate can deliver it and the midnight job back to back.

## Conventions in these docs

- `${NAME}` is a placeholder. `templates/kit.env.example` lists all of them and `templates/render.sh` fills them in.
- `TODO(verify)` marks a step that could not be checked against the running system. Treat it as a pointer to upstream docs, not as an instruction.
- Dates like 2026-09-22 in script comments are when the source system learned something. They are kept because the reason for a line is usually in that comment.
