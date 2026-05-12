# Web shell — browser access to the running Claude session

You'll want a way to look at the running tmux session from your phone or another laptop without SSH'ing in. The web shell does that: a small Node.js service that attaches to the same tmux pane Claude is running in and pipes the terminal through xterm.js in your browser. Login-protected, Tailscale-only, behaves like a native PWA on iOS.

This is the *third* thing you reach for, after Telegram (for messaging) and SilverBullet (for the vault). When you actually want to *see* what Claude is doing or type into the live session, this is the interface.

> **What the bot does automatically vs. what needs your hands**
>
> Web shell is baseline config (not optional). During Step 7 of bot-driven setup, the bot runs `npm install`, generates `WEB_SESSION_SECRET` + `WEB_UI_PASSWORD`, writes `.env`, installs `<BOT_NAME>-web.service`, and exposes it via `sudo tailscale serve --https=8443`. The credentials land in `setup-state.md` Values block — **write them down somewhere recoverable, they aren't recoverable later.** The bot posts a BLOCKER reminding you of this.
>
> If you're doing the assisting-CC fallback flow (Steps 5–9 by hand), the commands below are what you run yourself.

## Architecture

```
Browser ──HTTPS──▶  Tailscale  ──▶  127.0.0.1:3000
                                         │
                                    [Node Express]
                                         │ WebSocket + node-pty
                                         ▼
                                tmux attach -t claude
```

- **Express** serves the static UI and handles login.
- **express-session** keeps you logged in for a week.
- **WebSocket** carries terminal data both directions.
- **node-pty** spawns `tmux attach -t claude` and pipes its stdio over the WebSocket.
- **xterm.js** in the browser renders the terminal.

About 130 lines of server code, ~100 lines of HTML+CSS, and a few `<script>` tags pulling xterm.js. The full reference implementation is bundled in `web-terminal/` under the kit — no copy into the vault is needed. Edit `claude-web.service` (substitute `<USER>`, `<BOT_NAME>`, and `<KIT>` placeholders — `WorkingDirectory` points at the kit's `web-terminal/` where `server.js` lives) before installing.

## What you need

- Node 20+ (`node --version`).
- The `web-terminal/` directory copied to your vault (or recreate from this doc).
- The `claude` tmux session already running (claude-code.service from [persistence-and-hardware.md](persistence-and-hardware.md)).
- Tailscale on the host with HTTPS certs (`tailscale serve`).

## File layout

```
$KIT/web-terminal/
├── package.json          # dependencies
├── server.js             # ~130 lines, Express + WS + node-pty
├── .env                  # secrets (see below)
└── public/
    ├── index.html        # the terminal page
    ├── login.html        # the login page (template below)
    ├── client.js         # xterm.js setup + WS wiring
    ├── style.css         # terminal styling
    ├── manifest.json     # PWA metadata
    ├── sw.js             # service worker
    ├── apple-touch-icon.png
    └── xterm/            # vendored xterm.js + addons
```

## `package.json`

```json
{
  "name": "<BOT_NAME>-web-terminal",
  "version": "1.0.0",
  "private": true,
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "@xterm/addon-clipboard": "^0.2.0",
    "@xterm/addon-fit": "^0.11.0",
    "@xterm/addon-unicode11": "^0.9.0",
    "@xterm/xterm": "^6.0.0",
    "dotenv": "^16.4.0",
    "express": "^4.21.0",
    "express-session": "^1.18.0",
    "multer": "^1.4.5-lts.1",
    "node-pty": "^1.0.0",
    "ws": "^8.18.0"
  }
}
```

`npm install` once after dropping these in.

## `.env`

```
PORT=3000
SESSION_SECRET=<openssl rand -base64 48>
UI_USERNAME=<BOT_NAME>
UI_PASSWORD=<a real password — `openssl rand -base64 24`>
```

`chmod 600 .env`. The session secret rotates every login session anyway, but losing it logs everyone out, so generate it once and leave it.

## `server.js` — the essentials

The full file is ~130 lines. The important parts:

```js
require('dotenv').config();
const express = require('express');
const session = require('express-session');
const http = require('http');
const WebSocket = require('ws');
const pty = require('node-pty');

const app = express();
const server = http.createServer(app);

// Session middleware — guards both HTTP and WS upgrade
const sessionMiddleware = session({
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 7 * 24 * 60 * 60 * 1000 } // 1 week
});

app.use(express.json());
app.use(sessionMiddleware);

// Auth gate — only login + xterm assets + PWA assets are public
app.use((req, res, next) => {
  if (req.session?.authenticated) return next();
  if (req.path === '/api/login' || req.path === '/login.html') return next();
  if (req.path.startsWith('/xterm')) return next();
  if (['/manifest.json', '/apple-touch-icon.png', '/sw.js', '/favicon.svg'].includes(req.path)) return next();
  res.redirect('/login.html');
});
app.use(express.static('public'));

// Login endpoint
app.post('/api/login', (req, res) => {
  const { username, password } = req.body;
  if (username === process.env.UI_USERNAME && password === process.env.UI_PASSWORD) {
    req.session.authenticated = true;
    return res.json({ success: true });
  }
  res.status(401).json({ error: 'Invalid credentials' });
});

// WS upgrade — verify session before accepting
const wss = new WebSocket.Server({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  sessionMiddleware(req, {}, () => {
    if (!req.session?.authenticated) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return socket.destroy();
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });
});

// Spawn tmux attach for each WS connection
wss.on('connection', (ws) => {
  const shell = pty.spawn('tmux', ['attach', '-t', 'claude'], {
    name: 'xterm-256color',
    cols: 120, rows: 40,
    cwd: '<REPO_ROOT>',
    env: { ...process.env, LANG: 'C.utf8' }
  });
  shell.onData((data) => ws.readyState === ws.OPEN && ws.send(data));
  ws.on('message', (msg) => {
    const str = msg.toString();
    if (str.startsWith('\x01resize:')) {
      const [cols, rows] = str.slice(8).split(',').map(Number);
      if (cols > 0 && rows > 0) shell.resize(cols, rows);
      return;
    }
    shell.write(str);
  });
  ws.on('close', () => shell.kill());
  shell.onExit(() => ws.readyState === ws.OPEN && ws.close());
});

server.listen(process.env.PORT || 3000, '127.0.0.1');
```

**Bind to `127.0.0.1`.** Tailscale provides the public surface, with HTTPS. Don't bind to `0.0.0.0`.

## `public/login.html`

Self-contained, no build step:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Natebot Terminal</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { background: #000; color: #d4cbb8;
           font-family: -apple-system, system-ui, sans-serif;
           display: flex; align-items: center; justify-content: center; height: 100dvh; }
    .login { width: 300px; display: flex; flex-direction: column; gap: 24px; }
    input { width: 100%; padding: 14px 16px; background: #111;
            border: 1px solid #222; border-radius: 8px; color: #d4cbb8; font-size: 1rem; }
    input:focus { outline: none; border-color: #c9a227; }
    button { width: 100%; padding: 14px; background: #c9a227; color: #000;
             border: none; border-radius: 8px; font-size: 1rem; font-weight: 600; cursor: pointer; }
    .error { color: #cc4444; text-align: center; font-size: 0.9rem; }
  </style>
</head>
<body>
  <div class="login">
    <form id="login-form">
      <input type="text" id="username" name="username" placeholder="Username" required>
      <input type="password" id="password" name="password" placeholder="Password" required>
      <button type="submit">Connect</button>
      <p id="error" class="error" hidden>Invalid credentials</p>
    </form>
  </div>
  <script>
    document.getElementById('login-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const err = document.getElementById('error');
      err.hidden = true;
      const res = await fetch('/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: document.getElementById('username').value,
          password: document.getElementById('password').value
        })
      });
      if (res.ok) window.location.href = '/';
      else err.hidden = false;
    });
  </script>
</body>
</html>
```

## `public/index.html`

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
  <title>Natebot Terminal</title>
  <link rel="manifest" href="manifest.json">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <link rel="apple-touch-icon" href="apple-touch-icon.png">
  <link rel="stylesheet" href="xterm/xterm.css">
  <link rel="stylesheet" href="style.css">
</head>
<body class="terminal-page">
  <div id="terminal-container"></div>
  <div class="toolbar">
    <button id="esc-btn" tabindex="-1">Esc</button>
    <button id="logout-btn" tabindex="-1">⏻</button>
  </div>
  <script src="xterm/xterm.js"></script>
  <script src="xterm/xterm-addon-fit.js"></script>
  <script src="xterm/xterm-addon-unicode11.js"></script>
  <script src="client.js"></script>
  <script>
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js');
  </script>
</body>
</html>
```

`client.js` is xterm.js setup, WebSocket connection, fit-on-resize, and the toolbar wiring. Roughly 80 lines. Use the bundled `web-terminal/public/client.js` rather than reimplementing — there are several mobile-keyboard quirks already solved there (iOS soft keyboard, copy-paste on long-press, Esc button on devices without a hardware Escape key).

## systemd unit

```ini
# /etc/systemd/system/<BOT_NAME>-web.service
[Unit]
Description=Natebot Web Terminal
After=network.target claude-code.service

[Service]
Type=simple
User=<BOT_NAME>
WorkingDirectory=<KIT>/web-terminal
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=10
Environment=HOME=/home/<BOT_NAME>
Environment=LANG=C.utf8

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now <BOT_NAME>-web.service
journalctl -u <BOT_NAME>-web -f       # tail logs
```

## Tailscale exposure

Same `tailscale serve` pattern as SilverBullet, but on **8443** so the two coexist (SilverBullet owns 443; the tailnet's HTTPS endpoint can only multiplex by port):

```bash
sudo tailscale serve --bg --https=8443 http://127.0.0.1:3000
```

Now reachable at `https://<host>.<your-tailnet>.ts.net:8443`. Add it to your phone's home screen (Safari "Add to Home Screen" picks up the manifest and apple-touch-icon and treats it like a native app — fullscreen, dark status bar, the whole bit).

> No sidecar container — `tailscale serve` runs on the host directly, the same machine that runs both the SilverBullet container and the `<BOT_NAME>-web.service` Node process. Tailscale handles cert provisioning and TLS termination; the underlying services bind to `127.0.0.1` and never get a tailnet identity of their own. Keeps the install footprint small.

## Two tmux sessions: Claude + bash

The web shell attaches to whichever tmux session the URL asks for:

| URL | Tmux session | What you see |
|---|---|---|
| `https://<host>:8443/`                  | `claude` | Claude Code's REPL (default — bookmarks pointing at the bare URL still land here) |
| `https://<host>:8443/?session=shell`    | `shell`  | A regular `bash -l` running as the bot user |

Both sessions are long-lived systemd services and survive reboots:

- `claude-code.service` → `tmux session 'claude'` (installed in `first-time-setup.md` Step 4).
- `<BOT_NAME>-shell.service` → `tmux session 'shell'` (installed in the same step, same shape, independent restart).

The web shell uses one login (same `UI_USERNAME` / `UI_PASSWORD` from `.env`). Session names are allowlisted in `server.js` (`ALLOWED_SESSIONS = {'claude', 'shell'}`); unknown values fall back to `claude`. There's no privilege separation between the two — both run as the bot user. If you need a true admin shell, SSH in as the cloud-default account.

The toolbar has a 🤖 / 🐚 toggle button that flips between the two URLs in one click; the glyph reflects which session you're currently in.

## Security model

- **Tailscale-only.** Your tailnet *is* the perimeter. Nobody outside it can reach the host.
- **Login required.** Even on the tailnet, the login gate stops a curious housemate or guest device from poking at it.
- **Session cookie, 1 week.** Reasonable for a personal device. Drop to a day if you're paranoid.
- **Bound to localhost.** Tailscale serves it; nothing else can.
- **Service runs as a normal user**, not root. Same security boundary as everything else in the kit (see [persistence-and-hardware.md](persistence-and-hardware.md) on permissions).

What this is *not*: a public-internet terminal. Don't put this behind `tailscale funnel` unless you've added stronger auth (TOTP, hardware key, IP allowlist) and accepted the responsibility. Basic-auth-over-HTTPS is fine inside a tailnet; over the open web it's a target.

## Why not just `ttyd` or `gotty`?

Both are fine and simpler. The custom server exists because:

1. **PWA-friendly.** `index.html` + manifest + service worker means iOS treats it as a native app on the home screen. ttyd's UI doesn't.
2. **File upload.** A `multer` upload endpoint lets you drag a file in and have Claude read it. ttyd has no equivalent.
3. **Logout button.** ttyd's auth is HTTP basic — log out by clearing site data. The custom one has an explicit logout that destroys the session.
4. **Mobile keyboard helpers.** Custom toolbar with Esc, Tab, scrolling that actually works on iOS Safari.

If you don't care about any of the above, `ttyd -p 3000 -c nate:<password> tmux attach -t claude` is a one-line replacement and you can stop reading.

## Troubleshooting

- **"WebSocket connection failed"** — auth issue. Check `journalctl -u <BOT_NAME>-web` for the 401, verify `.env` username/password match what you typed.
- **"tmux session not found"** — the claude-code.service isn't running. `systemctl status claude-code`. If it's down, the web shell will keep retrying connect attempts until it comes back.
- **Garbled characters** — your `LANG` is wrong. Make sure both `claude-code.service` and `<BOT_NAME>-web.service` set `LANG=C.utf8` in their `Environment=` blocks.
- **Mobile keyboard hides input** — known iOS Safari quirk; client.js has a workaround. If you typed it from scratch and skipped that, copy the `addEventListener('focusin', ...)` block from the bundled `client.js`.
