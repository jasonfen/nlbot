#!/usr/bin/env bash
# substitute-placeholders.sh — replace Phase 0 placeholder tokens in a target
# file. Used by:
#
#   * `first-time-setup.sh` Step 2: source the function and call it inline
#     for each freshly-seeded vault file (in-process, no subprocess overhead).
#
#   * `/setup` interview: invokes as a script after Nate's answers have
#     been written to setup-state.md, to re-substitute the seeded vault
#     files with the real values (replacing the bracket-placeholders that
#     first-time-setup.sh left visible for Nate's pre-interview SilverBullet
#     reading).
#
# Reads values from env vars first, falls back to setup-state.md Values block
# if env unset. All variable expansions use `${VAR:-}` defaults so the script
# is safe under `set -u` when a value is unset (F22 pattern).
#
# Usage:
#   # As a script:
#   substitute-placeholders.sh <file>
#
#   # Sourced from another bash script:
#   source <KIT>/runtime/substitute-placeholders.sh
#   substitute_placeholders <file>

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$KIT/.." && pwd)
STATE_FILE="$REPO_ROOT/setup-state.md"

# Read a value from setup-state.md (Values block format:
# `- **KEY**: value <!-- optional comment -->`).
_state_read() {
  local key="$1"
  [ -f "$STATE_FILE" ] || { echo ""; return 0; }
  grep "^- \*\*$key\*\*:" "$STATE_FILE" 2>/dev/null \
    | sed 's/^[^:]*: *//; s/ *<!--.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

# For each placeholder var: env wins; if env is empty, fall back to
# setup-state.md. Anything still empty after that gets left as empty string
# (sed substitutes the placeholder with nothing). For the placeholder
# tokens that say `[your name — set via /setup]` etc., the state file's
# default value IS that string, so it survives the substitution intact.
substitute_placeholders() {
  local file="$1"
  [ -f "$file" ] || return 0

  local var current state_val
  for var in BOT_NAME USER_NAME VAULT CANARY_PHRASE \
             IDLE_PREFS CREATIVE_OUTPUT COMM_STYLE VALUES_CARES_ABOUT \
             USER_ROLE USER_HOBBIES USER_HOURS USER_PREFS; do
    current=$(eval echo "\${$var:-}")
    if [ -z "$current" ]; then
      state_val=$(_state_read "$var")
      if [ -n "$state_val" ]; then
        eval "$var=$(printf '%q' "$state_val")"
      fi
    fi
  done

  # Build the sed argv dynamically. A placeholder that maps to an unset
  # var is SKIPPED entirely rather than replaced with an empty string —
  # so the template literal (e.g., `[Nate]`, `[CHOOSE YOUR CANARY PHRASE]`)
  # stays visible in the seeded vault file until the corresponding value
  # is set. This is what lets the bash bootstrap leave intentional gaps
  # for the /setup interview to fill in later; the seeded identity.md
  # reads as legible "[Nate]" prose to a human browsing pre-interview.
  local -a cmd=(sed -i)

  # Always-run substitutions — these are required values written by the
  # bash bootstrap.
  cmd+=(-e "s|<BOT_NAME>|${BOT_NAME:-}|g")
  cmd+=(-e "s|<VAULT>|${VAULT:-}|g")
  cmd+=(-e "s|<USER>|${BOT_NAME:-}|g")
  cmd+=(-e "s|\[Your Bot's Name\]|${BOT_NAME:-}|g")

  # Optional substitutions — only added to argv when the var is set.
  if [ -n "${USER_NAME:-}" ]; then
    cmd+=(-e "s|\[Nate's\]|${USER_NAME}'s|g")
    cmd+=(-e "s|\[Nate\]|${USER_NAME}|g")
    cmd+=(-e "s|<USER_NAME>|${USER_NAME}|g")
  fi
  if [ -n "${CANARY_PHRASE:-}" ]; then
    cmd+=(-e "s|\[CHOOSE YOUR CANARY PHRASE\]|${CANARY_PHRASE}|g")
    cmd+=(-e "s|\[YOUR CANARY PHRASE\]|${CANARY_PHRASE}|g")
  fi
  if [ -n "${USER_PREFS:-}" ]; then
    cmd+=(-e "s|\[Nate: Fill this in\. What are your non-negotiable preferences?\]|${USER_PREFS}|g")
  fi
  if [ -n "${IDLE_PREFS:-}" ]; then
    cmd+=(-e "s|\[reading/coding/writing/exploring\]|${IDLE_PREFS}|g")
  fi
  if [ -n "${CREATIVE_OUTPUT:-}" ]; then
    cmd+=(-e "s|\[poems/stories/technical docs/music reviews\]|${CREATIVE_OUTPUT}|g")
  fi
  if [ -n "${COMM_STYLE:-}" ]; then
    cmd+=(-e "s|\[direct/gentle/playful/formal\]|${COMM_STYLE}|g")
  fi
  if [ -n "${VALUES_CARES_ABOUT:-}" ]; then
    cmd+=(-e "s|\[quality/speed/creativity/accuracy\]|${VALUES_CARES_ABOUT}|g")
  fi

  "${cmd[@]}" "$file"
}

# Direct-invocation entry point. When sourced from another script, this block
# is skipped and only the function is exposed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ -z "${1:-}" ]; then
    echo "Usage: $0 <file>" >&2
    exit 2
  fi
  substitute_placeholders "$1"
fi
