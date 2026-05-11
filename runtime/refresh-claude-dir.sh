#!/usr/bin/env bash
# Re-sync <VAULT>/.claude/ from the kit's dot-claude/ source.
#
# The vault is the kit clone. After `git pull` brings in new
# dot-claude/{agents,commands}/*.md, this script:
#
#   1. Reads Phase-0 substitution values (BOT_NAME, USER_NAME, VAULT,
#      OS_USER) from <VAULT>/setup-state.md.
#   2. Walks <VAULT>/dot-claude/, applies substitution, writes to
#      <VAULT>/.claude/ at the same relative path.
#   3. Reports how many files changed.
#
# Idempotent — re-running produces the same output unless dot-claude/
# changed (compares with cmp before overwriting).
#
# .claude/ is bot-owned. Don't hand-edit; the post-merge hook will
# overwrite local edits on every `git pull`. If you need to override
# kit behavior, fork the kit and edit dot-claude/ at the source.

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
