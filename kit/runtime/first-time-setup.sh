#!/usr/bin/env bash
# first-time-setup.sh — automates Steps 1-4 of first-time-setup.md.
#
# Drops the vault skeleton, copies kit files, substitutes Phase 0
# placeholders ([Nate], [Your Bot's Name], <VAULT>, etc.), installs
# claude-code.service, and brings up the tmux session.
#
# Stops BEFORE the NOPASSWD sudoers grant and the verification reboot —
# those stay manual on purpose (the kit's explicit "hand over the keys"
# gate). Prints a clear next-steps block when done.
#
# Usage:
#   bash <KIT_CLONE>/runtime/first-time-setup.sh
#
# Phase 0 values are resolved in this order, first hit wins:
#   1. Environment variable already set (BOT_NAME=nlbot ./first-time-setup.sh)
#   2. Existing populated entry in <VAULT>/setup-state.md Values block
#   3. Interactive `read -p` with default in brackets
#
# Required: BOT_NAME, USER_NAME, VAULT, CANARY_PHRASE
# Optional: IDLE_PREFS, CREATIVE_OUTPUT, COMM_STYLE, VALUES_CARES_ABOUT,
#           USER_ROLE, USER_HOBBIES, USER_HOURS, USER_PREFS

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

banner() {
  echo
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

skip() {
  echo "  [skip] $1"
}

# Path triple resolution. Script lives at kit/runtime/first-time-setup.sh,
# so two levels up is the repo root; vault is repo_root/vault.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SCRIPT_DIR/.." && pwd)"           # kit/runtime/ → kit/
REPO_ROOT="$(cd "$KIT/.." && pwd)"            # kit/ → repo root
VAULT_DEFAULT="$REPO_ROOT/vault"

# --reinstall-services-only: skip Phase 0/Steps 1–3 and jump straight to
# Step 4. Used by migrate-layout.sh on existing installs whose Phase 0
# values are already in setup-state.md and whose vault is already seeded.
REINSTALL_SERVICES_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --reinstall-services-only) REINSTALL_SERVICES_ONLY=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
  esac
done

# Read a value from setup-state.md Values block (returns empty if missing
# or still has the placeholder comment). setup-state.md lives at the repo
# root in the new layout (bot-runtime state, not vault content).
state_read() {
  local key="$1"
  local file="$REPO_ROOT/setup-state.md"
  [ -f "$file" ] || return 0
  local value
  value=$(grep "^- \*\*$key\*\*:" "$file" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1)
  echo "$value"
}

# Write a value into setup-state.md Values block.
state_write() {
  local key="$1"
  local value="$2"
  local file="$REPO_ROOT/setup-state.md"
  [ -f "$file" ] || return 0
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[\&|]/\\&/g')
  sed -i "s|^- \*\*$key\*\*:.*|- **$key**: $escaped|" "$file"
}

# Prompt-or-resolve. Order: env var, setup-state, default, prompt.
# Usage: prompt_value VAR_NAME "question" [default] [required=yes|no]
prompt_value() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local required="${4:-no}"
  local current
  current="$(eval echo "\${$var_name:-}")"

  if [ -n "$current" ]; then
    echo "  $var_name = $current  (from env)"
    return 0
  fi

  local from_state
  from_state=$(state_read "$var_name")
  if [ -n "$from_state" ]; then
    eval "$var_name=$(printf '%q' "$from_state")"
    echo "  $var_name = $from_state  (from setup-state.md)"
    return 0
  fi

  local answer
  # `read` returns non-zero on EOF (which happens whenever the script is
  # piped stdin from /dev/null or any non-tty source). Under `set -e`
  # that aborts the whole script BEFORE the default-merge below could
  # take effect. Guard with `|| true` so EOF leaves `answer` empty, then
  # the default-merge + required check handle the rest. Caught by ansi
  # on kit-e2e-test-3 (F16) when probing the non-TTY hard-fail without
  # PASSWORD_MODE pre-set in env.
  if [ -n "$default" ]; then
    read -rp "  $question [$default]: " answer || true
    answer="${answer:-$default}"
  else
    read -rp "  $question: " answer || true
  fi

  if [ -z "$answer" ] && [ "$required" = "yes" ]; then
    echo "  ERROR: $var_name is required" >&2
    exit 1
  fi

  eval "$var_name=$(printf '%q' "$answer")"
}

# Replace Phase 0 placeholders in one file.
substitute_placeholders() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -i \
    -e "s|\[Your Bot's Name\]|$BOT_NAME|g" \
    -e "s|\[Nate's\]|${USER_NAME}'s|g" \
    -e "s|\[Nate\]|$USER_NAME|g" \
    -e "s|\[Nate: Fill this in\. What are your non-negotiable preferences?\]|$USER_PREFS|g" \
    -e "s|\[CHOOSE YOUR CANARY PHRASE\]|$CANARY_PHRASE|g" \
    -e "s|\[YOUR CANARY PHRASE\]|$CANARY_PHRASE|g" \
    -e "s|\[reading/coding/writing/exploring\]|$IDLE_PREFS|g" \
    -e "s|\[poems/stories/technical docs/music reviews\]|$CREATIVE_OUTPUT|g" \
    -e "s|\[direct/gentle/playful/formal\]|$COMM_STYLE|g" \
    -e "s|\[quality/speed/creativity/accuracy\]|$VALUES_CARES_ABOUT|g" \
    -e "s|<BOT_NAME>|$BOT_NAME|g" \
    -e "s|<USER_NAME>|$USER_NAME|g" \
    -e "s|<VAULT>|$VAULT|g" \
    -e "s|<USER>|$BOT_NAME|g" \
    "$file"
}

# --- OAuth pre-flight (must happen before the systemd service can run) ------
# claude --continue inside a detached tmux session silently exits if the
# user hasn't done first-run OAuth at a real terminal — the TOS gate can't
# be answered headlessly. Catch it here before we wire up the service.
if [ ! -f "$HOME/.claude/.credentials.json" ]; then
  echo
  echo "  ✗ Claude Code first-run OAuth has not been completed."
  echo "    \$HOME/.claude/.credentials.json is missing."
  echo
  echo "  Fix: at a real terminal (this SSH session is fine, NOT inside tmux),"
  echo "       run:  claude"
  echo "       Accept the TOS, walk the OAuth, then exit cleanly."
  echo "       Re-run this script after."
  exit 1
fi

# --- Bootstrap setup-state.md from the template if missing ------------------
# The repo ships setup-state.md.template (versioned) and .gitignores
# setup-state.md (per-bot live values). This means `git pull` never
# clobbers Phase 0 answers a previous run wrote. First run copies once.
if [ ! -f "$VAULT_DEFAULT/setup-state.md" ] \
   && [ -f "$VAULT_DEFAULT/setup-state.md.template" ]; then
  cp "$VAULT_DEFAULT/setup-state.md.template" "$VAULT_DEFAULT/setup-state.md"
  echo "  Created setup-state.md from template (first run on this box)."
fi

# --- Phase 0: collect values ------------------------------------------------

if [ "$REINSTALL_SERVICES_ONLY" = "1" ]; then
  banner "Reinstall-services-only mode — loading Phase 0 from setup-state.md"
  [ -f "$REPO_ROOT/setup-state.md" ] || {
    echo "  ERROR: $REPO_ROOT/setup-state.md missing; can't reinstall services without Phase 0 values." >&2
    exit 1
  }
  BOT_NAME=$(state_read BOT_NAME)
  USER_NAME=$(state_read USER_NAME)
  VAULT=$(state_read VAULT)
  [ -n "$BOT_NAME" ] && [ -n "$VAULT" ] || {
    echo "  ERROR: setup-state.md missing required values (BOT_NAME, VAULT)." >&2
    exit 1
  }
  echo "  BOT_NAME=$BOT_NAME  USER_NAME=$USER_NAME  VAULT=$VAULT"
  echo "  Jumping to Step 4 (systemd units + tmux verification)."
else

banner "Phase 0 — Collect setup values"
echo "  (env var > setup-state.md > prompt — first hit wins)"
echo

prompt_value BOT_NAME       "Bot name (lowercase, becomes the unix user)" "$USER" yes
prompt_value USER_NAME      "Your name (how the bot will address you)"   "${USER^}" yes
prompt_value VAULT          "Vault path (kit clone directory)"           "$VAULT_DEFAULT" yes
prompt_value CANARY_PHRASE  "Canary phrase (3-7 memorable words)"        "" yes
echo
echo "  Optional identity values (Enter accepts the default):"
prompt_value IDLE_PREFS         "Idle-time preference"                        "reading"
prompt_value CREATIVE_OUTPUT    "Preferred creative output"                   "technical docs"
prompt_value COMM_STYLE         "Communication style"                         "direct"
prompt_value VALUES_CARES_ABOUT "Values you care about"                       "quality"
prompt_value USER_ROLE          "Your role / what you work on"                "software engineer"
prompt_value USER_HOBBIES       "Hobbies (free-form)"                         "homelab, gaming"
prompt_value USER_HOURS         "Hours you're typically online"               "evenings EDT"
prompt_value USER_PREFS         "Non-negotiable preferences (one short line)" "be honest, be concise, ask when unsure"

[ -z "${VAULT:-}" ] && { echo "VAULT unresolved; aborting." >&2; exit 1; }

# --- Phase 0.5: bot service passwords ---------------------------------------
#
# Prompt for the SilverBullet + web-shell passwords here, while we're still
# at an interactive console with the operator's hand on the keyboard. The
# typed value flows through bot-secrets.sh store-interactive, which pipes
# it directly into systemd-creds encrypt — plaintext never on disk in the
# clear.
#
# Why prompt now instead of letting setup-runner auto-generate later:
# `bot-secrets.sh generate` produces an unguessable random base64 string
# the operator never sees. Fine for machine-only creds (sb-auth-token,
# web-session-secret) but unusable for credentials the operator actually
# logs in with (sb-user-password, web-ui-password). The "how do I learn a
# password I didn't type" hole has no clean answer, so we close it by
# only ever using passwords the operator typed or pre-set via env var.
#
# Order: BOT_PASSWORD env var → existing cred blob (idempotent re-run) →
# interactive prompt. Non-TTY without env override = hard fail, not
# silent random-generate.

banner "Phase 0.5 — Bot service passwords"

# Slot list. Each entry: <cred-name>|<human label for the prompt>
PROMPT_SLOTS=(
  "sb-user-password|SilverBullet"
  "web-ui-password|web shell"
)

slot_exists() {
  # systemd-creds blobs live at /etc/<bot>/secrets/ mode 700 root — need
  # sudo to even stat. Returns 0 if present, 1 if missing.
  sudo test -f "/etc/${BOT_NAME}/secrets/$1"
}

# Ensure secrets dir exists before any of the slot writes (bot-secrets.sh
# also has its own ensure_dir, but having it here makes the slot_exists
# probe order-independent).
sudo install -d -m 700 -o root -g root "/etc/$BOT_NAME/secrets"

# Resolve PASSWORD_MODE: env var → setup-state.md → prompt.
prompt_value PASSWORD_MODE "Password mode (unified | separate)" "unified" no

# Resolve a unified BOT_PASSWORD if env-supplied. We don't prompt for this;
# it's purely an env-var override for unattended provisioning (CI, ansible,
# `pct exec`). Empty = fall through to interactive prompt below.
BOT_PASSWORD="${BOT_PASSWORD:-}"

if [ -n "$BOT_PASSWORD" ]; then
  # Env-override path. Pipe the value into bot-secrets.sh store for each
  # missing slot (skips slots that already have a cred — idempotent re-run).
  echo "  BOT_PASSWORD env var supplied; using it for the unified slot set."
  for entry in "${PROMPT_SLOTS[@]}"; do
    slot="${entry%%|*}"
    if slot_exists "$slot"; then
      echo "  $slot: already stored, skipping (re-run idempotence)."
    else
      printf '%s' "$BOT_PASSWORD" \
        | BOT_NAME="$BOT_NAME" bash "$KIT/runtime/bot-secrets.sh" store "$slot"
    fi
  done
  unset BOT_PASSWORD
elif [ ! -t 0 ]; then
  # No env override and not interactive. Refuse to silently auto-generate
  # an unreadable password — explicit failure points the operator at
  # BOT_PASSWORD or the interactive path.
  echo "  ERROR: stdin is not a TTY and BOT_PASSWORD is not set." >&2
  echo "  Either: (a) re-run interactively, or (b) export BOT_PASSWORD=… first." >&2
  echo "  Auto-generating an unreadable password is intentionally NOT a fallback." >&2
  exit 1
else
  # Interactive path.
  case "$PASSWORD_MODE" in
    unified)
      # Single prompt, written to every slot. bot-secrets.sh
      # store-interactive prompts + confirms, then encrypts the same
      # plaintext per slot. We invoke once per slot so the operator
      # types twice total (prompt + confirm), not per-slot.
      #
      # Implementation: prompt once via store-interactive into the FIRST
      # missing slot, then for any remaining missing slots, decrypt the
      # just-stored value and pipe it into `store`. Decrypt requires sudo
      # but stays in-process; nothing extra hits disk.
      first_missing=""
      for entry in "${PROMPT_SLOTS[@]}"; do
        slot="${entry%%|*}"
        if ! slot_exists "$slot"; then
          first_missing="$slot"
          break
        fi
      done
      if [ -z "$first_missing" ]; then
        echo "  All password slots already stored, skipping (re-run idempotence)."
      else
        BOT_NAME="$BOT_NAME" bash "$KIT/runtime/bot-secrets.sh" \
          store-interactive "$first_missing" "$BOT_NAME services (unified)"
        for entry in "${PROMPT_SLOTS[@]}"; do
          slot="${entry%%|*}"
          [ "$slot" = "$first_missing" ] && continue
          if slot_exists "$slot"; then
            echo "  $slot: already stored, skipping."
          else
            # Reuse the value we just stored. systemd-creds decrypt to
            # stdout, piped straight into store for the next slot.
            sudo systemd-creds decrypt "/etc/$BOT_NAME/secrets/$first_missing" - \
              | BOT_NAME="$BOT_NAME" bash "$KIT/runtime/bot-secrets.sh" store "$slot"
          fi
        done
      fi
      ;;
    separate)
      # One prompt per slot. Each one is its own store-interactive call.
      for entry in "${PROMPT_SLOTS[@]}"; do
        slot="${entry%%|*}"
        label="${entry##*|}"
        if slot_exists "$slot"; then
          echo "  $slot: already stored, skipping."
        else
          BOT_NAME="$BOT_NAME" bash "$KIT/runtime/bot-secrets.sh" \
            store-interactive "$slot" "$label"
        fi
      done
      ;;
    *)
      echo "  ERROR: unknown PASSWORD_MODE='$PASSWORD_MODE' (expected: unified|separate)" >&2
      exit 1
      ;;
  esac
fi

# Optional: set the Linux user's login password from the same flow.
#
# Default OFF — SSH-key-only is the working model on the existing
# nlbot-test box and matches the kit's threat model (tailnet-only, no
# internet-facing surface). The /etc/shadow store is a DIFFERENT security
# domain from the systemd-creds blobs above: shadow survives a creds-blob
# wipe, blobs survive a /etc/shadow rotation. Worth a separate opt-in
# rather than a silent default-on.
#
# Runs HERE — before the Step 4 NOPASSWD grant lands — so it uses the
# operator's existing interactive sudo. That way we don't have to add
# /usr/bin/chpasswd to the kit's steady-state NOPASSWD template.
if [ -t 0 ] && [ "$(state_read LINUX_PASSWORD_SET)" != "yes" ] \
            && [ "$(state_read LINUX_PASSWORD_SET)" != "no" ]; then
  read -rp "  Also set the Linux login password for the $BOT_NAME account? [y/N — N keeps the box SSH-key-only, recommended]: " linux_pw_choice
  linux_pw_choice="${linux_pw_choice:-n}"
  case "$linux_pw_choice" in
    y|Y|yes|YES)
      if [ "$PASSWORD_MODE" = "unified" ] && slot_exists "sb-user-password"; then
        # Reuse the unified password the operator just typed. Decrypt to
        # stdout → prepend "user:" → pipe to chpasswd. Plaintext stays
        # in-process through the pipe.
        echo "  Setting $BOT_NAME login password to the unified password value."
        sudo systemd-creds decrypt "/etc/$BOT_NAME/secrets/sb-user-password" - \
          | awk -v u="$BOT_NAME" '{print u":"$0}' \
          | sudo chpasswd
      else
        # separate mode (or unified but no sb-user-password yet — shouldn't
        # happen given the flow above, but defensive). Prompt fresh, no
        # blob storage — /etc/shadow is the only sink.
        while true; do
          printf "  Enter Linux login password for %s: " "$BOT_NAME" >&2
          IFS= read -rs lpw1; printf "\n" >&2
          printf "  Confirm Linux login password for %s: " "$BOT_NAME" >&2
          IFS= read -rs lpw2; printf "\n" >&2
          if [ -z "$lpw1" ]; then
            echo "  ERROR: password cannot be empty — try again." >&2
            continue
          fi
          if [ "$lpw1" != "$lpw2" ]; then
            echo "  ERROR: passwords don't match — try again." >&2
            continue
          fi
          break
        done
        printf '%s:%s\n' "$BOT_NAME" "$lpw1" | sudo chpasswd
        unset lpw1 lpw2
      fi
      echo "  ✓ Linux user password updated for $BOT_NAME."
      state_write LINUX_PASSWORD_SET "yes"
      ;;
    *)
      echo "  Linux user password unchanged (SSH-key-only). Skipping."
      state_write LINUX_PASSWORD_SET "no"
      ;;
  esac
else
  prior=$(state_read LINUX_PASSWORD_SET)
  if [ "$prior" = "yes" ] || [ "$prior" = "no" ]; then
    echo "  Linux user password choice already recorded in setup-state.md ($prior); skipping re-prompt."
  fi
fi

state_write PASSWORD_MODE "$PASSWORD_MODE"

# --- Step 1: prereq check ---------------------------------------------------
#
# setup-status.sh exits 1 whenever ANY part of the kit is incomplete —
# including the vault skeleton + claude-code.service that THIS script
# is about to install. So we can't gate on its exit code directly.
# Instead, run it once, capture the output, and only abort if a [✗]
# appears in the "System prerequisites" or "Bot user" sections (the
# things bootstrap.md owns; everything else is what we're here to do).

banner "Step 1 — Prereqs (delegating to setup-status.sh)"
if [ -x "$KIT/runtime/setup-status.sh" ]; then
  PROBE=$(bash "$KIT/runtime/setup-status.sh" 2>&1 || true)
  echo "$PROBE"
  echo
  # Extract just the System + Bot-user sections (between their headers
  # and the next major section "Vault and bot service") and check those
  # lines for [✗] markers. Anything before "Vault and bot service" is a
  # genuine prereq the script can't fix; anything after is our own job.
  PREREQ_FAILS=$(printf '%s\n' "$PROBE" \
    | awk '/^Vault and bot service/{exit} /\[✗\]/{print}')
  if [ -n "$PREREQ_FAILS" ]; then
    echo "  ✗ Genuine prereq failures (bootstrap.md territory):" >&2
    printf '%s\n' "$PREREQ_FAILS" | sed 's/^/      /' >&2
    echo "    Resolve those, then re-run this script." >&2
    exit 1
  fi
  echo "  ✓ System + bot-user prereqs OK. Vault/service items below will be addressed by Steps 2-4."
else
  skip "setup-status.sh not executable (continuing — re-bootstrap recommended)"
fi

# --- Step 2: vault skeleton + identity seed + placeholder substitution ------

banner "Step 2 — Vault skeleton + identity seed"
mkdir -p "$VAULT" "$VAULT/journals/fiction" "$VAULT/handoffs" "$VAULT/processes"

# Seed setup-state.md at repo root from the kit's template if absent.
if [ ! -f "$REPO_ROOT/setup-state.md" ]; then
  cp "$KIT/setup-state.md.template" "$REPO_ROOT/setup-state.md"
fi

# Seed top-level identity files into the vault. -n = don't clobber edits.
[ -f "$VAULT/CLAUDE.md" ]       || cp "$KIT/CLAUDE-nate.md"            "$VAULT/CLAUDE.md"
# .claude/ is regenerated from dot-claude/ by refresh-claude-dir.sh after
# Phase 0 values are written below. Lives at repo root, not in vault.
[ -f "$VAULT/identity.md" ]     || cp "$KIT/templates/identity.md"     "$VAULT/identity.md"
[ -f "$VAULT/user-profile.md" ] || cp "$KIT/templates/user-profile.md" "$VAULT/user-profile.md"
[ -f "$VAULT/soul-loop.md" ]    || cp "$KIT/templates/soul-loop.md"    "$VAULT/soul-loop.md"

# SilverBullet vault-page + process-doc seeds. -n on cp = no-clobber.
cp -n "$KIT/templates/vault-pages/"*.md "$VAULT/"            2>/dev/null || true
cp -n "$KIT/templates/processes/"*.md   "$VAULT/processes/"  2>/dev/null || true

# SilverBullet page-template seeds (_templates/ is SB's Page-From-Template
# source). Recurse to copy the subtree; -n preserves any local edits.
if [ -d "$KIT/templates/vault-pages/_templates" ] && [ ! -d "$VAULT/_templates" ]; then
  cp -rn "$KIT/templates/vault-pages/_templates" "$VAULT/_templates"
fi
touch "$VAULT/journals/journal.md"

# Seed bot-runtime cron-prompts at repo root (NOT in vault). These are
# slash-command invocations the cron fires + the inject script. They're
# kit-managed source at $KIT/runtime/cron-prompts/ but the runtime copies
# live at $REPO_ROOT/cron-prompts/ so the bot can write state files
# (.soul-loop-last-action, job-log.md) next to them.
mkdir -p "$REPO_ROOT/cron-prompts"
cp -n "$KIT/runtime/cron-prompts/"*.md "$REPO_ROOT/cron-prompts/" 2>/dev/null || true
[ -f "$REPO_ROOT/cron-prompts/inject-prompt.sh" ] || \
  cp "$KIT/runtime/inject-prompt.sh" "$REPO_ROOT/cron-prompts/inject-prompt.sh"
chmod +x "$REPO_ROOT/cron-prompts/inject-prompt.sh"

echo "  Files seeded. Now substituting placeholders…"

# Top-level seeded files
for f in CLAUDE.md identity.md user-profile.md soul-loop.md \
         index.md dashboard.md handoffs.md journals.md \
         processes.md inbox.md decisions.md CONFIG.md; do
  substitute_placeholders "$VAULT/$f"
done

# Process docs + SB page templates (one-shot; user-facing pages, hand-edits expected).
for f in "$VAULT/processes/"*.md "$VAULT/_templates/"*.md; do
  substitute_placeholders "$f"
done

# Persist Phase 0 values into setup-state.md
state_write BOT_NAME            "$BOT_NAME"
state_write USER_NAME           "$USER_NAME"
state_write VAULT               "$VAULT"
state_write OS_USER             "$USER"
state_write CANARY_PHRASE       "$CANARY_PHRASE"
state_write IDLE_PREFS          "$IDLE_PREFS"
state_write CREATIVE_OUTPUT     "$CREATIVE_OUTPUT"
state_write COMM_STYLE          "$COMM_STYLE"
state_write VALUES_CARES_ABOUT  "$VALUES_CARES_ABOUT"
state_write USER_ROLE           "$USER_ROLE"
state_write USER_HOBBIES        "$USER_HOBBIES"
state_write USER_HOURS          "$USER_HOURS"
state_write USER_PREFS          "$USER_PREFS"
sed -i "s|^Last updated:.*|Last updated: $(date '+%Y-%m-%d %H:%M')|" "$REPO_ROOT/setup-state.md"
sed -i "s|^Current phase:.*|Current phase: pre-step-5|" "$REPO_ROOT/setup-state.md"

# Generate <REPO_ROOT>/.claude/ from kit/dot-claude/ now that setup-state.md
# has the Phase 0 values. refresh-claude-dir.sh handles first-install and
# re-sync uniformly; the post-merge hook installed below re-runs it on
# every git pull, so kit updates to agents + slash commands propagate
# automatically.
bash "$KIT/runtime/refresh-claude-dir.sh"

# Pre-install SilverBullet plug bundles into <VAULT>/_plug/ so TreeView
# is present at SB's first startup without requiring a manual
# "Plugs: Update" command-palette action.
VAULT="$VAULT" bash "$KIT/runtime/install-plugs.sh" || \
  echo "  WARN: plug install reported failures — open SB and run \"Plugs: Update\" once to recover"

# Install the post-merge hook at <REPO_ROOT>/.git/hooks/post-merge so kit
# pulls auto-refresh .claude/ + vault-page seeds + plug bundles.
# `git rev-parse --git-dir` returns a path relative to its CWD by default,
# so we resolve it to an absolute path before joining. Without this, the
# install ended up at `./.git/hooks/post-merge` relative to whatever CWD
# the script was invoked from, NOT relative to $REPO_ROOT. Caught on
# ansi's 2026-05-12 e2e #2 walk (Finding 8) where the hook reported
# installed but was missing post-reboot.
GIT_DIR_REL=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "$REPO_ROOT/.git")
case "$GIT_DIR_REL" in
  /*) GIT_DIR_PATH="$GIT_DIR_REL" ;;
  *)  GIT_DIR_PATH="$REPO_ROOT/$GIT_DIR_REL" ;;
esac
mkdir -p "$GIT_DIR_PATH/hooks"
if install -m 755 "$KIT/runtime/hooks/post-merge" "$GIT_DIR_PATH/hooks/post-merge" \
   && [ -x "$GIT_DIR_PATH/hooks/post-merge" ]; then
  echo "  ✓ .claude/ generated and post-merge hook installed at $GIT_DIR_PATH/hooks/post-merge"
else
  echo "  ✗ post-merge hook FAILED to install at $GIT_DIR_PATH/hooks/post-merge" >&2
  echo "    (.claude/ was rendered but auto-refresh on git pull is not wired)" >&2
fi

# Verify no leftover placeholders. Only inspect the files we actually
# seeded into the vault — the kit's source docs (README.md, bootstrap.md,
# setup-orchestrator.md, etc.) legitimately reference <BOT_NAME>/<VAULT>
# as documentation and aren't templates the user needs to substitute.
SEEDED_FILES=(
  "$VAULT/CLAUDE.md" "$VAULT/identity.md" "$VAULT/user-profile.md"
  "$VAULT/soul-loop.md" "$VAULT/index.md" "$VAULT/dashboard.md"
  "$VAULT/handoffs.md" "$VAULT/journals.md" "$VAULT/processes.md"
  "$VAULT/inbox.md" "$VAULT/decisions.md" "$REPO_ROOT/start-claude.sh"
)
LEFTOVER=""
for f in "${SEEDED_FILES[@]}"; do
  [ -f "$f" ] || continue
  if grep -qE '\[Your Bot|\[Nate\]|\[CHOOSE YOUR|<USER>|<USER_NAME>|<VAULT>|<BOT_NAME>|<KIT>|<REPO_ROOT>' "$f"; then
    LEFTOVER+="$f"$'\n'
  fi
done
# Also check the seeded processes/ + .claude/ (at repo root) + _templates/ trees
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -qE '\[Your Bot|\[Nate\]|\[CHOOSE YOUR|<USER>|<USER_NAME>|<VAULT>|<BOT_NAME>|<KIT>|<REPO_ROOT>' "$f"; then
    LEFTOVER+="$f"$'\n'
  fi
done < <(find "$VAULT/processes" "$REPO_ROOT/.claude" "$VAULT/_templates" -name '*.md' 2>/dev/null)

if [ -n "$LEFTOVER" ]; then
  echo "  ⚠ Files still contain placeholders (edit by hand if needed):"
  printf '%s' "$LEFTOVER" | sed 's/^/      /'
else
  echo "  ✓ All Phase 0 placeholders substituted."
fi

# --- Step 3: disable runaway keybindings ------------------------------------

banner "Step 3 — Disable session-killing keybindings"
mkdir -p "$HOME/.claude"
KB="$HOME/.claude/keybindings.json"
if [ -f "$KB" ] && grep -q 'ctrl+x ctrl+e' "$KB"; then
  skip "keybindings.json already disables ctrl+x ctrl+e / ctrl+x ctrl+k"
else
  cat > "$KB" <<'KBEOF'
{
  "bindings": [
    { "keys": "ctrl+x ctrl+e", "action": "none" },
    { "keys": "ctrl+x ctrl+k", "action": "none" }
  ]
}
KBEOF
  echo "  Wrote $KB"
fi

fi   # end of "if not REINSTALL_SERVICES_ONLY" block (matches the `else` above Phase 0)

# --- Step 4: persistence (start-claude.sh + systemd unit + enable) ----------

banner "Step 4 — Persistence (start-claude.sh + systemd unit)"

# Encrypted credentials directory. systemd-creds blobs live here, owned by
# root mode 700 — the bot user can `ls` via sudo to see names but cannot
# read the ciphertext. See templates/processes/security.md.
sudo install -d -m 700 -o root -g root "/etc/$BOT_NAME/secrets"
echo "  Ensured /etc/$BOT_NAME/secrets exists (root:root, 700)"

# bot-secrets.sh + migrate-secrets.sh stay in $KIT/runtime/ and are
# invoked directly from there. No staging into the vault — keeps the
# kit-source / runtime-state boundary clean.

# Render + substitute start-claude.sh into the repo root (bot CWD).
# claude-code.service ExecStart points here. The script template at
# $KIT/runtime/start-claude.sh stays untouched.
cp "$KIT/runtime/start-claude.sh" "$REPO_ROOT/start-claude.sh"
substitute_placeholders "$REPO_ROOT/start-claude.sh"
chmod +x "$REPO_ROOT/start-claude.sh"
echo "  Wrote $REPO_ROOT/start-claude.sh"

# Optional setup-bootstrap.sh sidecar (start-claude.sh probes for it).
if [ -f "$KIT/runtime/setup-bootstrap.sh" ]; then
  cp "$KIT/runtime/setup-bootstrap.sh" "$REPO_ROOT/setup-bootstrap.sh"
  chmod +x "$REPO_ROOT/setup-bootstrap.sh"
  echo "  Wrote $REPO_ROOT/setup-bootstrap.sh"
fi

# Drop the systemd unit
sudo tee /etc/systemd/system/claude-code.service > /dev/null <<EOF
[Unit]
Description=Claude Code persistent tmux session
After=network-online.target
Wants=network-online.target
# Cap restart loops at 10 within 60s so a genuine break doesn't flood the
# journal — without this, RestartSec=5 will hammer indefinitely. Caught
# during nlbot-test dry-run when a misconfigured start-claude.sh racked
# up 34 restart attempts in seconds.
StartLimitBurst=10
StartLimitIntervalSec=60

[Service]
Type=forking
User=$BOT_NAME
WorkingDirectory=$REPO_ROOT
ExecStart=$REPO_ROOT/start-claude.sh
ExecStop=/usr/bin/tmux kill-session -t claude
Restart=on-failure
RestartSec=5
Environment=LANG=C.utf8
Environment=LC_ALL=C.utf8

[Install]
WantedBy=multi-user.target
EOF
echo "  Wrote /etc/systemd/system/claude-code.service"

# Sibling tmux service for a regular bash shell — accessible via the web
# shell at ?session=shell, or `tmux attach -t shell` over SSH. Same User,
# same Restart cap as claude-code.service. Independent of Claude — can be
# stopped/restarted without disturbing the bot.
sudo tee /etc/systemd/system/${BOT_NAME}-shell.service > /dev/null <<EOF
[Unit]
Description=Bot user persistent shell tmux session
After=network-online.target claude-code.service
Wants=network-online.target
StartLimitBurst=10
StartLimitIntervalSec=60

[Service]
# oneshot + RemainAfterExit because by the time this service starts, the
# tmux server is already running (claude-code.service started it). The
# \`tmux new-session\` call is just a client request that returns immediately
# after creating the session, so Type=forking has no daemon to track and
# the unit immediately deactivates — the session itself lives in the
# existing tmux server process. Caught on fenbot 2026-05-11 retrofit.
Type=oneshot
RemainAfterExit=yes
User=$BOT_NAME
Environment=HOME=/home/$BOT_NAME
Environment=LANG=C.utf8
Environment=LC_ALL=C.utf8
# Idempotent: create the session only if missing. has-session returns 0
# when found, non-zero when not — so the || branch creates on miss.
ExecStart=/bin/bash -c 'tmux has-session -t shell 2>/dev/null || tmux new-session -d -s shell -c /home/$BOT_NAME /bin/bash -l'
ExecStop=/usr/bin/tmux kill-session -t shell

[Install]
WantedBy=multi-user.target
EOF
echo "  Wrote /etc/systemd/system/${BOT_NAME}-shell.service"

sudo systemctl daemon-reload
sudo systemctl enable --now claude-code.service
sudo systemctl enable --now ${BOT_NAME}-shell.service

# Verify BOTH tmux sessions came up. Give them a few seconds to spawn.
echo "  Waiting for tmux sessions to register…"
for i in 1 2 3 4 5; do
  if tmux ls 2>/dev/null | grep -q '^claude:' && \
     tmux ls 2>/dev/null | grep -q '^shell:'; then
    echo "  ✓ tmux sessions 'claude' and 'shell' are up."
    break
  fi
  sleep 1
done
if ! tmux ls 2>/dev/null | grep -q '^claude:'; then
  echo "  ✗ tmux session 'claude' did NOT come up." >&2
  echo "    Check: sudo journalctl -u claude-code.service -n 50" >&2
  exit 1
fi
if ! tmux ls 2>/dev/null | grep -q '^shell:'; then
  echo "  ✗ tmux session 'shell' did NOT come up." >&2
  echo "    Check: sudo journalctl -u ${BOT_NAME}-shell.service -n 50" >&2
  exit 1
fi

# --- Done ------------------------------------------------------------------

banner "Steps 1-4 complete — next, manual"
cat <<EOF

  1. tmux attach -t claude
     Verify the ❯ prompt renders correctly (not __ or ??).
     Ctrl-b then d to detach — DO NOT exit the session.

  2. Grant scoped NOPASSWD sudo (the kit's "hand over the keys" gate):

        sudo tee /etc/sudoers.d/$BOT_NAME >/dev/null <<EOS
# Service + container + cron management
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/systemctl
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/crontab
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/docker
# Service-file + log inspection (setup-runner step-7 step-9)
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/tee
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/journalctl
# Tailscale serve (setup-runner step-6 + step-7 publish via tailscale)
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/tailscale
# systemd-creds + secret-blob ops (runtime/bot-secrets.sh, migrate-secrets.sh,
# silverbullet-up.sh — the encrypted-secrets path needs all of these to run
# unattended from the soul-loop)
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/systemd-creds
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/install
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/mktemp
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/rm
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/test
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/bin/ls
EOS
        sudo chmod 440 /etc/sudoers.d/$BOT_NAME
        sudo visudo -cf /etc/sudoers.d/$BOT_NAME

     Verify the grant is active (lists every NOPASSWD entry $BOT_NAME has):
        sudo -u $BOT_NAME sudo -ln | grep NOPASSWD

     Confirm systemd is recent enough for the encrypted-secrets path
     (systemd >= 250 ships systemd-creds; setup-runner steps 6–7 need it):
        sudo -u $BOT_NAME sudo -n /usr/bin/systemd-analyze has-tpm2 \\
          && echo "systemd OK (TPM available)" \\
          || echo "systemd OK (no TPM — host-key fallback)"

     (Note: \`systemd-creds has-tpm2\` is the older spelling; Debian 13's
     systemd renamed it to \`systemd-analyze has-tpm2\`. Both work for now
     via a redirect, but the new spelling is silent.)

  3. sudo reboot
     Verify the box comes back clean and claude-code.service auto-starts.

  4. After reboot, the bot drives Steps 5-9 via setup-runner.
     Watch progress:  bash $KIT/runtime/setup-status.sh

EOF
