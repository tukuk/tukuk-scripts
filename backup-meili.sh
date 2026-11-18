#!/usr/bin/env bash
# Backup Meilisearch to Cloudflare R2.
#
# Two paths — one is enough:
#
#   1) WORKER (recommended, no S3 keys):
#        export index -> gzip -> POST to the tukuk-backup worker -> R2
#        NEEDS: BACKUP_WORKER_URL + BACKUP_UPLOAD_SECRET
#
#   2) S3 LEGACY (real R2 keys):
#        full Meilisearch snapshot -> curl --aws-sigv4
#        NEEDS: R2_ACCOUNT_ID + R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY + R2_BUCKET
#
#   BOTH: MEILI_MASTER_KEY
#
# ROTATION (why the keys are slots, not timestamps): this job runs every 6 hours and
# used to write a brand-new dated object each time — `meilisearch/2026/10/28/meili_...Z.json.gz`.
# Nothing ever deleted those, so R2 grew ~20 MB/day forever. Cloudflare's free R2 tier ends
# at 10 GB, so an unbounded mirror is a bill waiting to happen. Keys are now
# `meilisearch/slot-<day-of-week><hour>/...` (168 possible slots, 4 per weekday in practice =
# ~28 objects): the same slot is overwritten weekly, giving a full 7 days of history at 6 h
# granularity with NO delete API needed. Same scheme as scripts/backup-data.sh.
# The dated keys from 17–28 Oct (meilisearch/2026/… + store/2026/…, ~263 MB) are left in
# place — they are history, they no longer grow, and deleting backups is not this script's job.
#
# All values come from the unit's EnvironmentFile (/opt/tukuk-os/.env) or
# ~/.config/tukuk-os/r2.env if found (laptop leftover — still supported).

set -euo pipefail

# Load values from r2.env (EnvironmentFile style) if not already in the environment.
if [ -f "${HOME:-/nonexistent}/.config/tukuk-os/r2.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${HOME:-/nonexistent}/.config/tukuk-os/r2.env"
  set +a
fi

APP_DIR="${APP_DIR:-/opt/tukuk-os}"   # server deploy root (the unit sets the same value)
SNAP_DIR="${SNAP_DIR:-$APP_DIR/snapshots}"
MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_INDEX="${MEILI_INDEX:-halaman_web}"
R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID:-}.r2.cloudflarestorage.com}"
R2_REGION="${R2_REGION:-auto}"
R2_BUCKET="${R2_BUCKET:-tukuk-os-backups}"
KEEP_LOCAL="${KEEP_LOCAL:-3}"
TIMEOUT="${TIMEOUT:-300}"

log() { printf '[backup] %s\n' "$*"; }
fail() { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

# treat <...> placeholders as not yet filled in
usable() {
  case "${1:-}" in
    ''|'<'*'>'|*'<your'*) return 1 ;;
    *) return 0 ;;
  esac
}

usable "${R2_ACCESS_KEY_ID:-}" && usable "${R2_SECRET_ACCESS_KEY:-}" && usable "${R2_ACCOUNT_ID:-}" && S3_OK=1 || S3_OK=0
usable "${BACKUP_WORKER_URL:-}" && usable "${BACKUP_UPLOAD_SECRET:-}" && WORKER_OK=1 || WORKER_OK=0
# Third path: CLOUDFLARE_API_TOKEN + wrangler. This is the path the box actually has —
# BACKUP_WORKER_URL is empty here, so without this meili-backup had no upload path at all
# and failed every run. backup-data.sh has always fallen back to wrangler; this mirrors it.
usable "${CLOUDFLARE_API_TOKEN:-}" && WRANGLER_OK=1 || WRANGLER_OK=0

usable "${MEILI_MASTER_KEY:-}" || fail "MEILI_MASTER_KEY empty/placeholder (check /opt/tukuk-os/.env)"
[ "$S3_OK" = 1 ] || [ "$WORKER_OK" = 1 ] || [ "$WRANGLER_OK" = 1 ] || fail "no path: fill BACKUP_WORKER_URL+BACKUP_UPLOAD_SECRET (primary), the R2_* S3 keys, or CLOUDFLARE_API_TOKEN (wrangler)"

mkdir -p "$SNAP_DIR"

upload_wrangler() {
  # Direct R2 via wrangler — bypasses the throttled workers.dev edge entirely.
  # Only works once CLOUDFLARE_API_TOKEN has Account·R2 Storage·Read & Edit (README §9).
  local file="$1" key="$2" ctype="${3:-application/gzip}"
  log "trying wrangler path for $(basename "$file") -> $R2_BUCKET/$key"
  npx --yes wrangler r2 object put "${R2_BUCKET:-tukuk-fallback}/$key" --file "$file" \
    --content-type "$ctype" --remote >/dev/null 2>&1
}

upload_worker() {
  local file="$1" key="$2" ctype="${3:-application/gzip}"
  local size remote
  size=$(stat -c%s "$file")
  log "uploading $(basename "$file") ($size bytes) -> $R2_BUCKET/$key"

  curl -sf -m 900 -X POST \
    -H "Authorization: Bearer $BACKUP_UPLOAD_SECRET" \
    -H "Content-Type: $ctype" \
    --data-binary "@$file" \
    "$BACKUP_WORKER_URL/?key=$key" \
    || { log "worker upload failed (edge 429?) — trying wrangler path"
         upload_wrangler "$file" "$key" "$ctype" && { log "wrangler upload OK"; return 0; }
         fail "both upload paths failed"; }

  remote=$(curl -sf -m 60 -H "Authorization: Bearer $BACKUP_UPLOAD_SECRET" \
    "$BACKUP_WORKER_URL/?key=$key" -o /dev/null -w '%{size_download}') || remote=""
  if [ "$remote" != "$size" ]; then
    log "worker verify failed/mismatch (local=$size remote=${remote:-empty}) — trying wrangler path"
    upload_wrangler "$file" "$key" "$ctype" && { log "wrangler upload OK"; return 0; }
    fail "no upload path produced a verified copy: local=$size remote=${remote:-empty}"
  fi
  log "size verified OK ($size bytes)"
}

prune_local() {
  local pattern="$1"
  local -a files
  mapfile -t files < <(ls -1t "$SNAP_DIR"/$pattern 2>/dev/null || true)
  local f
  for f in "${files[@]:$KEEP_LOCAL}"; do
    [ -n "$f" ] && rm -f "$f" && log "pruned local backup: $(basename "$f")"
  done
  return 0
}

if [ "$WORKER_OK" = 1 ] || [ "$WRANGLER_OK" = 1 ]; then
  # ---- path 1: export index -> worker (preferred) or wrangler (this box) ----
  upload() {  # file key [content-type]
    if [ "$WORKER_OK" = 1 ]; then
      upload_worker "$1" "$2" "${3:-application/gzip}"
    else
      upload_wrangler "$1" "$2" "${3:-application/gzip}" \
        || fail "wrangler upload failed (CLOUDFLARE_API_TOKEN likely lacks R2:Edit): $2"
    fi
  }
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  SLOT="slot-$(date -u +%u%H)"   # weekday+hour, overwritten weekly (see ROTATION above)
  OUT="$SNAP_DIR/meili_${MEILI_INDEX}-${STAMP}.json.gz"
  log "exporting index $MEILI_INDEX..."
  MEILI_HOST="$MEILI_URL" node "$APP_DIR/scripts/export-index.js" "$OUT" "$MEILI_INDEX" \
    || { rm -f "$OUT"; fail "index export failed"; }
  upload "$OUT" "meilisearch/$SLOT/meili_${MEILI_INDEX}.json.gz"
  prune_local 'meili_*.json.gz'

  # blog store (data/tukuk-os.json) — not part of the Meilisearch export
  STORE="$APP_DIR/data/tukuk-os.json"
  if [ -f "$STORE" ]; then
    SOUT="$SNAP_DIR/store_${STAMP}.json"
    cp "$STORE" "$SOUT"
    upload "$SOUT" "store/$SLOT/tukuk-os.json" "application/json"
    prune_local 'store_*.json'
  fi
  prune_local 'meili_*.json.gz'
elif [ "$S3_OK" = 1 ]; then
  # ---- path 2: full snapshot -> S3 ----
  log "creating Meilisearch snapshot..."
  TASK=$(curl -sf -m 30 -X POST "$MEILI_URL/snapshots" \
    -H "Authorization: Bearer $MEILI_MASTER_KEY" | sed -E 's/.*"taskUid":([0-9]+).*/\1/')
  [ -n "$TASK" ] || fail "failed to get taskUid from Meilisearch"
  log "task uid: $TASK"

  STARTED=$SECONDS
  while :; do
    BODY=$(curl -sf -m 15 "$MEILI_URL/tasks/$TASK" -H "Authorization: Bearer $MEILI_MASTER_KEY")
    STATUS=$(printf '%s' "$BODY" | sed -E 's/.*"status":"([a-z]+)".*/\1/')
    case "$STATUS" in
      succeeded) log "snapshot ready in $((SECONDS - STARTED))s"; break ;;
      failed|canceled)
        printf '%s' "$BODY" | head -c 400 >&2
        fail "snapshot $STATUS"
        ;;
    esac
    [ $((SECONDS - STARTED)) -lt "$TIMEOUT" ] || fail "timeout after ${TIMEOUT}s"
    sleep 2
  done

  SNAP=$(ls -1t "$SNAP_DIR"/*.snapshot 2>/dev/null | head -1)
  [ -n "$SNAP" ] || fail "no .snapshot file in $SNAP_DIR"
  SIZE=$(du -h "$SNAP" | cut -f1)
  KEY="meilisearch/slot-$(date -u +%u%H)/meili_data.snapshot"   # overwritten weekly
  log "uploading $SNAP ($SIZE) -> $R2_BUCKET/$KEY"

  curl -sf -m 900 --aws-sigv4 "aws:amz:$R2_REGION:s3" \
    --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
    -T "$SNAP" \
    -H "Content-Type: application/octet-stream" \
    "$R2_ENDPOINT/$R2_BUCKET/$KEY" \
    || fail "R2 upload failed"

  REMOTE=$(curl -sf -m 30 --aws-sigv4 "aws:amz:$R2_REGION:s3" \
    --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
    "$R2_ENDPOINT/$R2_BUCKET/$KEY" | wc -c)
  LOCAL=$(stat -c%s "$SNAP")
  [ "$REMOTE" = "$LOCAL" ] || fail "size mismatch: local=$LOCAL remote=$REMOTE"
  log "size verified OK ($LOCAL bytes)"

  prune_local '*.snapshot'
fi

log "done"
