# ClaudeBerry (stub)

**Status: planned, not built (2026-11-14).** The hardware is on order on the source system. Every step below marked `TODO` has not been done by anyone connected with this kit. Use the upstream README for build instructions.

Decided so far:
- **What it runs:** Claude Code, logged in with the owner's own account, plus a plain admin shell.
- **Remote access:** through a travel router on the tailnet. Upstream only documents reaching the server directly on TCP 22 (with a `ufw limit` rule), and has no guidance on VPNs or Tailscale. The router approach keeps port 22 closed to the internet.
- **Target host:** a small dedicated container, not the bot's own box. The preset bakes the private key into the app on an old phone, so a lost phone should only expose one user on one host.
- **Voice input:** yes, which needs about 1 GB of extra RAM on the target.
- **One key per device.** A second keyboard device (for example a LILYGO T-Deck Plus running PocketSSH) gets its own key on the same target, so either can be revoked alone.

## What it is

A BlackBerry Bold 9900 (BlackBerry OS 7.1) used as a pocket SSH terminal into a tmux session on a box at home. The app is a Java ME MIDlet with modern SSH crypto.

- Upstream: <https://github.com/0xProbabillity/claudeberry>, a fork of <https://github.com/cobanov/berryssh>. GPL-2.0.
- Per the upstream notes collected so far: no BlackBerry SDK and no code signing are needed, and the build bakes a connection preset (user, host, key) into the app.

## Why it fits this design

Everything in this kit is reached over a tailnet, and the phone cannot run Tailscale. The plan is to put the phone's Wi-Fi behind a small travel router that is itself a tailnet node, so the phone gets a route to the box without any port being opened to the internet. The preset then points at the box's tailnet IP, and a tailnet ACL limits that router to SSH on that one box.

On the box, the phone lands in a dedicated tmux session, the same way the web terminal attaches to the `claude` session.

## Known constraints

From the project notes, not from testing:

- OS 7 or 7.1 only. BB10 and Android BlackBerrys cannot run it.
- No Tailscale client on the phone, and OS 7's TLS cannot reach modern HTTPS.
- Mobile data would need a network the phone still supports and a manual APN. Plan on Wi-Fi.
- The server needs OpenSSH 6.5 or newer.
- A build that contains a preset contains the private key. It should be installed over USB mass storage, never over Wi-Fi or an over-the-air download.

## Placeholders

| Placeholder | Meaning | Status |
|---|---|---|
| `${CLAUDEBERRY_DEVICE}` | The handset, its battery and SD card | `TODO` |
| `${CLAUDEBERRY_ROUTER}` | The travel router that joins the tailnet and routes for the phone | `TODO` |
| `${CLAUDEBERRY_TARGET_HOST}` | The box the phone connects to, by tailnet IP | `TODO` |
| `${CLAUDEBERRY_USER}` | A dedicated unix user on that box | `TODO` |
| `${CLAUDEBERRY_KEY}` | An Ed25519 key used only by the phone | `TODO` |
| `${CLAUDEBERRY_ACL}` | The tailnet rule: router's tag → target host, TCP 22 only | `TODO` |
| `${CLAUDEBERRY_TMUX_SESSION}` | The session the login attaches to | `TODO` |

## Steps

Each of these is a heading without content on purpose.

### Device

`TODO`: which handset, battery condition, SD card.

### Travel router

`TODO`: model, how it joins the tailnet, subnet routing or masquerade, its tag.

### Target host

`TODO`: which box, whether it is the bot's box or a separate one, sshd configured for keys only.

### User and key

`TODO`: create `${CLAUDEBERRY_USER}`, generate `${CLAUDEBERRY_KEY}`, decide how the login reaches `${CLAUDEBERRY_TMUX_SESSION}`.

### ACL

`TODO`: write and test `${CLAUDEBERRY_ACL}`. Confirm the router can reach nothing else.

### Build

`TODO`: follow the upstream README. Not attempted.

### Install and first session

`TODO`.

### Voice

`TODO`: optional speech-to-text on the server side. Not decided.
