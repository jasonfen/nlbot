# EC2 bootstrap

A pre-flight checklist for a fresh EC2 (or any clean Debian/Ubuntu box). This covers everything you need **before** `claude` exists on the machine — system packages, locale, Node, Docker, the kit itself. By the end you'll be ready to follow [`first-time-setup.md`](first-time-setup.md) from Step 1.

## Assumptions

- Ubuntu 22.04+ or Debian 12+. (Amazon Linux works too with `dnf` substituted for `apt`; flag in your head.)
- You're logged in either as root or as the cloud's default user (`ubuntu` on Ubuntu AMIs, `admin` on Debian AMIs, `ec2-user` on Amazon Linux).
- **Tailscale is already installed and logged in.** (`tailscale status` should show your tailnet.)
- Outbound HTTPS works (default on every cloud VM I've seen, but worth saying out loud).

If your instance is smaller than ~2 GB RAM, the script's Step 8 (swap) handles it automatically.

---

## TL;DR

```bash
# 1. As root or cloud-default user, update + install git, clone the kit.
sudo apt update
sudo apt install -y sudo git
git clone https://github.com/jasonfen/nlbot.git ~/nlbot

# 2. Create the bot user — interactive, one prompt per stage. See Step 2.
BOTUSER=nlbot
sudo adduser --gecos "" $BOTUSER
sudo usermod -aG sudo $BOTUSER
sudo install -d -m 700 -o $BOTUSER -g $BOTUSER /home/$BOTUSER/.ssh
sudo cp ~/.ssh/authorized_keys /home/$BOTUSER/.ssh/authorized_keys
sudo chown $BOTUSER:$BOTUSER /home/$BOTUSER/.ssh/authorized_keys
sudo chmod 600 /home/$BOTUSER/.ssh/authorized_keys
sudo mv ~/nlbot /home/$BOTUSER/nlbot
sudo chown -R $BOTUSER:$BOTUSER /home/$BOTUSER/nlbot

# 3. Switch to the bot user and run the bootstrap script. This does
#    Steps 3-9 (locale, core tools, Node, Docker, Claude Code CLI,
#    swap, timezone) non-interactively. ~5-10 min.
sudo su - $BOTUSER
bash ~/nlbot/runtime/bootstrap.sh

# 4. Log out, log back in (docker group needs a fresh login), then
#    one last interactive step: claude OAuth first-run.
exit
ssh $BOTUSER@<host>
claude    # accept TOS in the OAuth prompt, then exit

# 5. (optional) Sanity-check state.
bash ~/nlbot/runtime/setup-status.sh
```

Each shell command above is a single short line — safe to copy and paste one at a time, or all at once. The rest of this doc explains what the script does and the manual bits that can't be automated.

---

## Step 1 — System update + git + clone the kit

You need `sudo` (some minimal Debian images don't ship it) and `git` to clone the kit. The script does the rest.

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y sudo git
git clone https://github.com/jasonfen/nlbot.git ~/nlbot
```

If a kernel update landed, reboot before continuing:

```bash
[ -f /var/run/reboot-required ] && sudo reboot
```

(SSH back in via Tailscale after the reboot if so.)

## Step 2 — Create the bot user (3 min, interactive)

Don't run the bot as root or as the cloud's shared default user. Make it a dedicated account so SSH keys, sudoers, group memberships, and crontab live in one tidy `$HOME`. **This step is interactive** — `adduser` prompts for password twice. Pick a username (convention: bot's name in lowercase; the walkthrough uses `nlbot`).

```bash
BOTUSER=nlbot
sudo adduser --gecos "" $BOTUSER
sudo usermod -aG sudo $BOTUSER
```

Copy your SSH key over so you can `ssh $BOTUSER@<host>` directly:

```bash
sudo install -d -m 700 -o $BOTUSER -g $BOTUSER /home/$BOTUSER/.ssh
sudo cp ~/.ssh/authorized_keys /home/$BOTUSER/.ssh/authorized_keys
sudo chown $BOTUSER:$BOTUSER /home/$BOTUSER/.ssh/authorized_keys
sudo chmod 600 /home/$BOTUSER/.ssh/authorized_keys
```

Move the kit into the bot user's home so the rest runs as `$BOTUSER`:

```bash
sudo mv ~/nlbot /home/$BOTUSER/nlbot
sudo chown -R $BOTUSER:$BOTUSER /home/$BOTUSER/nlbot
```

Switch to the new user (fresh login picks up the new group memberships):

```bash
sudo su - $BOTUSER
```

(You can also disconnect and `ssh $BOTUSER@<host>` instead. Either way works.)

> **Note:** Bot-driven setup (Steps 5–9 of `first-time-setup.md`) requires scoped `NOPASSWD` sudo for `systemctl`, `crontab`, and `docker` so the bot can run them from inside a detached tmux session where there's no terminal to type a password into. **You'll grant that as the very last action of `first-time-setup.md` Step 4 — right before the verification reboot, after you've confirmed everything else works.** Don't grant it here. Doing it last means you've got a working setup to fall back on with normal password-prompted sudo if anything goes sideways.

## Step 3 — Run the bootstrap script

The script handles locale, core tools, Node 20+, Docker + compose plugin, Claude Code CLI, swap (only if RAM < 4 GB and no swap configured), and timezone. ~5–10 minutes depending on apt mirror speed.

```bash
bash ~/nlbot/runtime/bootstrap.sh
```

It's idempotent — safe to re-run if anything fails partway. Each section banners what it's doing so you can see progress in real time.

Read the script before running if you like: it's `~/nlbot/runtime/bootstrap.sh` after the clone in Step 1, or [on GitHub](https://github.com/jasonfen/nlbot/blob/main/runtime/bootstrap.sh).

## Step 4 — Re-login and verify docker group

`usermod -aG docker $USER` (done by the script in Step 6) only takes effect on a new login. Log out and back in:

```bash
exit
ssh $BOTUSER@<host>
```

Verify the docker group is live in this session:

```bash
id -nG | tr ' ' '\n' | grep -x docker
```

If that prints `docker`, you're good. If it doesn't, the bot's `claude-code.service` won't be able to run `docker compose` once it boots, and Step 5 of `first-time-setup.md` will fail. Re-`exit` and re-SSH if it's missing.

While you're at it, confirm Docker works end-to-end:

```bash
docker compose version
docker run --rm hello-world
```

## Step 5 — Claude Code first-run (OAuth)

This stays manual because the TOS gate doesn't render in detached panes:

```bash
claude
```

Follow the OAuth prompt, accept the TOS, exit.

## Step 6 — (Optional) State probe

The kit includes `runtime/setup-status.sh` — a probe that reports your bootstrap and setup progress against a checklist. Run it any time during bootstrap or first-time-setup to see what's done and what the next manual step is:

```bash
bash ~/nlbot/runtime/setup-status.sh
```

Add `--apply` to let it self-correct `setup-state.md` if `Current phase:` has drifted from reality:

```bash
bash ~/nlbot/runtime/setup-status.sh --apply
```

In PRE-SETUP mode (you don't have a vault yet), it probes system packages, the bot user, group memberships, and ssh keys. In POST-SETUP mode (after the Step 4 reboot in `first-time-setup.md`, when the bot is running), it adds per-phase reality checks. The bot's `setup-runner` agent runs it with `--apply` on every dispatch so the state file always reflects reality.

---

## What's next

You're now in the state that `first-time-setup.md` Step 1 assumes. Two paths:

- **DIY**: open [`first-time-setup.md`](first-time-setup.md) and follow it.
- **CC-assisted**: start a Claude Code session (`claude`) in this directory and tell it: *"read setup-orchestrator.md and walk me through the install."* It'll handle the rest, pausing at every spot that needs your eyes (BotFather token, password choices, sudo prompts, etc.).

Either way, expect about 30 minutes from here to a running bot.

---

## Appendix: what the script does, step by step

If you want to run the bootstrap steps manually instead of via the script (because something failed, or you want to read each command before it runs), open `runtime/bootstrap.sh` — it's commented banner-by-banner. The flow is:

| Banner | What it does |
|---|---|
| Step 3 — Locale | `apt install locales`, `locale-gen C.UTF-8 en_US.UTF-8`, `update-locale` |
| Step 4 — Core tools | `apt install git tmux curl jq unzip ca-certificates python3 python3-pip python3-venv build-essential` |
| Step 5 — Node 20+ | `curl https://deb.nodesource.com/setup_20.x \| sudo -E bash -`, then `apt install nodejs` |
| Step 6 — Docker | Fetch GPG keyring, write deb822 sources file, `apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`, `usermod -aG docker` |
| Step 7 — Claude Code | `sudo npm install -g @anthropic-ai/claude-code` (skips if already installed) |
| Step 8 — Swap | If RAM < 4 GB and no swap yet: 2 GB `/swapfile`, persisted in `/etc/fstab` |
| Step 9 — Timezone | If currently UTC, prints the `timedatectl set-timezone` command for you to run later |

Each section is idempotent (re-run is a no-op). If the script aborts partway, fix the issue and re-run from the top.

### Troubleshooting

- **`sudo: command not found` (some minimal Debian images)** — install it first as root: `apt update && apt install -y sudo`. Step 1 handles this if you're using a fresh image.
- **`apt update` fails with `404 Not Found` on the Docker Release file** — your codename probably isn't supported by Docker yet (rare, only happens on bleeding-edge releases). Check what's available at <https://download.docker.com/linux/debian/dists/> or <https://download.docker.com/linux/ubuntu/dists/> and patch the `Suites:` line of `/etc/apt/sources.list.d/docker.sources` to the nearest stable codename.
- **`docker run hello-world` fails with permission denied** — group membership isn't live in this login. `exit` and SSH back in, then retry.
- **Glyphs render as `??`** — locale didn't take effect for this shell. Log out and back in; if still wrong, see "Glyph rendering inside tmux" in [`persistence-and-hardware.md`](persistence-and-hardware.md).
