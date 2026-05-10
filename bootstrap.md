# EC2 bootstrap

A pre-flight checklist for a fresh EC2 (or any clean Debian/Ubuntu box). This covers everything you need **before** `claude` exists on the machine — system packages, locale, Node, Docker, the kit itself. By the end you'll be ready to follow [`first-time-setup.md`](first-time-setup.md) from Step 1.

## Assumptions

- Ubuntu 22.04+ or Debian 12+. (Amazon Linux works too with `dnf` substituted for `apt`; flag in your head.)
- You're logged in either as root or as the cloud's default user (`ubuntu` on Ubuntu AMIs, `admin` on Debian AMIs, `ec2-user` on Amazon Linux).
- **Tailscale is already installed and logged in.** (`tailscale status` should show your tailnet.)
- Outbound HTTPS works (default on every cloud VM I've seen, but worth saying out loud).

If your instance is smaller than ~2 GB RAM, do Step 8 (swap) early — Node + Claude Code + Docker get cranky without it.

---

## Step 1 — System update (1 min)

```bash
sudo apt update
sudo apt upgrade -y
```

If you're root and got `sudo: command not found` (some minimal Debian images), install it first:

```bash
apt update && apt install -y sudo
```

Reboot if the kernel updated:

```bash
[ -f /var/run/reboot-required ] && sudo reboot
```

(SSH back in via Tailscale after the reboot if so.)

## Step 2 — Create the bot user (3 min)

Don't run the bot as root or as the cloud's shared default user. Make it a dedicated account so SSH keys, sudoers, group memberships, and crontab live in one tidy `$HOME`.

Pick a username — by convention, the bot's name in lowercase. The walkthrough below uses `nlbot`; substitute your own.

```bash
BOTUSER=nlbot
```

### 2a. Make sure sudo exists

Some minimal Debian cloud images don't ship with `sudo` installed (you log in as root via SSH key instead). Check and install if needed:

```bash
if ! command -v sudo >/dev/null; then
  # Run as root — `apt` directly, no sudo
  apt update && apt install -y sudo
fi
```

### 2b. Create the user, set a password, grant sudo

```bash
sudo adduser --gecos "" $BOTUSER
# adduser will prompt twice for a password — pick a strong one,
# you'll need it whenever the bot user runs sudo
sudo usermod -aG sudo $BOTUSER
```

### 2b.5 — Scoped sudo NOPASSWD (required for bot-driven setup)

After the Step 4 verification reboot in `first-time-setup.md`, the bot drives Steps 5–9 (SilverBullet, Telegram daemon, web shell, cron, memory backend) on its own. It runs `sudo systemctl`, `sudo crontab`, and `sudo docker` from inside a detached tmux session where there's no terminal to type a password into. So either those commands need `NOPASSWD`, or the bot can't self-drive the rest of setup.

Drop a **scoped** NOPASSWD entry — only those three commands, not blanket `NOPASSWD: ALL`:

```bash
sudo tee /etc/sudoers.d/$BOTUSER >/dev/null <<EOF
$BOTUSER ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/crontab, /usr/bin/docker
EOF
sudo chmod 440 /etc/sudoers.d/$BOTUSER
sudo visudo -cf /etc/sudoers.d/$BOTUSER   # should print "parsed OK"
```

Anything else `sudo` (apt-install, editing /etc, etc.) still prompts for the password and stays your job. If you genuinely want **blanket `NOPASSWD: ALL`** (anyone with a shell as $BOTUSER gets root-equivalent — convenient but a bigger blast radius), replace the snippet above with `$BOTUSER ALL=(ALL) NOPASSWD:ALL`. The kit's recommended path is scoped.

### 2c. Copy your SSH key over so you can `ssh $BOTUSER@<host>` directly

This is what lets you skip back to the cloud-default user once you're done with bootstrap. Tailscale's SSH or your existing `authorized_keys` both work.

```bash
sudo install -d -m 700 -o $BOTUSER -g $BOTUSER /home/$BOTUSER/.ssh
sudo cp ~/.ssh/authorized_keys /home/$BOTUSER/.ssh/authorized_keys
sudo chown $BOTUSER:$BOTUSER /home/$BOTUSER/.ssh/authorized_keys
sudo chmod 600 /home/$BOTUSER/.ssh/authorized_keys
```

If you're using Tailscale SSH (`tailscale up --ssh`), you can skip the key-copy entirely — Tailscale handles auth — but copying the key is harmless and gives you a fallback path.

### 2d. Switch to the new user

Everything from Step 3 onward runs as `$BOTUSER`. Open a fresh login shell so group memberships take effect:

```bash
sudo su - $BOTUSER
# from here on, your prompt is $BOTUSER's, and `whoami` returns $BOTUSER
```

(You can also disconnect and `ssh $BOTUSER@<host>` instead. Either way works.)

You'll add the bot user to the `docker` group in Step 6 — that step's `sudo usermod -aG docker $USER` picks up the right user automatically since you're now logged in as `$BOTUSER`.

## Step 3 — Locale (1 min, critical)

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

## Step 4 — Core tools (1 min)

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

## Step 5 — Node.js 20+ (2 min)

Claude Code needs Node 20 or newer. The Ubuntu repo ships an older version, so use NodeSource:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
node --version    # v20.x.y
npm --version
```

## Step 6 — Docker + compose plugin (3 min)

For SilverBullet (the vault editor). Skip only if you're certain you don't want SilverBullet.

```bash
# Detect OS family — Docker has separate repos for ubuntu vs debian.
# (Common gotcha: a Debian box like AWS's Debian-13/'trixie' AMI will fail
# against the ubuntu URL with a 404 on /Release.)
. /etc/os-release
DOCKER_OS=$ID                # 'debian' or 'ubuntu'
DOCKER_CODENAME=$VERSION_CODENAME

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$DOCKER_OS/gpg | \
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/$DOCKER_OS $DOCKER_CODENAME stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add yourself to the docker group so you don't need sudo for `docker`
sudo usermod -aG docker $USER
```

**If apt update fails with `404 Not Found` on the Docker Release file**, your codename probably isn't supported by Docker yet (rare, only happens on bleeding-edge releases). Check what's available at <https://download.docker.com/linux/debian/dists/> or <https://download.docker.com/linux/ubuntu/dists/> and substitute the nearest stable codename for `$DOCKER_CODENAME`.

**Log out and back in** for the group change to take effect, then verify:

```bash
docker compose version    # 'docker compose' (two words, plugin), not 'docker-compose'
docker run --rm hello-world
id -nG | tr ' ' '\n' | grep -x docker    # MUST print 'docker' — confirms group is live in this login
```

The third line is the load-bearing one for the rest of the kit. The bot's `claude-code.service` inherits whatever groups this login has at the time the service starts; if `docker` isn't in this `id` output, the bot will be unable to run `docker compose` once it boots, and Step 5 of `first-time-setup.md` will fail. If it's missing, `exit` the SSH session, reconnect, and re-run the `id` check.

## Step 7 — Claude Code (1 min)

```bash
sudo npm install -g @anthropic-ai/claude-code
claude --version
```

Then log in once **at a real terminal** (not under tmux yet — the TOS gate doesn't render well in detached panes):

```bash
claude
```

Follow the OAuth prompt, accept the TOS, exit.

## Step 8 — Swap file (optional but recommended)

If your instance has less than ~4 GB RAM, give it 2 GB of swap. Skip if you've already got plenty of memory.

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h    # should show ~2G under 'Swap'
```

## Step 9 — Timezone (optional)

The bot's journal entries use the local timezone. Defaults are usually UTC; set explicitly if you want something else:

```bash
sudo timedatectl set-timezone America/New_York   # or your zone
timedatectl
```

## Step 10 — Clone the kit (1 min)

```bash
cd ~
git clone https://github.com/jasonfen/nlbot.git
cd nlbot
ls
```

You should see `README.md`, `first-time-setup.md`, `setup-orchestrator.md`, the `runtime/`, `dot-claude/`, `templates/`, and `web-terminal/` directories.

## Step 11 — Sanity check

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
