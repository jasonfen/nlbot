require('dotenv').config();
const express = require('express');
const session = require('express-session');
const http = require('http');
const WebSocket = require('ws');
const pty = require('node-pty');
const multer = require('multer');
const path = require('path');
const fs = require('fs');

const app = express();
const server = http.createServer(app);

const UPLOAD_DIR = '/tmp/claude-uploads';
fs.mkdirSync(UPLOAD_DIR, { recursive: true });

// Session middleware
const sessionMiddleware = session({
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 7 * 24 * 60 * 60 * 1000 } // 1 week
});

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(sessionMiddleware);

// Tmux session selector. The web-shell attaches to whichever named tmux
// session the client requests via `?session=...`. Hard allowlist — never
// pass arbitrary user input to `tmux -t`, even after auth.
const ALLOWED_SESSIONS = new Set(['claude', 'shell']);
const DEFAULT_SESSION = 'claude';

function parseSession(req) {
  try {
    const u = new URL(req.url, 'http://localhost');
    const s = u.searchParams.get('session') || DEFAULT_SESSION;
    return ALLOWED_SESSIONS.has(s) ? s : DEFAULT_SESSION;
  } catch (_e) {
    return DEFAULT_SESSION;
  }
}

// Auth middleware
function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) return next();
  if (req.path === '/api/login' || req.path === '/login.html') return next();
  // Allow xterm.js and addon assets without auth (they're just static JS)
  if (req.path.startsWith('/xterm')) return next();
  // Allow PWA assets without auth (needed for iOS home screen icon)
  if (req.path === '/manifest.json' || req.path === '/apple-touch-icon.png' || req.path === '/sw.js' || req.path === '/favicon.svg') return next();
  res.redirect('/login.html');
}

app.use(requireAuth);
app.use(express.static(path.join(__dirname, 'public')));

// Login
app.post('/api/login', (req, res) => {
  const { username, password } = req.body;
  if (username === process.env.UI_USERNAME && password === process.env.UI_PASSWORD) {
    req.session.authenticated = true;
    res.json({ success: true });
  } else {
    res.status(401).json({ error: 'Invalid credentials' });
  }
});

// Logout
app.post('/api/logout', (req, res) => {
  req.session.destroy();
  res.json({ success: true });
});

// File upload
const upload = multer({ dest: UPLOAD_DIR, limits: { fileSize: 50 * 1024 * 1024 } });
app.post('/api/upload', upload.single('file'), (req, res) => {
  if (!req.session || !req.session.authenticated) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  if (!req.file) return res.status(400).json({ error: 'No file' });
  // Rename to preserve original extension
  const ext = path.extname(req.file.originalname);
  const newPath = req.file.path + ext;
  fs.renameSync(req.file.path, newPath);
  res.json({ path: newPath, name: req.file.originalname });
});

// WebSocket server
const wss = new WebSocket.Server({ noServer: true });

// Validate session on WebSocket upgrade
server.on('upgrade', (req, socket, head) => {
  sessionMiddleware(req, {}, () => {
    if (!req.session || !req.session.authenticated) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req);
    });
  });
});

wss.on('connection', (ws, req) => {
  // Pick the tmux session from the upgrade URL's ?session=... query string.
  // Falls back to DEFAULT_SESSION for missing/unknown values (allowlist).
  const sessionName = parseSession(req);

  // Attach to the requested tmux session via PTY
  const shell = pty.spawn('tmux', ['attach', '-t', sessionName], {
    name: 'xterm-256color',
    cols: 120,
    rows: 40,
    cwd: process.env.VAULT_DIR || process.env.HOME,
    env: { ...process.env, LANG: 'C.utf8', PATH: (process.env.HOME + '/.local/bin:') + process.env.PATH }
  });

  shell.onData((data) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(data);
    }
  });

  ws.on('message', (msg) => {
    const str = msg.toString();
    // Handle resize messages
    if (str.startsWith('\x01resize:')) {
      try {
        const [cols, rows] = str.slice(8).split(',').map(Number);
        if (cols > 0 && rows > 0) shell.resize(cols, rows);
      } catch (e) { /* ignore bad resize */ }
      return;
    }
    shell.write(str);
  });

  ws.on('close', () => {
    shell.kill();
  });

  shell.onExit(() => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.close();
    }
  });
});

const PORT = parseInt(process.env.PORT) || 3000;
server.listen(PORT, '127.0.0.1', () => {
  console.log(`Claude web terminal running on http://127.0.0.1:${PORT}`);
});
