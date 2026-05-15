#!/usr/bin/env bash
# ui.sh — shared terminal-output helpers for nlbot kit scripts.
#
# Sourced (not exec'd) by setup-status.sh, bootstrap.sh, first-time-setup.sh,
# migrate-secrets.sh. Provides:
#
#   - Color vars G/R/Y/B/N — green / red / yellow / bold / normal,
#     TTY-gated so piped output stays plain.
#   - banner "Title"        — bold one-line section header.
#   - pass  "label" "[detail]" — green [✓] line.
#   - _ui_fail "label" "[detail]" — red [✗] line. Named with the
#     underscore prefix so setup-status.sh can layer its own fail()
#     wrapper on top that also captures FIRST_FAIL for the
#     recommendation block.
#   - warn  "label" "[detail]" — yellow [!] line.
#   - skip  "msg"             — "[skip] msg" plain text.
#
# Idempotent: source-guard via _NLBOT_UI_SOURCED so a script that sources
# ui.sh and then sources another script that also sources ui.sh doesn't
# redefine helpers (which would also redefine setup-status.sh's fail()
# wrapper back to the base).

[ -n "${_NLBOT_UI_SOURCED:-}" ] && return 0
_NLBOT_UI_SOURCED=1

# Colors only if stdout is a TTY. When piped to cat/tee/file, output
# stays clean (no escape literals).
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

banner() {
  echo
  printf "%s=== %s ===%s\n" "$B" "$1" "$N"
  echo
}

pass()    { printf "  [%s✓%s] %-38s %s\n" "$G" "$N" "$1" "${2:-}"; }
_ui_fail() { printf "  [%s✗%s] %-38s %s\n" "$R" "$N" "$1" "${2:-}"; }
warn()    { printf "  [%s!%s] %-38s %s\n" "$Y" "$N" "$1" "${2:-}"; }
skip()    { echo "  [skip] $1"; }

# Default fail() = _ui_fail. setup-status.sh re-defines fail() to wrap
# this and capture FIRST_FAIL; other scripts just inherit this base.
fail() { _ui_fail "$@"; }
