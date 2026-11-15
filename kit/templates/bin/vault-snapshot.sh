#!/usr/bin/env bash
# Commits the dot-paths SilverBullet's managed revisions skip (.claude/, cron-prompts/state/.*,
# any file or folder whose name starts with "."). Runs every 15 min via bot-vault-snapshot.timer.
#
# Everything else belongs to SilverBullet: since 2026-09-22 the space runs `revisions: managed`,
# which commits page edits ~30 s after quiet with the editing account as author. This script used
# to `git add -A` the whole repo as the local git identity (${HUMAN_NAME}). When it fired inside SB's quiet
# window it took page edits and credited them to ${HUMAN_NAME} (3 commits on 2026-09-23). Restricted to
# dot-paths with its own author at ${HUMAN_NAME}'s request, 2026-09-23. See processes/silverbullet.md.
set -uo pipefail
cd ${VAULT_DIR} || exit 1

DOT=(':(glob)**/.*' ':(glob)**/.*/**')
AUTHOR='snapshot-timer <snapshot-timer@${BOT_NAME}.local>'

# Nothing pending under a dot-path: nothing to do, and nothing worth logging.
[ -n "$(git status --porcelain -- "${DOT[@]}")" ] || exit 0

git add -A -- "${DOT[@]}" || exit 0

# Commit only the dot-paths (pathspec on commit), so nothing SB has staged rides along.
# SB can be mid-commit; losing the index lock is expected and the next tick retries.
if ! err=$(git commit --author="$AUTHOR" -m "Dotfile snapshot (timer) $(date '+%Y-%m-%d %H:%M:%S')" -- "${DOT[@]}" 2>&1); then
  case "$err" in
    *index.lock*|*"nothing to commit"*|*"no changes added"*) exit 0 ;;
    *) echo "vault-snapshot: $err" >&2; exit 1 ;;
  esac
fi
