#!/bin/bash
# sb.sh — ${BOT_NAME}'s wrapper for the SilverBullet v2 HTTP + Runtime APIs.
# Reference: processes/silverbullet.md. Upstream docs: "HTTP API.md", "Runtime API.md"
# in silverbulletmd/silverbullet at the running tag (2.10.0).
#
#   sb.sh lua '<expr>'            POST /.runtime/lua        one Lua expression → {"result":…}
#   sb.sh script [file|-]         POST /.runtime/lua_script multi-statement Lua with `return`
#   sb.sh cmd '<Command Name>'    run a command-palette command (editor.invokeCommand)
#   sb.sh query '<LIQ>'           shorthand: lua 'query[[<LIQ>]]'
#   sb.sh get <path.md>           GET  /.fs/<path>          read a file as SilverBullet serves it
#   sb.sh put <path.md> [file|-]  PUT  /.fs/<path>          write a file through the server
#   sb.sh ls                      GET  /.fs                 every file SilverBullet can SEE (listing honours .gitignore)
#   sb.sh logs [N]                GET  /.runtime/logs       headless client console log
#   sb.sh shot [out.png]          GET  /.runtime/screenshot headless client viewport
#   sb.sh config                  GET  /.config             server-side client config
#   sb.sh shell <cmd> [args…]     POST /.shell              run a command server-side, in the container (JSON stdout/stderr/code)
#   sb.sh ready                   poll /.runtime/lua until the headless client answers (≤ 3 min)
#
# The Runtime API (lua/script/cmd/query/logs/shot) runs inside a headless Chromium
# that the server starts on the FIRST runtime call; it then boots the client and
# indexes the space. Until then you get 503 {"code":"bridge_unavailable"}. Run
# `sb.sh ready` first. If it never comes up, check `docker logs silverbullet`
# for chrome launch failures (2026-09-11: HOME=/ unwritable for uid 1001 →
# chrome_crashpad_handler abort; fix is HOME=/tmp in the live compose).
#
# Token: SB_AUTH_TOKEN env, else ${BOT_NAME}'s per-account API token from .sb-token
# (2026-09-22 multi-space cutover; SB_AUTH_TOKEN is single-space-only and is gone
# from the live stack). The stale compose copy this comment used to point at was
# deleted 2026-09-22 and fed nothing here; recover it from git history if the old
# single-space credentials are ever wanted.
set -uo pipefail
# Multi-space (2026-09-22): the binding prefix (/vault) is the BROWSER route only.
# Every API endpoint stays at the server ROOT. Measured, after an initial wrong
# guess: POST /vault/.runtime/lua → 405 (allow GET,HEAD) but POST /.runtime/lua →
# {"result":1}; GET /.fs/ → JSON listing of 2589 vault files while /vault/.fs/
# returns HTML; POST /.shell → 200 but /vault/.shell → 405. The 401 seen at
# /vault/.runtime/lua before auth was the space LOGIN GATE, not the endpoint.
U=${SB_URL:-http://127.0.0.1:${SB_PORT}}
# Multi-space uses PER-ACCOUNT API tokens; SB_AUTH_TOKEN is single-space only and
# no longer exists in the live stack. ${BOT_NAME}'s own token lives in .sb-token
# (mode 600, gitignored). Env still wins.
T=${SB_AUTH_TOKEN:-$(cat ${VAULT_DIR}/.sb-token 2>/dev/null)}
[ -n "$T" ] || { echo "sb.sh: no token — put ${BOT_NAME}'s SilverBullet API token in ${VAULT_DIR}/.sb-token (Dashboard → Users → ${BOT_NAME} → API tokens)" >&2; exit 2; }
A=(-H "Authorization: Bearer $T")
TO=(-H "X-Timeout: ${TIMEOUT:-60}")

lua() { curl -sS -X POST "${A[@]}" "${TO[@]}" --data-binary "$1" "$U/.runtime/lua"; echo; }

case "${1:-}" in
  lua)    lua "$2" ;;
  query)  lua "query[[$2]]" ;;
  cmd)    lua "editor.invokeCommand([==[$2]==])" ;;
  script) curl -sS -X POST "${A[@]}" "${TO[@]}" --data-binary @"${2:--}" "$U/.runtime/lua_script"; echo ;;
  get)    curl -sS "${A[@]}" -H 'X-Sync-Mode: true' "$U/.fs/$2" ;;
  put)    curl -sS -X PUT "${A[@]}" -H 'X-Sync-Mode: true' --data-binary @"${3:--}" "$U/.fs/$2"; echo ;;
  ls)     curl -sS "${A[@]}" -H 'X-Sync-Mode: true' "$U/.fs/" | jq -r '.[].name' ;;
  logs)   curl -sS "${A[@]}" "$U/.runtime/logs?limit=${2:-50}" | jq -r '.logs[] | "\(.level)\t\(.text)"' ;;
  shot)   echo 'sb.sh shot: /.runtime/screenshot was removed in SilverBullet 2.11 (docs list only lua, lua_script, logs); it returns the app HTML. Evaluate the page expressions with sb.sh lua instead.' >&2; exit 2 ;;
  # Revisions (managed mode). snapshot = commit everything outstanding NOW, as the ${BOT_NAME} account:
  # a rollback point before a multi-file edit. revlog [N] = last N space commits (rev author message).
  snapshot) curl -sS -X POST "${A[@]}" -H 'X-Sync-Mode: true' "$U/.revisions/"; echo ;;
  revlog) curl -sS "${A[@]}" -H 'X-Sync-Mode: true' "$U/.revisions/?limit=${2:-10}" | jq -r '.commits[] | "\(.rev[0:8])\t\(.author)\t\(.message)"' ;;
  config) curl -sS "${A[@]}" "$U/.config"; echo ;;
  shell)
    shift; cmd="$1"; shift
    # Pass remaining args as a JSON array so jq never parses them as its own flags (e.g. --short)
    args_json=$(jq -cn '$ARGS.positional' --args -- "$@" 2>/dev/null || printf '%s\n' "$@" | jq -Rs 'split("\n") | .[:-1]')
    json=$(jq -cn --arg c "$cmd" --argjson a "$args_json" '{cmd:$c, args:$a}')
    curl -sS -X POST "${A[@]}" -H 'Content-Type: application/json' -d "$json" "$U/.shell"; echo
    ;;
  ready)
    for i in $(seq 1 18); do
      r=$(lua '1'); case "$r" in *'"result":1'*) echo "runtime ready"; exit 0 ;; esac
      echo "not ready ($i): $r" >&2; sleep 10
    done
    echo "sb.sh: runtime never became ready — check: docker logs silverbullet 2>&1 | grep -i chrome" >&2; exit 1 ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
