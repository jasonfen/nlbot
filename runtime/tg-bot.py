#!/usr/bin/env python3
"""Telegram Bot — single daemon handling inbound polling and outbound sending."""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_FILE = SCRIPT_DIR / "config"
MSG_FILE = SCRIPT_DIR / "message.txt"
TRIGGER_FILE = SCRIPT_DIR / "new-messages.txt"
OFFSET_FILE = SCRIPT_DIR / ".last-update-id"
POLL_TIMEOUT = 5  # seconds — short so we check outbound frequently


def load_config():
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, val = line.split("=", 1)
                config[key.strip()] = val.strip()
    return config


def api_call(token, method, data=None):
    url = f"https://api.telegram.org/bot{token}/{method}"
    if data is not None:
        payload = json.dumps(data).encode()
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    else:
        req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        print(f"API error {e.code}: {body}", file=sys.stderr)
        return None
    except (urllib.error.URLError, OSError) as e:
        print(f"Network error: {e}", file=sys.stderr)
        return None


def send_message(token, chat_id, text):
    """Send a message, splitting if over 4096 chars."""
    max_len = 4096
    parts = []
    while len(text) > max_len:
        # Try to split on paragraph break
        idx = text.rfind("\n\n", 0, max_len)
        if idx == -1:
            idx = text.rfind("\n", 0, max_len)
        if idx == -1:
            idx = max_len
        parts.append(text[:idx])
        text = text[idx:].lstrip("\n")
    parts.append(text)

    for part in parts:
        if not part.strip():
            continue
        result = api_call(token, "sendMessage", {"chat_id": chat_id, "text": part})
        if result and not result.get("ok"):
            print(f"sendMessage failed: {result}", file=sys.stderr)
        if len(parts) > 1:
            time.sleep(0.5)


def check_outbound(token, chat_id):
    """Check for message.txt and send if present."""
    if not MSG_FILE.exists():
        return
    try:
        # Atomic read-and-delete: rename first so hooks don't race
        tmp = MSG_FILE.with_suffix(".sending")
        try:
            MSG_FILE.rename(tmp)
        except FileNotFoundError:
            return  # Hook already grabbed it
        text = tmp.read_text().strip()
        tmp.unlink(missing_ok=True)
        if text:
            send_message(token, chat_id, text)
    except Exception as e:
        print(f"Outbound error: {e}", file=sys.stderr)


def load_offset():
    try:
        return int(OFFSET_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return 0


def save_offset(offset):
    OFFSET_FILE.write_text(str(offset))


def inject_telegram_check():
    """Best-effort: inject /telegram-check into Claude's tmux session."""
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", "claude", "/telegram-check", "Enter"],
            capture_output=True, timeout=5
        )
    except Exception:
        pass  # FileChanged hook is the primary trigger


def process_updates(token, chat_id, updates):
    """Process inbound updates, write to trigger file."""
    messages = []
    for update in updates:
        msg = update.get("message", {})
        if not msg:
            continue
        # Security: whitelist chat_id
        if str(msg.get("chat", {}).get("id")) != str(chat_id):
            print(f"Rejected message from chat_id {msg.get('chat', {}).get('id')}", file=sys.stderr)
            continue
        text = msg.get("text", "")
        if not text:
            continue
        ts = datetime.fromtimestamp(msg["date"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        first_name = msg.get("from", {}).get("first_name", "Unknown")
        messages.append(f"[{ts}] {first_name}: {text}")

    if messages:
        with open(TRIGGER_FILE, "a") as f:
            for line in messages:
                f.write(line + "\n")
        inject_telegram_check()


def main():
    config = load_config()
    token = config["BOT_TOKEN"]
    chat_id = config["CHAT_ID"]

    print(f"Telegram bot starting — polling as @{config.get('BOT_USERNAME', 'unknown')}")
    print(f"Whitelisted chat_id: {chat_id}")

    offset = load_offset()

    while True:
        try:
            # Check outbound first (fast)
            check_outbound(token, chat_id)

            # Long-poll inbound
            params = {"offset": offset, "timeout": POLL_TIMEOUT, "allowed_updates": ["message"]}
            result = api_call(token, "getUpdates", params)

            if result and result.get("ok") and result.get("result"):
                updates = result["result"]
                process_updates(token, chat_id, updates)
                offset = updates[-1]["update_id"] + 1
                save_offset(offset)

        except KeyboardInterrupt:
            print("\nShutting down.")
            break
        except Exception as e:
            print(f"Loop error: {e}", file=sys.stderr)
            time.sleep(5)


if __name__ == "__main__":
    main()
