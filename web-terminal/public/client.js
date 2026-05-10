/* global Terminal, FitAddon */

(function () {
  const termContainer = document.getElementById('terminal-container');
  const fileInput = document.getElementById('file-input');

  // xterm.js setup
  const term = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', Menlo, monospace",
    theme: {
      background: '#12100e',
      foreground: '#d4cbb8',
      cursor: '#c9a227',
      selectionBackground: '#c9a22744',
      black: '#12100e',
      brightBlack: '#2a2520',
      white: '#d4cbb8',
      brightWhite: '#f0e8d8'
    },
    allowProposedApi: true
  });

  const fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  const unicode11Addon = new Unicode11Addon.Unicode11Addon();
  term.loadAddon(unicode11Addon);
  term.unicode.activeVersion = '11';
  // OSC 52 clipboard — intercept tmux yank, store it, copy button grabs it.
  // Browser clipboard API requires user gesture on iOS, so we can't write
  // directly from the WebSocket data path. Instead: capture OSC 52 content
  // and auto-copy on the next copy button tap.
  let lastOsc52 = '';
  term.parser.registerOscHandler(52, (data) => {
    const parts = data.split(';');
    if (parts.length >= 2 && parts[1] !== '?') {
      try {
        lastOsc52 = atob(parts[1]);
        // Try clipboard API (works on desktop, may fail on iOS without gesture)
        navigator.clipboard.writeText(lastOsc52).catch(() => {});
        // Visual indicator that text was captured
        const copyBtn = document.getElementById('copy-btn');
        if (copyBtn) {
          copyBtn.textContent = '\u2713';
          setTimeout(() => { copyBtn.textContent = '\u2398'; }, 1500);
        }
      } catch (e) {}
    }
    return true;
  });
  term.open(termContainer);
  fitAddon.fit();

  // WebSocket
  let ws;
  let reconnectTimer;

  function connect() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const path = location.pathname.replace(/\/$/, '') || '';
    ws = new WebSocket(`${proto}//${location.host}${path}`);

    ws.onopen = () => {
      const dims = fitAddon.proposeDimensions();
      if (dims) {
        ws.send('\x01resize:' + dims.cols + ',' + dims.rows);
      }
    };

    ws.onmessage = (e) => {
      term.write(e.data);
    };

    ws.onclose = () => {
      term.write('\r\n\x1b[33m[Disconnected — reconnecting...]\x1b[0m\r\n');
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, 3000);
    };

    ws.onerror = () => {
      ws.close();
    };
  }

  connect();

  // Terminal keyboard input (desktop + mobile OS keyboard)
  term.onData((data) => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(data);
    }
  });

  // Resize handling
  function doResize() {
    fitAddon.fit();
    if (ws && ws.readyState === WebSocket.OPEN) {
      const dims = fitAddon.proposeDimensions();
      if (dims) {
        ws.send('\x01resize:' + dims.cols + ',' + dims.rows);
      }
    }
  }

  window.addEventListener('resize', doResize);
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', doResize);
  }

  // On touch devices, don't call term.focus() from buttons — xterm's hidden
  // textarea triggers the iOS keyboard. Users tap the terminal directly to
  // get the OS keyboard when they want it.
  const isTouchDevice = 'ontouchstart' in window;

  document.addEventListener('click', (e) => {
    if (e.target === fileInput) return;
    if (e.target.closest('.tool-btn')) return;
    if (!isTouchDevice) term.focus();
  });

  // Track tmux copy mode for scroll buttons
  let inCopyMode = false;

  // Scroll controls (sends tmux copy-mode sequences)
  const scrollUp = document.getElementById('scroll-up');
  const scrollDown = document.getElementById('scroll-down');
  const scrollBottom = document.getElementById('scroll-bottom');

  scrollUp.addEventListener('click', () => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    if (!inCopyMode) {
      ws.send('\x02[');
      inCopyMode = true;
      setTimeout(() => { ws.send('\x1b[5~'); }, 100); // PgUp
    } else {
      ws.send('\x1b[5~'); // PgUp
    }
    if (!isTouchDevice) term.focus();
  });

  scrollDown.addEventListener('click', () => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    if (inCopyMode) {
      ws.send('\x1b[6~'); // PgDn
    }
    if (!isTouchDevice) term.focus();
  });

  scrollBottom.addEventListener('click', () => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    if (inCopyMode) {
      ws.send('q');
      inCopyMode = false;
    }
    term.scrollToBottom();
  });

  // Escape — exits search, copy mode, goto line, etc.
  document.getElementById('esc-btn').addEventListener('click', () => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send('\x1b'); // ESC
    if (inCopyMode) inCopyMode = false;
  });

  // Copy button — uses xterm selection first, falls back to last OSC 52 capture
  const copyBtn = document.getElementById('copy-btn');
  copyBtn.addEventListener('click', async () => {
    const text = term.getSelection() || lastOsc52;
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
    } catch (e) {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
    }
    copyBtn.textContent = '\u2713';
    setTimeout(() => { copyBtn.textContent = '\u2398'; }, 1000);
  });

  // Logout
  document.getElementById('logout-btn').addEventListener('click', async () => {
    const basePath = location.pathname.replace(/\/$/, '') || '';
    await fetch(`${basePath}/api/logout`, { method: 'POST' });
    window.location.href = `${basePath}/login.html`;
  });

  // File upload
  fileInput.addEventListener('change', async () => {
    const file = fileInput.files[0];
    if (!file) return;
    const form = new FormData();
    form.append('file', file);
    try {
      const basePath = location.pathname.replace(/\/$/, '') || '';
      const res = await fetch(`${basePath}/api/upload`, { method: 'POST', body: form });
      if (res.ok) {
        const { path } = await res.json();
        // Type the path directly into the terminal
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(path);
        }
      }
    } catch (e) {
      console.error('Upload failed:', e);
    }
    fileInput.value = '';
  });
})();
