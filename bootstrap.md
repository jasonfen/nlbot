# EC2 bootstrap

A pre-flight checklist for a fresh EC2 (or any clean Debian/Ubuntu box). This covers everything you need **before** `claude` exists on the machine — system packages, locale, Node, Docker, the kit itself. By the end you'll be ready to follow [`first-time-setup.md`](first-time-setup.md) from Step 1.

## Assumptions

- Ubuntu 22.04+ or Debian 12+. (Amazon Linux works too with `dnf` substituted for `apt`; flag in your head.)
- You're SSH'd in as `ubuntu` (or another sudoer). Root works but isn't recommended.
- **Tailscale is already installed and logged in.** (`tailscale status` should show your tailnet.)
- Outbound HTTPS works (default on every cloud VM I've seen, but worth saying out loud).

If your instance is smaller than ~2 GB RAM, do Step 7 (swap) early — Node + Claude Code + Docker get cranky without it.

---

## Step 1 — System update (1 min)

```bash
sudo apt update
sudo apt upgrade -y
```

Reboot if the kernel updated:

```bash
[ -f /var/run/reboot-required ] && sudo reboot
```

(SSH back in via Tailscale after the reboot if so.)

## Step 2 — Locale (1 min, critical)

Claude Code uses Unicode box-drawing characters (`❯ ─ ┌`) for its prompt and panes. If the locale isn't right, you'll see `__` or `??` instead and the UI will look broken even though it's working.

```bash
sudo apt install -y locales
sudo locale-gen C.UTF-8 en_US.UTF-8
sudo update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8
```

Verify in a fresh shell (log out and back in):

```bash
locale
echo "❯ ─ ┌"
```

If the second line shows the actual glyphs (not `??`), you're good. If not, see the "Glyph rendering inside tmux" section in [`persistence-and-hardware.md`](persistence-and-hardware.md).

## Step 3 — Core tools (1 min)

```bash
sudo apt install -y \
  git \
  tmux \
  curl \
  jq \
  unzip \
  ca-certificates \
  python3 \
  python3-pip \
  python3-venv \
  build-essential
```

## Step 4 — Node.js 20+ (2 min)

Claude Code needs Node 20 or newer. The Ubuntu repo ships an older version, so use NodeSource:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
node --version    # v20.x.y
npm --version
```

## Step 5 — Docker + compose plugin (3 min)

For SilverBullet (the vault editor). Skip only if you're certain you don't want SilverBullet.

```bash
# Install Docker Engine via the official repo
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add yourself to the docker group so you don't need sudo for `docker`
sudo usermod -aG docker $USER
```

**Log out and back in** for the group change to take effect, then verify:

```bash
docker compose version    # 'docker compose' (two words, plugin), not 'docker-compose'
docker run --rm hello-world
```

## Step 6 — Claude Code (1 min)

```bash
sudo npm install -g @anthropic-ai/claude-code
claude --version
```

Then log in once **at a real terminal** (not under tmux yet — the TOS gate doesn't render well in detached panes):

```bash
claude
```

Follow the OAuth prompt, accept the TOS, exit.

## Step 7 — Swap file (optional but recommended)

If your instance has less than ~4 GB RAM, give it 2 GB of swap. Skip if you've already got plenty of memory.

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h    # should show ~2G under 'Swap'
```

## Step 8 — Timezone (optional)

The bot's journal entries use the local timezone. Defaults are usually UTC; set explicitly if you want something else:

```bash
sudo timedatectl set-timezone America/New_York   # or your zone
timedatectl
```

## Step 9 — Clone the kit (1 min)

```bash
cd ~
git clone https://github.com/jasonfen/nlbot.git
cd nlbot
ls
```

You should see `README.md`, `first-time-setup.md`, `setup-orchestrator.md`, the `runtime/`, `dot-claude/`, `templates/`, and `web-terminal/` directories.

## Step 10 — Sanity check

Run all the prereq checks at once:

```bash
echo "node:       $(node --version)"
echo "claude:     $(claude --version 2>&1 | head -1)"
echo "docker:     $(docker compose version 2>&1 | head -1)"
echo "tmux:       $(tmux -V)"
echo "tailscale:  $(tailscale status --json | jq -r '.BackendState')"
echo "locale:     $(locale | grep ^LANG)"
echo "glyphs:     ❯ ─ ┌    (these should render as actual symbols)"
```

If everything reports cleanly and the glyphs show, you're done with bootstrap.

---

## What's next

You're now in the state that `first-time-setup.md` Step 1 assumes. Two paths:

- **DIY**: open [`first-time-setup.md`](first-time-setup.md) and follow it.
- **CC-assisted**: start a Claude Code session (`claude`) in this directory and tell it: *"read setup-orchestrator.md and walk me through the install."* It'll handle the rest, pausing at every spot that needs your eyes (BotFather token, password choices, sudo prompts, etc.).

Either way, expect about 30 minutes from here to a running bot.
