#!/bin/bash
# Gate for the sb-mentions cron. Runs every 5 minutes.
#
# Watches for NEW @${BOT_NAME} mentions in the SilverBullet vault via the Runtime
# API (identity.mentions("${BOT_NAME}")). Exits 10 (noop, 0 tokens) unless a
# mention nobody has seen before shows up. Scope is watcher + trigger only —
# no runner exists yet; the main session reads the detail file itself. See
# processes/cron-wake-path.md.
#
# Contract (shared by all cron gates):
#   exit 0  + echo "KEY=VAL ..." on stdout  → there is work; wake and spawn.
#   exit 10 (+ log the noop itself)          → rest; no wake.
#   any other exit                           → treated as error, no wake.
#
# The pause kill switch is handled by cron-wake.sh itself — not duplicated here.
#
# ---------------------------------------------------------------------------
# Stable key design
#
# identity.mentions() returns a `range`/`pos` (and `ref`) that shift on every
# unrelated edit to the page — using them as the dedup key would re-fire on
# every save. Instead the key is sha1(page \x1f normalised-snippet \x1f
# target): page + the mention's own text is what actually identifies "this is
# the same @mention a human wrote", and normalising the snippet (collapse
# whitespace, trim) absorbs whitespace-only re-flows without changing the key.
# A genuine edit to the mention's surrounding text is treated as a new
# mention on purpose — the alternative (hashing something stabler) would risk
# silently swallowing an edited, still-open mention.
#
# Caveat: renaming the page changes the key (new page name -> new hash), so a
# rename re-fires the mention once. Accepted; out of scope to chase renames.
# ---------------------------------------------------------------------------
set -uo pipefail
VAULT=${VAULT_DIR}
SB="$VAULT/bin/sb.sh"   # moved to bin/ 2026-09-24; this line was missed then, found 2026-09-26
STATE_DIR="$VAULT/cron-prompts/state"
SEEN="$STATE_DIR/.sb-mentions-seen"
DETAIL="/tmp/sb-mentions-new.txt"
mkdir -p "$STATE_DIR"

log() { echo "sb-mentions: $*" >&2; echo "$(date '+%F %T') sb-mentions $*" >> "$VAULT/cron-prompts/inject.log"; }   # also to inject.log: stderr alone was invisible under cron (the 09-24→09-26 blind spot)

# --- fetch -------------------------------------------------------------
# SB_MENTIONS_SIMULATE_UNAVAILABLE=1 is a TEST-ONLY hook (see test d in the
# build report) that skips the real call and feeds back the same JSON shape
# the server returns while the headless Chromium hasn't booted yet. Never
# leave this set in the environment cron-wake.sh actually runs under.
if [ "${SB_MENTIONS_SIMULATE_UNAVAILABLE:-0}" = "1" ]; then
  resp='{"code":"bridge_unavailable"}'
else
  LUA_SCRIPT='local r = identity.mentions("${BOT_NAME}")
local US = string.char(31)
local RS = string.char(30)
local parts = {}
for _, m in ipairs(r.mentions) do
  local by = ""
  if type(m.by) == "table" then by = table.concat(m.by, ",") end
  local page = tostring(m.page or ""):gsub("[\r\n]+", " ")
  local snippet = tostring(m.snippet or ""):gsub("[\r\n]+", " ")
  local target = tostring(m.target or "")
  local replyTo = tostring(m.replyTo or "")
  local inComment = tostring(m.inComment)
  table.insert(parts, page .. US .. snippet .. US .. target .. US .. by .. US .. replyTo .. US .. inComment)
end
return table.concat(parts, RS)'
  resp=$(printf '%s' "$LUA_SCRIPT" | timeout 25 "$SB" script - 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    log "sb.sh script failed or empty (rc=$rc)"
    exit 10
  fi
fi

# --- error handling ------------------------------------------------------
code=$(printf '%s' "$resp" | jq -r '.code // empty' 2>/dev/null)
if [ -n "$code" ]; then
  if [ "$code" = "bridge_unavailable" ]; then
    log "bridge_unavailable — launching detached sb.sh ready to warm it for next tick"
    nohup "$SB" ready >/tmp/sb-mentions-ready.log 2>&1 &
    disown
  else
    log "runtime error code=$code"
  fi
  exit 10
fi

if ! printf '%s' "$resp" | jq -e 'has("result")' >/dev/null 2>&1; then
  log "unexpected response (no result, no code): $resp"
  exit 10
fi

data=$(printf '%s' "$resp" | jq -r '.result')

# --- parse + baseline/diff -----------------------------------------------
BASELINE=0
[ -f "$SEEN" ] || BASELINE=1

new_keys_tmp=$(mktemp)
all_keys_tmp=$(mktemp)
new_detail_tmp=$(mktemp)
trap 'rm -f "$new_keys_tmp" "$all_keys_tmp" "$new_detail_tmp"' EXIT

n_new=0
ctx_parts=()

# Split records on RS (\x1e -> \n via tr), fields on US (\x1f) via `read`'s
# IFS. The trailing \n on the tr input matters: bash's `read` silently drops
# a final field-only line with no terminator (verified empirically — see the
# build report), so the last mention would vanish without it.
if [ -n "$data" ]; then
  while IFS=$'\x1f' read -r page snippet target by replyTo inComment; do
    [ -z "$page" ] && continue
    # Cut ${BOT_NAME}'s own nested replies (`* **${BOT_NAME}:** …`) out of the key: identity.mentions()
    # folds child bullets into the snippet, so every inline reply re-fired the parent (11-11).
    norm_snippet=$(printf '%s' "$snippet" | sed -e 's/[[:space:]]*\* \*\*${BOT_NAME}:\*\*.*$//' | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')
    key_input=$(printf '%s\x1f%s\x1f%s' "$page" "$norm_snippet" "$target")
    key=$(printf '%s' "$key_input" | sha1sum | cut -d' ' -f1)
    echo "$key" >> "$all_keys_tmp"

    if [ "$BASELINE" -eq 1 ]; then
      continue
    fi
    grep -qxF "$key" "$SEEN" 2>/dev/null && continue

    # not previously seen -> record it either way so it never re-fires, but
    # surface it as "new".
    echo "$key" >> "$new_keys_tmp"

    # No "self-authored" skip (removed 2026-09-26). `by` comes from the page's `authors:`
    # frontmatter and signatures, NOT from who typed the line: every ${BOT_NAME} response page
    # has `authors: ${BOT_NAME}`, so ${HUMAN_NAME}'s in-place answers (`- answer @${BOT_NAME}`) were being
    # credited to ${BOT_NAME} and dropped. Measured: ${BOT_NAME}'s own `-- @${BOT_NAME}` signatures are not
    # returned by identity.mentions at all, and ${BOT_NAME}'s writing backticks @-names (mention
    # hygiene), so there was nothing real to skip. `by` is still passed along in the detail.

    n_new=$((n_new + 1))
    short=$(printf '%s' "$norm_snippet" | cut -c1-80)
    ctx_parts+=("$page: $short")
    {
      echo "page: $page"
      echo "snippet: $snippet"
      echo "by: $by"
      echo "replyTo: $replyTo"
      echo "inComment: $inComment"
      echo "---"
    } >> "$new_detail_tmp"
  done < <(printf '%s\n' "$data" | tr '\036' '\n')
fi

# --- second source: #handoff-tagged lines with no @${BOT_NAME} (added 2026-11-11) ---------
# ${HUMAN_NAME} adds work as `* comment #handoff` bullets or `- [ ] task #handoff` lines without
# @${BOT_NAME}. identity.mentions() never returns those, and the soul-loop gate only counts
# open checkbox tasks (every 10 min, and never under #blocked-on-human), so on 11-11 two
# inline comments on a response page went unseen. Scan handoffs/ on disk instead: one key
# per (file, normalised line) in its own seen file with its own baseline. Backticked
# `#handoff` (${BOT_NAME} prose about the tag) doesn't count. Editing a line makes it new
# again, same as mentions.
TAG_SEEN="$STATE_DIR/.sb-handoff-tags-seen"
TAG_BASELINE=0; [ -f "$TAG_SEEN" ] || TAG_BASELINE=1
tag_all_tmp=$(mktemp); tag_new_tmp=$(mktemp)
trap 'rm -f "$new_keys_tmp" "$all_keys_tmp" "$new_detail_tmp" "$tag_all_tmp" "$tag_new_tmp"' EXIT
while IFS= read -r hit; do
  file=${hit%%:*}; line=${hit#*:}
  bare=$(printf '%s' "$line" | sed -e 's/`[^`]*`//g')
  printf '%s' "$bare" | grep -qE '(^|[[:space:]])#handoff([^-[:alnum:]_]|$)' || continue
  printf '%s' "$bare" | grep -q '@${BOT_NAME}' && continue   # mentions source already covers it
  rel=${file#"$VAULT"/}; page=${rel%.md}
  norm=$(printf '%s' "$line" | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')
  key=$(printf 'tag\x1f%s\x1f%s' "$page" "$norm" | sha1sum | cut -d' ' -f1)
  echo "$key" >> "$tag_all_tmp"
  [ "$TAG_BASELINE" -eq 1 ] && continue
  grep -qxF "$key" "$TAG_SEEN" 2>/dev/null && continue
  echo "$key" >> "$tag_new_tmp"
  n_new=$((n_new + 1))
  ctx_parts+=("$page: $(printf '%s' "$norm" | cut -c1-80)")
  { echo "page: $page"; echo "snippet: $norm"; echo "by: (file scan: #handoff without @${BOT_NAME})"; echo "---"; } >> "$new_detail_tmp"
done < <(grep -rn --include='*.md' -e '#handoff' "$VAULT/handoffs" 2>/dev/null | sed -E 's/^([^:]*):[0-9]+:/\1:/')
if [ "$TAG_BASELINE" -eq 1 ]; then
  sort -u "$tag_all_tmp" > "$TAG_SEEN"
  log "tag baseline: recorded $(wc -l < "$TAG_SEEN") #handoff line(s) as seen"
elif [ -s "$tag_new_tmp" ]; then
  cat "$tag_new_tmp" >> "$TAG_SEEN"; sort -u -o "$TAG_SEEN" "$TAG_SEEN"
fi

if [ "$BASELINE" -eq 1 ]; then
  sort -u "$all_keys_tmp" > "$SEEN"
  log "baseline: recorded $(wc -l < "$SEEN") existing mention(s) as seen; no wake"
  exit 10
fi

if [ -s "$new_keys_tmp" ]; then
  cat "$new_keys_tmp" >> "$SEEN"
  sort -u -o "$SEEN" "$SEEN"
fi

if [ "$n_new" -eq 0 ]; then
  exit 10
fi

mv "$new_detail_tmp" "$DETAIL"
joined=$(printf '%s; ' "${ctx_parts[@]}")
joined="${joined%; }"
echo "NEW=$n_new $joined"
exit 0
