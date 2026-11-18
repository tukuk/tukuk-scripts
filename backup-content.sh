#!/usr/bin/env bash
# ==============================================================================
# backup-content.sh — portable CMS content snapshot → Cloudflare R2 (tukuk-fallback).
#
# Runs scripts/export-content.js to dump every post (incl. drafts) as Markdown +
# posts.json + settings.json, then tars that readable export together with the
# on-disk content/ tree, so the whole content layer is recoverable WITHOUT the
# running app. Complements backup-data.sh (which packs data/ hourly).
#
# ROTATION: tukuk-content-<day-of-week 1-7>.tar.gz → 7 daily slots, no delete API.
#
# USE:  BACKUP_WORKER_URL=... BACKUP_UPLOAD_SECRET=... bash scripts/backup-content.sh
#       (old fallback: CLOUDFLARE_API_TOKEN + wrangler, only if the token has R2:Edit)
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

BUCKET="${R2_BUCKET:-tukuk-fallback}"
WURL="${BACKUP_WORKER_URL:-}"
WSEC="${BACKUP_UPLOAD_SECRET:-}"
if [[ -z "$WURL" || -z "$WSEC" ]]; then
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { echo "[backup-content] no BACKUP_WORKER_URL/SECRET & no R2 token — skip."; exit 0; }
fi

echo "[backup-content] exporting store → generated/content-export ..."
node scripts/export-content.js || { echo "[backup-content] ERROR: export failed" >&2; exit 1; }

KEY="backups/tukuk-content-$(date -u +%u).tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

tar czf "$TMP/content.tar.gz" generated/content-export content 2>/dev/null; TARRC=$?
if [[ $TARRC -ge 2 ]]; then echo "[backup-content] ERROR: tar failed (rc=$TARRC)" >&2; exit 1; fi
SIZE="$(du -h "$TMP/content.tar.gz" | cut -f1)"

echo "[backup-content] sending $KEY ($SIZE) to R2 ..."
if [[ -n "$WURL" && -n "$WSEC" ]]; then
  if curl -fsS --max-time 180 -X POST -H "Authorization: Bearer $WSEC" \
       -H "x-content-type: application/gzip" --data-binary "@$TMP/content.tar.gz" \
       "$WURL/?key=$KEY" >/dev/null; then
    echo "[backup-content] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [worker]"
    exit 0
  fi
  # Worker refused (congestion, or the account's daily free Worker request cap = error
  # 1027, which resets at 00:00 UTC) — fall through to the wrangler
  # path instead of aborting; self-heals once the VPS token gains R2 scope (README §9).
  echo "[backup-content] worker post failed — trying wrangler path" >&2
fi
if npx --yes wrangler r2 object put "$BUCKET/$KEY" --file "$TMP/content.tar.gz" --remote >/dev/null 2>&1; then
  echo "[backup-content] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [wrangler]"
else
  echo "[backup-content] ERROR: failed to send to R2" >&2; exit 1
fi
