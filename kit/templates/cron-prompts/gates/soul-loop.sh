#!/bin/bash
# Gate for the soul-loop cron. Tier-1 + Tier-2 of .claude/commands/soul-loop.md,
# moved to the shell so the main session is woken ONLY when a runner should spawn.
#
# Contract (shared by all cron gates):
#   exit 0  + echo "KEY=VAL ..." on stdout  → there is work; wake and spawn.
#   exit 10 (+ log the noop itself)          → rest; no wake.
#   any other exit                           → treated as error, no wake.
#
# On a spawn decision it also performs Tier-3 step 1 (bump the last-action
# timestamp) so the creative-cycle backoff stays enforced even if delivery of
# the wake is deferred while ${HUMAN_NAME} is busy.
set -uo pipefail
VAULT=${VAULT:-${VAULT_DIR}}   # overridable so the gate can be tested against a scratch tree

HANDOFFS=$(grep -rhn "\- \[ \].*#handoff" "$VAULT"/handoffs/ "$VAULT"/inbox.md 2>/dev/null \
  | grep -v "#blocked-on-human" | grep -v "\.conflicted" | wc -l)

# Due-dated tasks ("bookmarks for later", added 2026-09-26 at ${HUMAN_NAME}'s request).
# An open task carrying a SilverBullet attribute [due: YYYY-MM-DD] or
# [due: YYYY-MM-DDTHH:MM] (a space instead of T also works) in inbox.md, handoffs/
# or projects/ wakes the loop once that time has passed, whatever the
# backoff, just like a handoff. Date-only = 06:00 local (start of ${HUMAN_NAME}'s day).
# #blocked-on-human is skipped. A due task keeps waking the loop every
# 10 minutes until it's ticked, re-dated later (snooze), or tagged
# #blocked-on-human, the same brake handoffs use. Due lines go to DUE_FILE for the router.
DUE_FILE=${DUE_FILE:-/tmp/soul-loop-due.txt}
DUE=$(VAULT="$VAULT" DUE_FILE="$DUE_FILE" python3 - <<'PY'
import os, re, glob, datetime
root = os.environ["VAULT"]; out = os.environ["DUE_FILE"]
files = [os.path.join(root, "inbox.md")]
for d in ("handoffs", "projects"):
    files += glob.glob(os.path.join(root, d, "**", "*.md"), recursive=True)
pat = re.compile(r"\[due:\s*(\d{4}-\d{2}-\d{2})(?:[T ](\d{1,2}:\d{2}))?\s*\]")
now = datetime.datetime.now(); hits = []
for f in files:
    if ".conflicted" in f: continue
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for i, line in enumerate(lines, 1):
        if not re.match(r"\s*[-*] \[ \]", line) or "#blocked-on-human" in line: continue
        m = pat.search(line)
        if not m: continue
        try: due = datetime.datetime.fromisoformat(m.group(1) + " " + (m.group(2) or "06:00").zfill(5))
        except ValueError: continue
        if due <= now:
            hits.append("%s:%d: %s" % (os.path.relpath(f, root), i, line.strip()))
tmp = out + ".tmp"
open(tmp, "w").write("\n".join(hits) + ("\n" if hits else "")); os.replace(tmp, out)
print(len(hits))
PY
)
[ -z "$DUE" ] && DUE=0

LAST_ACTION_FILE="$VAULT/cron-prompts/.soul-loop-last-action"
NOW=$(date +%s)
LAST=$(cat "$LAST_ACTION_FILE" 2>/dev/null || echo 0)
SECONDS_SINCE=$((NOW - LAST))

REST_STREAK_FILE="$VAULT/cron-prompts/.soul-loop-rest-streak"
STREAK=$(cat "$REST_STREAK_FILE" 2>/dev/null || echo 0)
[ "$STREAK" -gt 5 ] 2>/dev/null && STREAK=5
THRESHOLD=$((3600 * (1 << STREAK)))
[ "$THRESHOLD" -gt 86400 ] && THRESHOLD=86400

if [ "$HANDOFFS" -gt 0 ] || [ "$DUE" -gt 0 ] || [ "$SECONDS_SINCE" -ge "$THRESHOLD" ]; then
  date +%s > "$LAST_ACTION_FILE"          # Tier-3 step 1: bump before the wake
  echo "HANDOFFS=$HANDOFFS DUE=$DUE SECONDS_SINCE=$SECONDS_SINCE"
  exit 0
fi

echo "| $(date '+%Y-%m-%d %H:%M') | soul-loop | 0 | shell-only rest |" >> "$VAULT/cron-prompts/job-log.md"
exit 10
