#!/usr/bin/env bash
# nlbot bootstrap script — does Steps 3-9 of bootstrap.md non-interactively:
# locale, core tools, Node 20+, Docker + compose, Claude Code CLI, swap,
# timezone. Re-runnable: each section is idempotent.
#
# Usage:
#   bash ~/<KIT_CLONE>/runtime/bootstrap.sh
#
# What this script SKIPS (manual, see bootstrap.md):
#   - Step 1 system update    (run `sudo apt update && sudo apt upgrade -y` first)
#   - Step 2 user creation    (interactive `adduser` prompts)
#   - Step 7 `claude` first-run OAuth login (needs a real terminal)
#   - Step 10 kit clone       (you already cloned to get this script)
#
# Run as the bot user (after switching with `sudo su - $BOTUSER`). The
# `usermod -aG docker $USER` line picks up whatever user the script is
# running as.

set -euo pipefail

banner() {
  echo
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

skip() {
  echo "  [skip] $1"
}

#
# Step 3: Locale — Claude Code uses box-drawing glyphs; broken locale
# renders them as `??` and the UI looks broken even though it works.
#
banner "Step 3 — Locale"
sudo apt install -y locales
sudo locale-gen C.UTF-8 en_US.UTF-8
sudo update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8
echo "  Locale generated. New shells will pick up C.UTF-8."

#
# Step 4: Core tools — git, tmux, jq, python, build-essential, etc.
#
banner "Step 4 — Core tools"
sudo apt install -y \
  git tmux curl jq unzip ca-certificates \
  python3 python3-pip python3-venv build-essential

#
# Step 5: Node 20+ from NodeSource. Skip if already on a recent version.
#
banner "Step 5 — Node.js 20+"
NODE_OK=0
if command -v node >/dev/null 2>&1; then
  NODE_VER=$(node --version | sed 's/^v//; s/\..*//')
  if [ "$NODE_VER" -ge 20 ] 2>/dev/null; then
    NODE_OK=1
  fi
fi
if [ "$NODE_OK" -eq 1 ]; then
  skip "Node $(node --version) already installed."
else
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt install -y nodejs
fi
echo "  node:  $(node --version)"
echo "  npm:   $(npm --version)"

#
# Step 6: Docker + compose plugin. Uses deb822 sources format so the
# sources file has one short line per field (no paste-wrap hazard if
# you ever look at the rendered docker.sources). Idempotent: skips the
# keyring fetch if /etc/apt/keyrings/docker.gpg already exists.
#
banner "Step 6 — Docker + compose plugin"
. /etc/os-release
DOCKER_OS=$ID
DOCKER_CODENAME=$VERSION_CODENAME
sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL "https://download.docker.com/linux/$DOCKER_OS/gpg" \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
else
  skip "Docker GPG keyring already in place."
fi
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DOCKER_OS
Suites: $DOCKER_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
EOF
sudo apt update
sudo apt install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
echo "  docker:  $(docker --version)"
echo "  compose: $(docker compose version)"
echo
echo "  NOTE: docker group membership only activates on next login."
echo "        Log out and back in before running 'docker' as $USER."

#
# Step 7: Claude Code CLI install. First-run OAuth login is interactive
# and stays manual — you'll run \`claude\` at a real terminal after this.
#
banner "Step 7 — Claude Code (CLI install only)"
if command -v claude >/dev/null 2>&1; then
  skip "Claude Code already installed ($(claude --version 2>&1 | head -1))."
else
  sudo npm install -g @anthropic-ai/claude-code
  echo "  claude:  $(claude --version 2>&1 | head -1)"
  echo
  echo "  NOTE: Claude Code is now installed globally via npm. On first run"
  echo "        it may warn about auto-update permissions because the binary"
  echo "        lives in a sudo-required directory (/usr/local/lib/...). After"
  echo "        the initial OAuth login (first-time-setup.md Step 1), run"
  echo "        \`claude install\` once to switch to the user-scoped native"
  echo "        binary at ~/.local/bin/claude — this enables auto-updates."
fi

#
# Step 8: Swap — only if RAM < 4 GB and no swap configured. Don't
# clobber user-managed swap.
#
banner "Step 8 — Swap file"
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
MEM_GB=$(( MEM_KB / 1024 / 1024 ))
if [ "$MEM_GB" -lt 4 ] && [ "$SWAP_KB" -eq 0 ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
  fi
  echo "  Added 2 GB swap (MemTotal was ${MEM_GB} GB)."
elif [ "$SWAP_KB" -gt 0 ]; then
  skip "Swap already configured (SwapTotal=${SWAP_KB} KB)."
else
  skip "MemTotal=${MEM_GB} GB — no swap needed."
fi

#
# Step 9: Timezone — only flag if currently UTC. Don't overwrite a
# user-chosen zone.
#
banner "Step 9 — Timezone"
TZ_NOW=$(timedatectl show --property=Timezone --value 2>/dev/null || echo unknown)
if [ "$TZ_NOW" = "Etc/UTC" ] || [ "$TZ_NOW" = "UTC" ]; then
  echo "  Currently $TZ_NOW. Set explicitly with:"
  echo "    sudo timedatectl set-timezone America/New_York"
else
  echo "  Already set to $TZ_NOW."
fi

#
# Done
#
banner "Bootstrap complete"
echo
echo "Next steps:"
echo "  1. exit + ssh back in (or sudo su - again) so 'docker' group is live."
echo "  2. Verify: id -nG | tr ' ' '\\n' | grep -x docker  (should print 'docker')"
echo "  3. Run \`claude\` at a real terminal — OAuth first-run, then exit."
echo "  4. (optional) bash <kit>/runtime/setup-status.sh — state probe."
echo "  5. Open first-time-setup.md and continue from Step 1."
echo
