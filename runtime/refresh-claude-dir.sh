#!/usr/bin/env bash
# Re-sync kit-managed files into the vault. Runs from the git post-merge
# hook so kit pulls propagate without manual reseeds.
#
# Two phases, with different ownership models:
#
#   1. <VAULT>/.claude/ — kit-owned, OVERWRITES on every run. Source is
#      <VAULT>/dot-claude/, substituted for Phase-0 placeholders.
#      Local edits are blown away; fork the kit if you need to override.
#
#   2. Vault-page seeds — user-owned, NO-CLOBBER. New files from
#      templates/vault-pages/ (CONFIG.md, _templates/handoff.md, etc.)
#      get seeded if absent; existing files at the vault root are left
#      alone so user edits survive.
#
# Phase-0 substitution values (BOT_NAME, USER_NAME, VAULT, OS_USER) come
# from <VAULT>/setup-state.md's Values block.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VAULT_GUESS=$(cd "$SCRIPT_DIR/.." && pwd)
SRC="$VAULT_GUESS/dot-claude"
STATE="$VAULT_GUESS/setup-state.md"

[ -d "$SRC" ] || {
  echo "refresh-claude-dir: $SRC not found — is this a kit clone?" >&2
  exit 1
}
[ -f "$STATE" ] || {
  echo "refresh-claude-dir: $STATE not found — run first-time-setup.sh first" >&2
  exit 1
}

# Read a Values-block field from setup-state.md.
get_val() {
  local key=$1
  grep "^- \*\*${key}\*\*:" "$STATE" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

BOT_NAME=$(get_val BOT_NAME)
USER_NAME=$(get_val USER_NAME)
VAULT=$(get_val VAULT)
OS_USER=$(get_val OS_USER)
[ -n "$OS_USER" ] || OS_USER="$BOT_NAME"

for var in BOT_NAME USER_NAME VAULT OS_USER; do
  if [ -z "${!var}" ]; then
    echo "refresh-claude-dir: missing $var in $STATE Values block" >&2
    exit 2
  fi
done

# Sanity-check: the VAULT in setup-state should match the script's
# inferred location. Mismatch usually means the vault was moved without
# updating setup-state — surface as a warning, don't bail.
if [ "$VAULT" != "$VAULT_GUESS" ]; then
  echo "refresh-claude-dir: warning — setup-state VAULT=$VAULT but script ran from $VAULT_GUESS" >&2
  VAULT="$VAULT_GUESS"
fi

DST="$VAULT/.claude"
mkdir -p "$DST"

changed=0
total=0
while IFS= read -r -d '' src; do
  rel=${src#"$SRC/"}
  dst="$DST/$rel"
  mkdir -p "$(dirname "$dst")"
  tmp=$(mktemp)
  # Only the four canonical kit placeholders. Other angle-bracket tokens
  # (<HANDOFFS>, <SECONDS_SINCE>, <TAILSCALE_HOSTNAME>, <YOUR_TOKEN>)
  # are runtime values and documentation examples — leave them alone.
  sed \
    -e "s|<BOT_NAME>|$BOT_NAME|g" \
    -e "s|<USER_NAME>|$USER_NAME|g" \
    -e "s|<VAULT>|$VAULT|g" \
    -e "s|<USER>|$OS_USER|g" \
    "$src" > "$tmp"
  total=$((total + 1))
  if [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
    mv "$tmp" "$dst"
    changed=$((changed + 1))
  else
    rm -f "$tmp"
  fi
done < <(find "$SRC" -type f -print0)

echo "refresh-claude-dir: $changed/$total file(s) updated in $DST"

# Seed any vault-page templates that the kit ships but this vault doesn't
# have yet. Unlike .claude/ (kit-owned, overwriting), vault-page files at
# the root are USER-OWNED after first install — they hand-edit them. So
# we only ADD missing files; never clobber existing ones.
#
# This covers the gap where the kit gains a new vault-page (e.g. CONFIG.md
# in d04074c, _templates/handoff.md in the same commit). Existing installs
# pull the new files into templates/vault-pages/ but Step 2's one-shot
# `cp -n` never re-fires, so the new templates sit unused. Without this
# block, every kit-added vault-page requires a manual reseed instruction.
PAGES_SRC="$VAULT/templates/vault-pages"
if [ -d "$PAGES_SRC" ]; then
  seeded_pages=0
  for src in "$PAGES_SRC"/*.md; do
    [ -f "$src" ] || continue
    base=$(basename "$src")
    dst="$VAULT/$base"
    if [ ! -f "$dst" ]; then
      sed \
        -e "s|<BOT_NAME>|$BOT_NAME|g" \
        -e "s|<USER_NAME>|$USER_NAME|g" \
        -e "s|<VAULT>|$VAULT|g" \
        -e "s|<USER>|$OS_USER|g" \
        "$src" > "$dst"
      seeded_pages=$((seeded_pages + 1))
      echo "  seeded $base (was missing)"
    fi
  done

  # _templates/ — the SilverBullet page-template directory. Same no-clobber
  # contract: add the whole tree if the vault has no _templates yet; add
  # individual files if the directory exists but specific templates are
  # missing.
  if [ -d "$PAGES_SRC/_templates" ]; then
    seeded_tpls=0
    for src in "$PAGES_SRC/_templates"/*.md; do
      [ -f "$src" ] || continue
      base=$(basename "$src")
      dst="$VAULT/_templates/$base"
      mkdir -p "$VAULT/_templates"
      if [ ! -f "$dst" ]; then
        sed \
          -e "s|<BOT_NAME>|$BOT_NAME|g" \
          -e "s|<USER_NAME>|$USER_NAME|g" \
          -e "s|<VAULT>|$VAULT|g" \
          -e "s|<USER>|$OS_USER|g" \
          "$src" > "$dst"
        seeded_tpls=$((seeded_tpls + 1))
        echo "  seeded _templates/$base (was missing)"
      fi
    done
    echo "refresh-claude-dir: $seeded_pages new vault-page(s), $seeded_tpls new template(s) seeded"
  else
    echo "refresh-claude-dir: $seeded_pages new vault-page(s) seeded"
  fi
fi
