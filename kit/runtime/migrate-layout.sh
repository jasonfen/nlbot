#!/usr/bin/env bash
# migrate-layout.sh — one-shot migrator for kit clones that predate the
# kit/ + vault/ restructure. Run once on an existing install (e.g.
# nlbot, nlbot-test). Idempotent: detects "already migrated" by presence
# of kit/ + vault/ at the repo root and exits 0 if so.
#
# What it does:
#   1. Stops claude-code.service, <BOT_NAME>-web.service, telegram-bot.service.
#   2. git mv kit-source files into kit/, vault-content into vault/.
#   3. Re-renders systemd units from kit/ templates with new paths.
#   4. Re-runs refresh-claude-dir.sh + install-plugs.sh against new layout.
#   5. Re-installs the post-merge hook.
#   6. Restarts services.
#   7. Commits the migration as a single 'migrate-layout' commit.
#
# Pre-migration snapshot is recommended — for an LXC, take the snapshot
# before running this script so revert is one click.

set -euo pipefail

# Source from this script's location, which post-migration will be at
# kit/runtime/migrate-layout.sh. The script ALSO needs to work pre-
# migration (when it's at runtime/migrate-layout.sh, before the move).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# If we're at runtime/ (pre-migration), repo root is one up; if we're
# at kit/runtime/ (post-migration), repo root is two up.
if [ -d "$SCRIPT_DIR/../kit" ]; then
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)         # we're at kit/runtime/ — already migrated
  echo "migrate-layout: kit/ already exists; nothing to do."
  echo "  Run \`bash $REPO_ROOT/kit/runtime/setup-status.sh\` to verify the install is healthy."
  exit 0
fi
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)            # we're at runtime/ — pre-migration

cd "$REPO_ROOT"

[ -d ".git" ] || { echo "migrate-layout: $REPO_ROOT/.git not found; not a kit clone" >&2; exit 1; }

# Confirm we're at the OLD layout. If kit/ AND vault/ both exist, bail.
if [ -d "kit" ] && [ -d "vault" ]; then
  echo "migrate-layout: already migrated (kit/ and vault/ both exist)."
  exit 0
fi

BOT_NAME="${BOT_NAME:-$USER}"

banner() {
  echo
  echo "=========================================================="
  echo "  $1"
  echo "=========================================================="
}

banner "Phase 1 — stop services"
# Best-effort; ignore failures (services may not be installed on a
# bot-side migration where some weren't reached yet).
sudo systemctl stop claude-code.service 2>/dev/null || true
sudo systemctl stop "${BOT_NAME}-web.service" 2>/dev/null || true
sudo systemctl stop "${BOT_NAME}-shell.service" 2>/dev/null || true
sudo systemctl stop telegram-bot.service 2>/dev/null || true
# Don't stop SilverBullet — its compose file path changes after the
# move; we restart it explicitly in Phase 5.

banner "Phase 2 — git mv into kit/ and vault/"
mkdir -p kit vault

# Kit-source: every existing top-level .md doc + the kit machinery dirs.
KIT_FILES=(
  README.md bootstrap.md first-time-setup.md silverbullet-setup.md
  persistence-and-hardware.md memory.md web-shell.md
  telegram-integration.md portainer.md INTRO-FOR-HUMANS.md
  CLAUDE.md.template setup-orchestrator.md setup-state.md.template
  docker-compose.yml
  dot-claude runtime templates web-terminal
)
for f in "${KIT_FILES[@]}"; do
  [ -e "$f" ] && git mv "$f" "kit/$f"
done

# Vault content: SB pages + dirs.
VAULT_FILES=(
  CLAUDE.md identity.md user-profile.md soul-loop.md CONFIG.md
  inbox.md decisions.md dashboard.md index.md
  handoffs.md journals.md processes.md
  handoffs journals processes _templates _plug
)
for f in "${VAULT_FILES[@]}"; do
  [ -e "$f" ] && git mv "$f" "vault/$f"
done

echo "  moved $(git diff --cached --name-only | wc -l) paths"

banner "Phase 3 — re-render systemd units"
# Re-run first-time-setup.sh's Step 4 only — Phase 0 values already
# exist in setup-state.md, vault content is already seeded.
bash "$REPO_ROOT/kit/runtime/first-time-setup.sh" --reinstall-services-only

banner "Phase 4 — refresh .claude/ + vault-page seeds + plug bundles"
bash "$REPO_ROOT/kit/runtime/refresh-claude-dir.sh"

banner "Phase 5 — re-install post-merge hook"
install -m 755 "$REPO_ROOT/kit/runtime/hooks/post-merge" "$REPO_ROOT/.git/hooks/post-merge"
echo "  post-merge hook installed at .git/hooks/post-merge"

banner "Phase 6 — restart services + SilverBullet"
sudo systemctl daemon-reload
sudo systemctl start claude-code.service 2>/dev/null || true
sudo systemctl start "${BOT_NAME}-shell.service" 2>/dev/null || true
sudo systemctl start "${BOT_NAME}-web.service" 2>/dev/null || true
sudo systemctl start telegram-bot.service 2>/dev/null || true
# SilverBullet uses the new kit/docker-compose.yml path.
bash "$REPO_ROOT/kit/runtime/silverbullet-up.sh" 2>/dev/null || \
  echo "  WARN: silverbullet-up.sh returned non-zero — check kit/docker-compose.yml + secrets"

banner "Phase 7 — commit the migration"
git add -A
git commit -m "migrate-layout: split kit/ from vault/

One-shot migration via kit/runtime/migrate-layout.sh.
Kit-source moved into kit/, SilverBullet space content into vault/.
Bot-runtime state (.claude/, .telegram/, cron-prompts/, setup-state.md)
stays at repo root. Systemd units, post-merge hook, and refresh
scripts re-rendered against the new layout."

banner "Migration complete"
cat <<EOF

Verify with:
  bash $REPO_ROOT/kit/runtime/setup-status.sh

Open SilverBullet — TreeView should now show only vault/ content (no
kit/ clutter). Trigger a soul-loop manually if you want immediate
confirmation: the bot's CWD is still $REPO_ROOT.

If anything's off, revert the LXC snapshot you took before running
this script. The migration commit is a single SHA so \`git revert <SHA>\`
also rolls back cleanly.
EOF
