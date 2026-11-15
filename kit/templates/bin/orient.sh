#!/bin/bash
# orient.sh — the orientation bundle for any fresh ${BOT_NAME} context.
#
# Every agent that starts with an empty context runs this first: the main
# session after a restart or compaction, and every runner subagent (soul-loop,
# secretary, journal-synthesizer, wake-up).
# One script instead of a file list copied into each prompt, so the list can't
# drift, and so no agent has to work out today's date, the weekday or a journal
# path itself. Hand-derived dates and weekdays went wrong three times in
# 2026-09.
#
# The bundle holds, in order:
#   - current local date, time and weekday (${BOT_NAME} runs on ${TIMEZONE})
#   - identity.md (includes the anchor canary), user-profile.md
#   - journals/journal.md: today's running journal
#   - yesterday's daily file, journals/YYYY/MM/DD.md
#   - the newest N day-entries from the monthly summaries (spills into last
#     month early in a month)
#
# Usage: bash ${VAULT_DIR}/bin/orient.sh [--stdout] [N_SUMMARY_ENTRIES]   (default 5)
#
# By default the bundle (~22 KB) is written to a fresh /tmp/bot-orient.*.md
# and only a two-line pointer is printed; the agent then Reads that file.
# Printing it straight to stdout failed its first real test (2026-09-11): a
# Haiku runner saw the output cut off partway through user-profile.md and
# missed today's journal entirely. Large Bash results reach an agent only in
# part, while the Read tool returns the whole file. A unique file per run so
# concurrent runners don't read each other's half-written bundle; bundles
# older than an hour are cleaned up. --stdout prints the bundle instead (for
# humans and debugging).
set -uo pipefail
V=${VAULT_DIR}
J="$V/journals"
STDOUT=0; [ "${1:-}" = "--stdout" ] && { STDOUT=1; shift; }
N="${1:-5}"

if [ "$STDOUT" = 0 ]; then
  find /tmp -maxdepth 1 -name 'bot-orient.*.md' -mmin +60 -delete 2>/dev/null
  OUT=$(mktemp /tmp/bot-orient.XXXXXX.md)
  exec 3>&1 >"$OUT"
fi

section() { printf '\n===== %s =====\n' "$1"; }

echo "ORIENTATION — now: $(date '+%Y-%m-%d %H:%M %A %Z')"
echo "Use this date and weekday. Never infer them. Journal layout: today → journals/journal.md;"
echo "past days → journals/YYYY/MM/DD.md; monthly summaries → journals/YYYY/MM.md."

section "identity.md"
cat "$V/identity.md"

section "user-profile.md"
cat "$V/user-profile.md"

section "journals/journal.md (today, $(date +%F))"
if [ -s "$J/journal.md" ]; then cat "$J/journal.md"; else echo "(empty — nothing journaled yet today)"; fi

YD=$(date -d yesterday +%F); YP=$(date -d yesterday +%Y/%m/%d)
section "journals/$YP.md (yesterday, $YD)"
if [ -s "$J/$YP.md" ]; then cat "$J/$YP.md"
else echo "(missing — the midnight synthesis has not written $YD yet; its raw entries may still be in journal.md)"; fi

# Newest N day-entries across this month's and last month's summaries. Each
# summary is newest-first, and each entry starts with a date label linking to
# its daily file: '**[[journals/…' (current format) or '## [[journals/…' (Mar–May).
M=$(date +%Y/%m); PM=$(date -d "$(date +%Y-%m-01) -1 day" +%Y/%m)
section "recent days (newest $N entries from journals/$M.md, then journals/$PM.md)"
# awk, not head: head exits early, grep takes SIGPIPE, and under pipefail the
# whole script then reports exit 141 on success.
for f in "$J/$M.md" "$J/$PM.md"; do [ -f "$f" ] && grep -E '^(\*\*|## )\[\[journals/' "$f"; done | awk -v n="$N" 'NR<=n'

if [ "$STDOUT" = 0 ]; then
  exec >&3
  echo "ORIENTATION — now: $(date '+%Y-%m-%d %H:%M %A %Z')"
  echo "Bundle written to $OUT ($(wc -c <"$OUT") bytes). Read the WHOLE file with the Read tool now; this line is not the orientation."
fi
