#!/usr/bin/env bash
# first-time-setup.sh — automates Steps 1-4 of first-time-setup.md.
#
# Drops the vault skeleton, copies kit files, substitutes Phase 0
# placeholders (<USER_NAME>, [Your Bot's Name], <VAULT>, etc.), installs
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
#
# --non-interactive: provisioner mode. prompt_value fails fast on missing
# required values instead of dropping to `read -rp`. Combined with env vars
# (BOT_NAME, VAULT, BOT_PASSWORD), enables fully unattended provisioning
# from CI / image-bake pipelines. The bash bootstrap collects only the
# load-bearing values; identity/personality values (USER_NAME, CANARY_PHRASE,
# the eight personality fields, TELEGRAM_ENABLED) are deferred to /setup
# and the new "phase-0-interview-pending" phase state. See the
# jaunty-swimming-forest plan for the provisioner-vs-user split.
REINSTALL_SERVICES_ONLY=0
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --reinstall-services-only) REINSTALL_SERVICES_ONLY=1 ;;
    --non-interactive)         NON_INTERACTIVE=1 ;;
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

  # --non-interactive provisioner mode: refuse to drop into `read -rp`.
  # If we got here, the value wasn't supplied via env or setup-state.md.
  # Use the default if one's available; otherwise hard-fail with a clear
  # message naming the missing var. Provisioner can re-invoke with the
  # right env var.
  if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
    if [ -n "$default" ]; then
      eval "$var_name=$(printf '%q' "$default")"
      echo "  $var_name = $default  (non-interactive: applied default)"
      return 0
    fi
    if [ "$required" = "yes" ]; then
      echo "  ERROR: $var_name is required but unset (--non-interactive mode)" >&2
      echo "  Re-invoke with: $var_name=<value> $0 --non-interactive [...]" >&2
      exit 1
    fi
    # Optional + no default + non-interactive → leave empty.
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

# Replace Phase 0 placeholders in one file. Delegated to the standalone
# `substitute-placeholders.sh` (sourced for in-process function access)
# so the same substitution logic is also reusable by the `/setup` interview
# command at /setup time, AFTER the end user has typed his answers into setup-
# state.md. The function reads shell vars first, falls back to setup-
# state.md if env unset, and uses ${VAR:-} defaults under `set -u`.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/substitute-placeholders.sh"

# --- OAuth pre-flight (advisory only post-F42) ------------------------------
# Before F42: this gate hard-aborted the script if ~/.claude/.credentials.json
# was missing, on the theory that claude-code.service would crashloop without
# OAuth done. That theory was right but the gate forced the provisioner to
# SSH in and walk OAuth before bash could run — wiping out the kit's stated
# UX promise that the end user's first action is opening the web shell URL in a
# browser. F42 (fenbot02 walk 2026-05-12) inverts the order: bash provisioner
# runs without OAuth, Phase 5 brings up the web shell, and the end user walks OAuth
# via the web shell's bash session (`?session=shell`) AFTER opening the URL.
# claude-code.service still crashloops in the background until OAuth lands,
# but the start-claude.sh while-loop wrapper absorbs that (each iteration is
# its own claude exit, not a systemd-visible failure) and once OAuth is
# complete the next claude launch succeeds. the end user then switches to the claude
# session and types /setup.
#
# The gate stays as an ADVISORY warning so an operator who *is* OAuth-walking
# on the provisioner side (the old flow) still sees the prompt and knows
# what to expect; the script no longer aborts.
if [ ! -f "$HOME/.claude/.credentials.json" ]; then
  echo
  echo "  ℹ Claude Code first-run OAuth has not been completed."
  echo "    \$HOME/.claude/.credentials.json is missing — that is OK for the"
  echo "    F42 zero-SSH flow. the end user walks OAuth via the web shell after the"
  echo "    bash provisioner finishes: open the web shell URL, switch to the"
  echo "    'shell' session (use the URL param ?session=shell), run \`claude\`"
  echo "    and walk /login in the browser. claude-code.service will start"
  echo "    succeeding from that point and /setup becomes available."
  echo
  echo "  If you would rather walk OAuth here on the provisioner side (the"
  echo "  pre-F42 flow), Ctrl-C now, run \`claude\` at this same shell, walk"
  echo "  /login, exit, and re-run this script."
  echo
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

banner "Phase 0 — Collect provisioning values"
echo "  (env var > setup-state.md > prompt — first hit wins)"
echo
echo "  Only BOT_NAME and VAULT are bash-collected. Identity values (your"
echo "  name, canary phrase, communication style, hobbies, etc.) are filled"
echo "  in by the user via /setup after the bot is up — see jaunty-swimming"
echo "  -forest plan / first-time-setup.md provisioner-vs-user split."
echo

prompt_value BOT_NAME  "Bot name (lowercase, becomes the unix user)" "$USER"             yes
prompt_value VAULT     "Vault path (kit clone directory)"            "$VAULT_DEFAULT"    yes

# Non-interactive shortcut: provisioner can override the friendly defaults
# above with env vars and skip ALL prompts. Used for unattended provisioning
# (CI, image-bake pipelines, repeated dev installs). Combined with the
# `--non-interactive` flag (which makes prompt_value fail-fast instead of
# falling through to `read -rp`), this gives a clean scripted provisioning
# path. If --non-interactive and any required value is missing, the prompt
# function will already have aborted.

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

# --- Machine-only credentials ----------------------------------------------
#
# sb-auth-token (SilverBullet API/sync token) and web-session-secret (web
# shell session signing key) are credentials the operator never needs to
# see — services consume them, humans don't. setup-runner Steps 6/7 are
# the canonical generation path, but those don't fire if Claude OAuth
# is blocked. Generate them here so the box is fully credential-equipped
# after Phase 0.5 alone and SilverBullet + the web shell can come up
# without waiting on OAuth (kit-e2e-test-3 / nlbot0 F18).
#
# Idempotent: skip if the cred is already on disk.
banner "Phase 0.5 — Machine-only credentials"
for entry in "sb-auth-token|24" "web-session-secret|32"; do
  name="${entry%%|*}"
  length="${entry##*|}"
  if slot_exists "$name"; then
    echo "  $name: already stored, skipping."
  else
    BOT_NAME="$BOT_NAME" bash "$KIT/runtime/bot-secrets.sh" generate "$name" "$length"
  fi
done

# Also store web-ui-username if unset. Defaults to BOT_NAME; encrypted
# blob so the service unit can LoadCredentialEncrypted= it like any
# other secret. Stays a one-line constant; the operator can override
# later via `echo "<name>" | bot-secrets.sh store web-ui-username`.
if ! slot_exists "web-ui-username"; then
  printf '%s' "$BOT_NAME" \
    | BOT_NAME="$BOT_NAME" bash "$KIT/runtime/bot-secrets.sh" store web-ui-username
fi

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
[ -f "$VAULT/CLAUDE.md" ]       || cp "$KIT/CLAUDE.md.template"            "$VAULT/CLAUDE.md"
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
# (.soul-loop-last-action, .secretary-last-hash) next to them. job-log.md lives in the vault root so SilverBullet indexes it.
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

# Persist Phase 0 values into setup-state.md. Only BOT_NAME / VAULT /
# OS_USER are populated by the bash bootstrap; the rest stay empty (the
# /setup interview will fill them based on the user's answers, then re-run
# substitute-placeholders.sh on the seeded vault files).
state_write BOT_NAME            "$BOT_NAME"
state_write VAULT               "$VAULT"
state_write OS_USER             "$USER"
state_write USER_NAME           "${USER_NAME:-}"
state_write CANARY_PHRASE       "${CANARY_PHRASE:-}"
state_write IDLE_PREFS          "${IDLE_PREFS:-}"
state_write CREATIVE_OUTPUT     "${CREATIVE_OUTPUT:-}"
state_write COMM_STYLE          "${COMM_STYLE:-}"
state_write VALUES_CARES_ABOUT  "${VALUES_CARES_ABOUT:-}"
state_write USER_ROLE           "${USER_ROLE:-}"
state_write USER_HOBBIES        "${USER_HOBBIES:-}"
state_write USER_HOURS          "${USER_HOURS:-}"
state_write USER_PREFS          "${USER_PREFS:-}"
state_write TELEGRAM_ENABLED    "${TELEGRAM_ENABLED:-}"
sed -i "s|^Last updated:.*|Last updated: $(date '+%Y-%m-%d %H:%M')|" "$REPO_ROOT/setup-state.md"
# Initial phase is phase-0-interview-pending. setup-runner is gated on this
# (the runner's tier-1 probe returns "interview pending — user must type
# /setup" until the interview advances the phase). soul-loop sees the
# non-done phase and dispatches setup-runner, which then no-ops cleanly.
sed -i "s|^Current phase:.*|Current phase: phase-0-interview-pending|" "$REPO_ROOT/setup-state.md"

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
  if grep -qE '\[Your Bot|\[CHOOSE YOUR|<USER>|<USER_NAME>|<USER_PREFS>|<USER_ROLE>|<USER_HOBBIES>|<USER_HOURS>|<TIMEZONE>|<VAULT>|<BOT_NAME>|<KIT>|<REPO_ROOT>' "$f"; then
    LEFTOVER+="$f"$'\n'
  fi
done
# Also check the seeded processes/ + .claude/ (at repo root) + _templates/ trees
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -qE '\[Your Bot|\[CHOOSE YOUR|<USER>|<USER_NAME>|<USER_PREFS>|<USER_ROLE>|<USER_HOBBIES>|<USER_HOURS>|<TIMEZONE>|<VAULT>|<BOT_NAME>|<KIT>|<REPO_ROOT>' "$f"; then
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
# Claude Code 2.1.139's parser wants:
#   - Top-level OBJECT with a `bindings` array (NOT a bare top-level array).
#   - Each block has a `context` from the documented enum (Global, Chat,
#     Autocomplete, Confirmation, Help, Transcript, HistorySearch, Task,
#     ThemePicker, Settings, Tabs, Attachments, Footer, MessageSelector,
#     DiffDialog, ModelPicker, Select, Plugin, Scroll, Doctor) — strings
#     like "input" are rejected as "Unknown context".
#   - `bindings` value inside each block is an object mapping key → action
#     string or `null` to disable.
# Earlier kit revisions (F23 first pass / e707f8f) shipped the wrong
# shape because the /doctor error message only described the inner-block
# requirement, not the outer wrapper. ansi empirically validated the
# correct shape on nlbot0 by iterating against the live parser until
# /doctor went clean (F25, sidechat 2741). The check-existing-and-skip
# guard stays string-based so it works against any prior schema for
# upgrade.
if [ -f "$KB" ] && grep -q 'ctrl+x ctrl+e' "$KB"; then
  skip "keybindings.json already disables ctrl+x ctrl+e / ctrl+x ctrl+k"
else
  cat > "$KB" <<'KBEOF'
{
  "bindings": [
    {
      "context": "Global",
      "bindings": {
        "ctrl+x ctrl+e": null,
        "ctrl+x ctrl+k": null
      }
    }
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
# PartOf= ties this unit's lifecycle to claude-code.service. When
# claude-code restarts (e.g., the F21 wrapper respawns claude after a
# clean exit, taking the underlying tmux server with it), systemd
# propagates the restart here so the shell session gets re-created in
# the new tmux server. Without this, the unit stayed in active(exited)
# from its first successful run and the shell tmux session disappeared
# silently — web shell's ?session=shell URL then hit "can't find
# session: shell". Caught on nlbot0 (F24, sidechat msg 2737).
PartOf=claude-code.service
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

# --- Step 5: web shell (so the end user can connect at phase-0-interview-pending) ---
#
# The web shell used to be set up by setup-runner step-7-web-shell, which
# runs only AFTER the end user has typed /setup. But the F34 provisioner-vs-user
# split tells the end user that the first action is to open the web shell URL and type
# /setup THERE — so a web shell that only comes up post-/setup is a
# chicken-and-egg (the end user cannot reach the bot to type the thing that
# brings up the surface the end user is supposed to type into). Caught on the
# fenbot01 walk 2026-05-12 (F41). Moving it into the provisioner makes
# the URL in HANDOFF-TO-NATE.txt actually load when the end user opens it.
#
# step-7-web-shell in setup-runner becomes a probe-and-advance no-op
# from this point on (it stays in the phase enum so re-runs against
# older state files still walk cleanly).
banner "Step 5: web shell"

# F43 (2026-05-13): pre-accept the bypass-permissions disclaimer so the end user
# does not see it on first connect. Claude Code reads
# `~/.claude/settings.json` and skips the disclaimer when
# `skipDangerousModePermissionPrompt: true`. (The companion
# "trust this folder" prompt is NOT pre-acceptable yet — no
# trustedDirectories key exists in Claude Code as of this commit;
# upstream feature request #12737. HANDOFF prose still mentions
# trust + theme + login as one-time prompts.) Merge with any
# existing settings.json rather than clobber.
mkdir -p "$HOME/.claude"
if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq '. + { "skipDangerousModePermissionPrompt": true }' \
    "$HOME/.claude/settings.json" > "$tmp" \
    && mv "$tmp" "$HOME/.claude/settings.json" \
    || rm -f "$tmp"
else
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "skipDangerousModePermissionPrompt": true
}
JSON
fi
echo "  Pre-accepted bypass-permissions disclaimer in ~/.claude/settings.json"

# Machine-only secret. Stored as a systemd-creds blob; the operator never
# sees the plaintext. web-ui-username + web-ui-password were already
# handled by Phase 0.5.
if [ ! -f "/etc/${BOT_NAME}/secrets/web-session-secret" ]; then
  bash "$KIT/runtime/bot-secrets.sh" generate web-session-secret 32 >/dev/null
  echo "  Generated web-session-secret (encrypted blob at /etc/${BOT_NAME}/secrets/)"
fi
if [ ! -f "/etc/${BOT_NAME}/secrets/web-ui-username" ]; then
  printf '%s' "$BOT_NAME" | bash "$KIT/runtime/bot-secrets.sh" store web-ui-username >/dev/null
  echo "  Stored web-ui-username = $BOT_NAME"
fi

# npm install in the kit's web-terminal/. The systemd unit's
# WorkingDirectory points here; node_modules lives alongside server.js.
# Skip the install if node_modules is already populated (idempotent).
if [ ! -d "$KIT/web-terminal/node_modules" ]; then
  echo "  Running npm install in $KIT/web-terminal/ (may take 30-60s)…"
  (cd "$KIT/web-terminal" && npm install --no-audit --no-fund --silent) || {
    echo "  ✗ npm install failed in $KIT/web-terminal/" >&2
    echo "    Check that node 20+ is installed and the directory is writable." >&2
    exit 1
  }
  echo "  ✓ npm install complete"
else
  echo "  npm dependencies already installed (node_modules present)"
fi

# Write a minimal .env. The real credentials are loaded from systemd-creds
# at service start; this file just pins PORT so server.js does not fall
# back to a different default.
cat > "$KIT/web-terminal/.env" <<EOF
PORT=3000
# SESSION_SECRET, UI_USERNAME, UI_PASSWORD are loaded from systemd-creds
# blobs at service start. See $KIT/web-terminal/claude-web.service.
EOF
chmod 600 "$KIT/web-terminal/.env"
echo "  Wrote $KIT/web-terminal/.env"

# Render the systemd unit template into /etc/systemd/system/. Mirrors the
# render-and-install pattern used by claude-code.service + shell.service.
sudo tee "/etc/systemd/system/${BOT_NAME}-web.service" >/dev/null < <(
  sed \
    -e "s|<USER>|$BOT_NAME|g" \
    -e "s|<BOT_NAME>|$BOT_NAME|g" \
    -e "s|<KIT>|$KIT|g" \
    -e "s|<VAULT>|$VAULT|g" \
    "$KIT/web-terminal/claude-web.service"
)
echo "  Wrote /etc/systemd/system/${BOT_NAME}-web.service"

sudo systemctl daemon-reload
sudo systemctl enable --now "${BOT_NAME}-web.service"

# Verify the service came up.
sleep 2
if ! systemctl is-active --quiet "${BOT_NAME}-web.service"; then
  echo "  ✗ ${BOT_NAME}-web.service did not become active." >&2
  echo "    Check: sudo journalctl -u ${BOT_NAME}-web.service -n 50" >&2
  exit 1
fi
echo "  ✓ ${BOT_NAME}-web.service active"

# Publish via tailscale serve. --bg backgrounds the serve config; the
# command returns immediately and the config persists across reboots.
# If tailscale serve is already configured on :8443, this is idempotent
# (tailscale will just confirm the existing route).
if sudo tailscale serve --bg --https=8443 http://127.0.0.1:3000 >/dev/null 2>&1; then
  echo "  ✓ tailscale serve published on :8443"
else
  echo "  ⚠ tailscale serve failed — web shell is up locally but not on the tailnet." >&2
  echo "    The URL written into HANDOFF-TO-NATE.txt will not load until this is fixed:" >&2
  echo "    sudo tailscale serve --bg --https=8443 http://127.0.0.1:3000" >&2
fi

# --- Done ------------------------------------------------------------------

banner "Steps 1-4 complete — next, manual"
cat <<EOF

  1. tmux attach -t claude
     Verify the ❯ prompt renders correctly (not __ or ??).
     Ctrl-b then d to detach — DO NOT exit the session.

     **IMPORTANT: walk Claude Code's first-run flow (theme picker + OAuth)
     INSIDE this attached tmux session, not at a separate terminal.**
     The bot's parked \`claude\` is the live process the systemd unit
     started; finishing its first-run setup at a separate terminal makes
     this one exit (and tmux follows when the inner command exits). If
     that happens, claude-code.service may hit its 10-restarts-in-60s
     restart-limit cap and give up — \`tmux ls\` will then show no
     \`claude\` session. Recovery: \`sudo systemctl reset-failed
     claude-code.service && sudo systemctl start claude-code.service\`.

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
# Reboot (Step 4 final action — operator runs \`sudo reboot\` to validate
# the unit comes back clean; works even on SSH-key-only accounts with
# no /etc/shadow password)
$BOT_NAME ALL=(ALL) NOPASSWD: /usr/sbin/reboot
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

  4. After reboot, hand HANDOFF-TO-NATE.txt (written below) to the end-user.
     Their only step: open the web shell URL, log in, type \`/setup\`.
     The bot runs an interactive interview to collect their name, canary
     phrase, hobbies, comm style, etc., then dispatches setup-runner for
     Steps 5-9. Watch progress:  bash $KIT/runtime/setup-status.sh

EOF

# --- HANDOFF-TO-NATE.txt — credentials + first-step instructions ------------
#
# Writes a one-page handoff doc the provisioner gives to the end user.
# Lives at <REPO_ROOT>/HANDOFF-TO-NATE.txt, mode 600. Contains the web-shell
# URL (best-effort from `tailscale status`), the initial password the
# provisioner set (or "(see your BOT_PASSWORD env)" if it wasn't via env),
# and a single instruction: type /setup.
#
# Banner reminder: `shred -u` the file after delivering it to the end user. The
# password sits in /etc/<BOT_NAME>/secrets/ as a systemd-creds blob whether
# or not this file exists; this file is just a convenience for the
# provisioner-to-end-user handoff.
HANDOFF_FILE="$REPO_ROOT/HANDOFF-TO-NATE.txt"
# Pull DNSName via jq directly — the prior grep|sed approach used `\s` in a
# BRE sed pattern, which on many GNU seds is a literal `s` rather than a
# whitespace class, so the substitution silently fell through and dumped
# the raw `"DNSName": "host.":` JSON fragment into the URL line of the
# HANDOFF-TO-NATE.txt. jq is required for the kit anyway (sc-poll, MCP
# probes, several setup-runner phase steps), so a hard jq dependency
# here is fine; if jq is somehow missing we just fall through to the
# `<bot>.<your-tailnet>.ts.net` placeholder. Trim the trailing dot
# tailscale's JSON includes on FQDN form.
TAILNET_HOST=""
if command -v jq >/dev/null 2>&1; then
  TAILNET_HOST=$(tailscale status --json 2>/dev/null \
    | jq -r '.Self.DNSName // empty' 2>/dev/null \
    | sed 's/\.$//')
fi
INITIAL_PASSWORD_HINT="${BOT_PASSWORD:-(the password you typed during Phase 0.5 — check your scrollback or your password manager)}"
WEB_URL="${TAILNET_HOST:+https://${TAILNET_HOST}:8443/}"

# Compute whether OAuth has been walked on the provisioner side. When it has,
# the claude session is already usable and the end user jumps straight to /setup.
# When it has not (F42 zero-SSH flow — the default), the end user walks a few
# one-time prompts (theme picker, trust folder, OAuth URL paste, bypass-
# permissions disclaimer) directly in the claude session on first connect.
# The pre-F42-doc HANDOFF prose told the end user to route OAuth through the bash
# `?session=shell` session, which doubled up on theme + trust prompts and
# added a back-and-forth between two sessions for no real gain (Jason
# validated by jason-as-end-user on fenbot03 walk 2026-05-13 — the default claude
# session walks cleanly to /setup without the shell detour).
if [ -f "$HOME/.claude/.credentials.json" ]; then
  OAUTH_BLOCK=""
else
  OAUTH_BLOCK="

First connect — you will see a few one-time prompts:

  1. Theme picker (color scheme for the terminal). Pick any, hit Enter.
  2. Trust this folder? Answer 'Yes, I trust this folder'.
  3. Login. Claude Code prints a URL. Open it in a new browser tab,
     sign in with your Anthropic account, accept the TOS, and the page
     will show a code. Paste the code back into the web shell terminal.

  (The bypass-permissions disclaimer is pre-accepted for you; you will
  not see it.) After those three, the prompt is ready and you can
  continue below.
"
fi

cat > "$HANDOFF_FILE" <<EOF
HANDOFF — your bot is ready
═══════════════════════════════════════════════════════════════════════════

Hi! Someone set up an nlbot for you. Here's everything you need to start:

  Web shell URL:  ${WEB_URL:-https://<bot>.<your-tailnet>.ts.net:8443/}
  Username:       $BOT_NAME
  Initial password:  $INITIAL_PASSWORD_HINT
${OAUTH_BLOCK}
To start: open the URL above in a browser, log in with the username and
password, and you will see a Claude Code session ready for input. Type:

  /setup

The bot walks you through a short conversational interview — your name,
hobbies, communication style, etc. — and then brings up the rest of its
services (SilverBullet vault, optional Telegram messaging). You will be
operational in a few minutes.

Questions? The bot answers them. Just talk.
EOF
chmod 600 "$HANDOFF_FILE" 2>/dev/null || true
echo
echo "  📄 Wrote $HANDOFF_FILE (mode 600). Deliver to the end user, then \`shred -u\` it."
echo
