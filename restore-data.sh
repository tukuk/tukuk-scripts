#!/usr/bin/env bash
# ==============================================================================
# restore-data.sh — restore Tukuk-OS data/ from an R2 copy (backup-data.sh).
#
#   bash scripts/restore-data.sh                    # current-hour slot (freshest)
#   bash scripts/restore-data.sh 314                # key tukuk-data-314.tar.gz (day3 hour14)
#
# SAFE: the existing data/ is moved to data.broken-<ts>/ first — no blind
# overwrite. After restoring: systemctl restart tukuk-os (root).
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BUCKET="${R2_BUCKET:-tukuk-fallback}"
WURL="${BACKUP_WORKER_URL:-}"
WSEC="${BACKUP_UPLOAD_SECRET:-}"
SLOT="${1:-$(date -u +%u%H)}"
KEY="backups/tukuk-data-${SLOT}.tar.gz"
[[ "$SLOT" =~ ^[0-9]{3}$ || "$SLOT" =~ ^[0-9]{4}$ ]] || { echo "Slot must be 3-4 digits (day+hour), example: 314"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[restore] fetching $KEY from $BUCKET ..."
if [[ -n "$WURL" && -n "$WSEC" ]]; then
  curl -fsS --max-time 120 -H "Authorization: Bearer $WSEC" "$WURL/?key=$KEY" -o "$TMP/data.tar.gz" || {
    echo "[restore] ERROR: copy missing / download failed (worker)" >&2; exit 1;
  }
elif ! npx --yes wrangler r2 object get "$BUCKET/$KEY" --file "$TMP/data.tar.gz" --remote; then
  echo "[restore] ERROR: copy missing / download failed" >&2; exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
if [[ -d "$ROOT/data" ]]; then
  mv "$ROOT/data" "$ROOT/data.broken-$TS"
  echo "[restore] old data kept at data.broken-$TS"
fi

tar xzf "$TMP/data.tar.gz" -C "$ROOT"
echo "[restore] ✓ data restored from $KEY"
echo "[restore] don't forget: systemctl restart tukuk-os"
