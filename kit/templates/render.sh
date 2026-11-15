#!/bin/bash
# render.sh — fill the kit's placeholders and write a ready-to-copy tree.
#
#   bash render.sh kit.env /path/to/output-dir
#
# Copies this templates/ directory to the output dir, then replaces every
# ${NAME} placeholder listed in kit.env with its value. Only those names are
# touched: shell variables like ${1:-} and SilverBullet template expressions
# like ${date.today()} are left alone. Nothing outside the output dir is written.
set -euo pipefail
ENVF="${1:?usage: render.sh kit.env output-dir}"
OUT="${2:?usage: render.sh kit.env output-dir}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -e "$OUT" ] && { echo "render.sh: $OUT already exists; pick a new directory" >&2; exit 1; }

SED=()
while IFS='=' read -r key val; do
  case "$key" in ''|\#*) continue ;; esac
  case "$val" in *'|'*) echo "render.sh: value of $key contains '|'" >&2; exit 1 ;; esac
  val=${val//\\/\\\\}; val=${val//&/\\&}
  SED+=(-e "s|\${$key}|$val|g")
done < "$ENVF"
[ "${#SED[@]}" -gt 0 ] || { echo "render.sh: no KEY=value lines in $ENVF" >&2; exit 1; }

mkdir -p "$OUT"
cp -a "$SRC"/. "$OUT"/
rm -f "$OUT/render.sh" "$OUT/kit.env" "$OUT/kit.env.example"
grep -rlIZ --exclude-dir=xterm -e '\${[A-Z_]*}' "$OUT" | xargs -0 -r sed -i "${SED[@]}"

# Anything still shaped like a kit placeholder was not in kit.env.
LEFT=$(grep -rnI --exclude-dir=xterm -oE '\$\{(BOT_NAME|HUMAN_NAME|HUMAN_HANDLE|UNIX_USER|HOME_DIR|VAULT_DIR|PROJECT_SLUG|BOT_UID|BOT_GID|TIMEZONE|TAILNET|SB_PORT|TERM_PORT|SB_DATA_DIR|SECRETS_DIR)\}' "$OUT" || true)
if [ -n "$LEFT" ]; then echo "render.sh: unfilled placeholders:" >&2; echo "$LEFT" | sort | uniq -c >&2; exit 1; fi
echo "rendered to $OUT"
