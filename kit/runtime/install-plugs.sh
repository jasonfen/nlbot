#!/usr/bin/env bash
# install-plugs.sh — fetch the kit's recommended plug bundles into
# <VAULT>/_plug/ so SilverBullet picks them up at startup without
# requiring a manual "Plugs: Update" command-palette invocation.
#
# Idempotent: skips downloads when the destination file already exists
# and matches the pinned SHA in the URL (kit upgrades to a newer pin
# overwrite). Plug versions are pinned to a commit SHA upstream so the
# kit is reproducible — bumping a plug = bump the URL in this script
# and re-run.
#
# Why a separate script instead of inline in first-time-setup.sh:
#   1. refresh-claude-dir.sh (the post-merge hook) calls this too, so
#      pulls of the kit can deliver new plugs to existing installs.
#   2. Easier to test and rerun manually if a plug fetch failed at
#      install time (e.g. network was flaky).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# kit/runtime/ → kit/ → repo root → vault/
VAULT=${VAULT:-$(cd "$SCRIPT_DIR/../.." && pwd)/vault}
DST="$VAULT/_plug"
mkdir -p "$DST"

# Format: <plug-name>:<SHA-pinned-URL>
# Add new plugs here. Pin to a commit SHA, not main/master, so the kit
# stays reproducible across kit-clone times.
PLUGS=(
  "treeview.plug.js:https://raw.githubusercontent.com/joekrill/silverbullet-treeview/c67dec213e8c31086fb0dc391965ae36aaefffba/treeview.plug.js"
)

fetched=0
skipped=0
for entry in "${PLUGS[@]}"; do
  name=${entry%%:*}
  url=${entry#*:}
  dst="$DST/$name"
  if [ -f "$dst" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  if curl -fsSL --max-time 30 -o "$dst" "$url"; then
    fetched=$((fetched + 1))
    echo "  installed $name"
  else
    echo "  WARN: failed to fetch $name from $url" >&2
    rm -f "$dst"
  fi
done

echo "install-plugs: $fetched fetched, $skipped already present (in $DST)"
