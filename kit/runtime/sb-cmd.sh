#!/usr/bin/env bash
# sb-cmd.sh — invoke a SilverBullet command via the HTTP Runtime API.
#
# Wraps the `POST /.runtime/lua` endpoint to run
# `editor.invokeCommand(<name>)` against the live SB instance — no `sb`
# CLI binary, no headless-Chrome setup on the host. The container does
# the work.
#
# REQUIRES: the SilverBullet container must use the `-runtime-api`
# image variant (`ghcr.io/silverbulletmd/silverbullet:latest-runtime-api`,
# ~766MB, includes Chromium) instead of the base `:latest` image
# (~64MB, no runtime API). See silverbullet-setup.md for the trade-off
# and how to flip the docker-compose.yml's `image:` line.
#
# AUTH: reads SB_AUTH_TOKEN from systemd-creds (sb-auth-token blob);
# falls back to the env var. The token is the same value SB uses for
# sync clients (set by the bot at step-6 install time).
#
# USAGE:
#   sb-cmd.sh "Plugs: Update"
#   sb-cmd.sh "Page: From Template" 'handoff'        # arg unsupported atm
#   sb-cmd.sh --lua 'editor.getCurrentPage()'        # arbitrary Lua expr
#
# RETURN: prints the JSON response on stdout; non-zero exit on HTTP/curl
# error. Caller can parse with jq.

set -euo pipefail

SB_URL=${SB_URL:-http://127.0.0.1:3001}
BOT_NAME=${BOT_NAME:-$USER}
SECRETS_DIR="/etc/${BOT_NAME}/secrets"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$SCRIPT_DIR/.." && pwd)

# Resolve auth token. Prefer the encrypted blob over an env var.
if [ -z "${SB_AUTH_TOKEN:-}" ] && sudo test -f "$SECRETS_DIR/sb-auth-token" 2>/dev/null; then
  SB_AUTH_TOKEN=$(sudo systemd-creds decrypt "$SECRETS_DIR/sb-auth-token" -)
fi

if [ -z "${SB_AUTH_TOKEN:-}" ]; then
  echo "sb-cmd: no SB_AUTH_TOKEN found (env var unset, secrets blob missing)" >&2
  exit 2
fi

# Probe — the Runtime API isn't available on the base image.
probe=$(curl -fsS --max-time 5 -X POST \
  -H "Authorization: Bearer $SB_AUTH_TOKEN" \
  --data-raw '1' \
  "$SB_URL/.runtime/lua" 2>&1 || true)
if ! echo "$probe" | grep -q '"result":1'; then
  cat >&2 <<EOF
sb-cmd: Runtime API not responding at $SB_URL/.runtime/lua
  probe: $probe
The SilverBullet container is probably running the base image, which
doesn't include Chromium. Flip $KIT/docker-compose.yml's image: line to
ghcr.io/silverbulletmd/silverbullet:latest-runtime-api and re-up:
  bash $KIT/runtime/silverbullet-up.sh
The base image is ~64MB and the -runtime-api variant is ~766MB; trade
disk for programmatic-command-invocation capability. See
$KIT/silverbullet-setup.md for the full trade-off.
EOF
  exit 3
fi

# Build the Lua expression. --lua passes arbitrary expr; default treats
# the first arg as a command name for editor.invokeCommand.
if [ "${1:-}" = "--lua" ]; then
  expr=$2
else
  cmd=$1
  # Escape any double-quotes in the command name (rare but legal).
  cmd_escaped=${cmd//\"/\\\"}
  expr="editor.invokeCommand(\"$cmd_escaped\")"
fi

curl -fsS --max-time 30 -X POST \
  -H "Authorization: Bearer $SB_AUTH_TOKEN" \
  --data-raw "$expr" \
  "$SB_URL/.runtime/lua"
echo  # trailing newline so terminal output looks clean
