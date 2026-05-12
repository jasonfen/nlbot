#!/usr/bin/env bash
# Re-sync kit-managed files into the working tree. Runs from the git
# post-merge hook so kit pulls propagate without manual reseeds.
#
# Three phases, with different ownership models:
#
#   1. <REPO_ROOT>/.claude/ — kit-owned, OVERWRITES on every run. Source
#      is <KIT>/dot-claude/, substituted for Phase-0 placeholders. Local
#      edits are blown away; fork the kit if you need to override.
#
#   2. <VAULT>/ vault-page seeds — user-owned, NO-CLOBBER. New files
#      from <KIT>/templates/vault-pages/ (CONFIG.md, _templates/handoff.md,
#      etc.) get seeded if absent; existing files are left alone so user
#      edits survive.
#
#   3. <VAULT>/_plug/ plug bundles — kit-managed but no-clobber per
#      bundle. Delegated to <KIT>/runtime/install-plugs.sh.
#
# Path triple:
#   REPO_ROOT = <repo_root>            — bot CWD, holds .claude/, cron-prompts/
#   KIT       = <repo_root>/kit/       — kit source
#   VAULT     = <repo_root>/vault/     — SilverBullet space
#
# Phase-0 values (BOT_NAME, USER_NAME, VAULT, OS_USER) come from
# <REPO_ROOT>/setup-state.md's Values block (setup-state.md lives at
# repo root, not in the vault).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$SCRIPT_DIR/.." && pwd)            # kit/runtime/ → kit/
REPO_ROOT=$(cd "$KIT/.." && pwd)             # kit/ → repo root
VAULT="$REPO_ROOT/vault"
SRC="$KIT/dot-claude"
STATE="$REPO_ROOT/setup-state.md"

[ -d "$SRC" ] || {
  echo "refresh-claude-dir: $SRC not found — is $KIT a kit clone?" >&2
  exit 1
}
[ -f "$STATE" ] || {
  echo "refresh-claude-dir: $STATE not found — run kit/runtime/first-time-setup.sh first" >&2
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
VAULT_FROM_STATE=$(get_val VAULT)
OS_USER=$(get_val OS_USER)
[ -n "$OS_USER" ] || OS_USER="$BOT_NAME"

for var in BOT_NAME VAULT_FROM_STATE OS_USER; do
  if [ -z "${!var}" ]; then
    echo "refresh-claude-dir: missing $var in $STATE Values block" >&2
    exit 2
  fi
done
# USER_NAME is intentionally NOT required. The F34 provisioner-vs-Nate
# split defers USER_NAME (along with CANARY_PHRASE and the personality
# values) to Nate's `/setup` interview, which runs inside the bot's
# tmux session post-reboot. refresh-claude-dir gets called from
# first-time-setup.sh (provisioner-phase) BEFORE the interview happens,
# so USER_NAME is legitimately blank. Substitution below treats it as
# conditional — `<USER_NAME>` stays as a literal placeholder token in
# any file that uses it until `/setup` re-runs the substitution pass.

# Sanity-check: setup-state's VAULT should match where we just computed
# it from the script location. Mismatch usually means the repo was moved
# without updating setup-state — surface as a warning, don't bail.
if [ "$VAULT_FROM_STATE" != "$VAULT" ]; then
  echo "refresh-claude-dir: warning — setup-state VAULT=$VAULT_FROM_STATE but script ran with VAULT=$VAULT" >&2
fi

# .claude/ lives at the REPO ROOT (bot's CWD), not inside the vault.
# Claude Code reads .claude/ from cwd, which is <repo_root>.
DST="$REPO_ROOT/.claude"
mkdir -p "$DST"

# Substitution helper. Six tokens: <BOT_NAME>, <USER_NAME>, <USER>,
# <KIT>, <VAULT>, <REPO_ROOT>. Other angle-bracket tokens
# (<HANDOFFS>, <SECONDS_SINCE>, <TAILSCALE_HOSTNAME>, <YOUR_TOKEN>)
# are runtime values and documentation examples — leave them alone.
#
# <USER_NAME> is conditionally substituted: empty value means the
# /setup interview hasn't run yet, so we leave the token as a literal
# in the rendered file. `/setup`'s substitute-placeholders.sh pass
# resolves it later when USER_NAME has been collected. This matches
# the F34 pattern in kit/runtime/substitute-placeholders.sh.
substitute() {
  local -a args=(
    -e "s|<BOT_NAME>|$BOT_NAME|g"
    -e "s|<USER>|$OS_USER|g"
    -e "s|<KIT>|$KIT|g"
    -e "s|<VAULT>|$VAULT|g"
    -e "s|<REPO_ROOT>|$REPO_ROOT|g"
  )
  [ -n "$USER_NAME" ] && args+=(-e "s|<USER_NAME>|$USER_NAME|g")
  sed "${args[@]}" "$1"
}

# Phase 1: render dot-claude/ → .claude/ (kit-owned, overwrites).
changed=0
total=0
while IFS= read -r -d '' src; do
  rel=${src#"$SRC/"}
  dst="$DST/$rel"
  mkdir -p "$(dirname "$dst")"
  tmp=$(mktemp)
  substitute "$src" > "$tmp"
  total=$((total + 1))
  if [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
    mv "$tmp" "$dst"
    changed=$((changed + 1))
  else
    rm -f "$tmp"
  fi
done < <(find "$SRC" -type f -print0)

echo "refresh-claude-dir: $changed/$total file(s) updated in $DST"

# Phase 2: no-clobber seed of vault-page templates → <VAULT>/.
# These are USER-OWNED after first install. We only ADD missing files;
# never clobber existing ones.
PAGES_SRC="$KIT/templates/vault-pages"
if [ -d "$PAGES_SRC" ]; then
  mkdir -p "$VAULT"
  seeded_pages=0
  for src in "$PAGES_SRC"/*.md; do
    [ -f "$src" ] || continue
    base=$(basename "$src")
    dst="$VAULT/$base"
    if [ ! -f "$dst" ]; then
      substitute "$src" > "$dst"
      seeded_pages=$((seeded_pages + 1))
      echo "  seeded $base (was missing)"
    fi
  done

  # _templates/ — SilverBullet page-template directory.
  if [ -d "$PAGES_SRC/_templates" ]; then
    seeded_tpls=0
    mkdir -p "$VAULT/_templates"
    for src in "$PAGES_SRC/_templates"/*.md; do
      [ -f "$src" ] || continue
      base=$(basename "$src")
      dst="$VAULT/_templates/$base"
      if [ ! -f "$dst" ]; then
        substitute "$src" > "$dst"
        seeded_tpls=$((seeded_tpls + 1))
        echo "  seeded _templates/$base (was missing)"
      fi
    done
    echo "refresh-claude-dir: $seeded_pages new vault-page(s), $seeded_tpls new template(s) seeded"
  else
    echo "refresh-claude-dir: $seeded_pages new vault-page(s) seeded"
  fi
fi

# Phase 3: pull any new plug bundles declared in install-plugs.sh.
# Idempotent: skips entries whose destination file already exists.
if [ -x "$KIT/runtime/install-plugs.sh" ]; then
  VAULT="$VAULT" bash "$KIT/runtime/install-plugs.sh"
fi

# Phase 4: cron-prompts kit assets. setup-runner Step 5 COPIES the kit's
# inject-prompt.sh + cron-prompts/*.md files to <REPO_ROOT>/cron-prompts/
# at install time. A later `git pull` updates the kit source but not the
# deployed copies, so kit-side fixes (e.g., a new pane-detection rule
# in inject-prompt.sh) don't reach the actual cron invocation path until
# someone re-copies by hand. This phase keeps the deployed copies in sync.
# OVERWRITE intentional — kit owns these files; local edits will be
# blown away on each refresh. State files (queue/, inject.log,
# .secretary-last-hash, .soul-loop-last-action, job-log.md, .inject.lock)
# live alongside but are not touched. Caught by ansi on nlbot0 after F30
# (sidechat msg 2771, F31).
CRON_DST="$REPO_ROOT/cron-prompts"
if [ -d "$CRON_DST" ]; then
  refreshed=0
  if [ -f "$KIT/runtime/inject-prompt.sh" ]; then
    install -m 755 "$KIT/runtime/inject-prompt.sh" \
      "$CRON_DST/inject-prompt.sh"
    refreshed=$((refreshed + 1))
  fi
  if [ -d "$KIT/runtime/cron-prompts" ]; then
    for src in "$KIT/runtime/cron-prompts"/*.md; do
      [ -f "$src" ] || continue
      install -m 644 "$src" "$CRON_DST/$(basename "$src")"
      refreshed=$((refreshed + 1))
    done
  fi
  if [ "$refreshed" -gt 0 ]; then
    echo "refresh-claude-dir: $refreshed cron-prompts file(s) refreshed"
  fi
fi
