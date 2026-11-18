#!/usr/bin/env bash
# Backup T Chat data (data/chat.json + data/chat-media/) to Cloudflare R2.
#
# Follows backup-meili.sh — two paths, one is enough:
#
#   1) WORKER (recommended, no S3 keys):
#        tar.gz snapshot -> POST to the tukuk-backup worker -> R2
#        NEEDS: BACKUP_WORKER_URL + BACKUP_UPLOAD_SECRET
#
#   2) LOCAL ONLY (no worker creds):
#        keep the tar.gz in SNAP_DIR with KEEP_LOCAL pruning — useful when
#        R2 is not configured yet, so the data is never left without any copy.
#
# All values live in ~/.config/tukuk-os/r2.env (systemd EnvironmentFile).
# Media assets can be large; the snapshot is taken without stopping the server
# (JSON is debounced-write; the copy is best-effort — may miss the last hour's writes).

set -euo pipefail

# HOME may not exist when run as root under systemd (the EnvironmentFile already
# supplies the main values, so the r2.env file is only an addition).
HOME="${HOME:-/home/tukuk}"
if [ -f "${HOME}/.config/tukuk-os/r2.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${HOME}/.config/tukuk-os/r2.env"
  set +a
fi

# APP_DIR: env value → this script's location (most reliable) → old default.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$SELF_DIR}"
SNAP_DIR="${SNAP_DIR:-$APP_DIR/snapshots}"
DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
R2_BUCKET="${R2_BUCKET:-tukuk-os-backups}"
KEEP_LOCAL="${KEEP_LOCAL:-3}"
TIMEOUT="${TIMEOUT:-900}"

log() { printf '[chat-backup] %s\n' "$*"; }
fail() { printf '[chat-backup] ERROR: %s\n' "$*" >&2; exit 1; }

# treat <...> placeholders as not yet filled in
usable() {
  case "${1:-}" in
    ''|'<'*'>'|*'<your'*) return 1 ;;
    *) return 0 ;;
  esac
}

usable "${BACKUP_WORKER_URL:-}" && usable "${BACKUP_UPLOAD_SECRET:-}" && WORKER_OK=1 || WORKER_OK=0

CHAT_JSON="$DATA_DIR/chat.json"
CHAT_MEDIA="$DATA_DIR/chat-media"
# No chat.json means T Chat has never been used on this box, which is not a backup failure.
# The old `|| fail` turned every timer run red (exit 1) for a server that simply has no chat
# data yet — and data/ is already covered by tukuk-data-backup. Skip cleanly instead.
if [ ! -f "$CHAT_JSON" ]; then
  log "no $CHAT_JSON — T Chat has no data on this server yet; nothing to back up (skip)"
  exit 0
fi

mkdir -p "$SNAP_DIR"

upload_wrangler() {
  # Direct R2 via wrangler — bypasses the throttled workers.dev edge entirely.
  # Only works once CLOUDFLARE_API_TOKEN has Account·R2 Storage·Read & Edit (README §9).
  local file="$1" key="$2"
  log "trying wrangler path for $(basename "$file") -> ${R2_BUCKET:-tukuk-fallback}/$key"
  npx --yes wrangler r2 object put "${R2_BUCKET:-tukuk-fallback}/$key" --file "$file" \
    --content-type application/gzip --remote >/dev/null 2>&1
}

upload_worker() {
  local file="$1" key="$2"
  local size remote
  size=$(stat -c%s "$file")
  log "uploading $(basename "$file") ($size bytes) -> $R2_BUCKET/$key"
  curl -sf -m "$TIMEOUT" -X POST \
    -H "Authorization: Bearer $BACKUP_UPLOAD_SECRET" \
    -H "Content-Type: application/gzip" \
    --data-binary "@$file" \
    "$BACKUP_WORKER_URL/?key=$key" \
    || { log "worker upload failed (edge 429?) — trying wrangler path"
         upload_wrangler "$file" "$key" && { log "wrangler upload OK"; return 0; }
         fail "both upload paths failed"; }
  remote=$(curl -sf -m 60 -H "Authorization: Bearer $BACKUP_UPLOAD_SECRET" \
    "$BACKUP_WORKER_URL/?key=$key" -o /dev/null -w '%{size_download}') || remote=""
  if [ "$remote" != "$size" ]; then
    log "worker verify failed/mismatch (local=$size remote=${remote:-empty}) — trying wrangler path"
    upload_wrangler "$file" "$key" && { log "wrangler upload OK"; return 0; }
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

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# Slot key, not a timestamp key: the R2 object is overwritten in place, so the bucket cannot
# grow without limit (Cloudflare's free R2 tier ends at 10 GB). weekday+hour = 168 slots = a
# full 7 days of history. Same scheme as scripts/backup-data.sh and backup-meili.sh.
SLOT="slot-$(date -u +%u%H)"
OUT="$SNAP_DIR/tukuk-chat-${STAMP}.tar.gz"
log "creating T Chat snapshot ($OUT)..."

# Copy JSON to staging (avoid reading the file during a debounce write → half snapshot),
# and use a symlink to media so tar does not double the space. -h (dereference)
# puts the real media content into the archive.
STAGE=$(mktemp -d)
cp "$CHAT_JSON" "$STAGE/chat.json"
if [ -d "$CHAT_MEDIA" ]; then
  ln -s "$CHAT_MEDIA" "$STAGE/chat-media"
  tar -czh -f "$OUT" -C "$STAGE" chat.json chat-media
else
  tar -cz -f "$OUT" -C "$STAGE" chat.json
fi
rm -rf "$STAGE"

[ -s "$OUT" ] || fail "snapshot empty/failed"
SIZE=$(du -h "$OUT" | cut -f1)
log "snapshot ready ($SIZE)"

if [ "$WORKER_OK" = 1 ]; then
  upload_worker "$OUT" "tukuk-chat/$SLOT/tukuk-chat.tar.gz"
elif usable "${CLOUDFLARE_API_TOKEN:-}"; then
  upload_wrangler "$OUT" "tukuk-chat/$SLOT/tukuk-chat.tar.gz" \
    || fail "no working upload path (worker unset, wrangler failed — token likely lacks R2 scope)"
else
  log "WORKER OK=0 — keep local only (fill BACKUP_WORKER_URL+BACKUP_UPLOAD_SECRET for R2)"
fi
prune_local 'tukuk-chat-*.tar.gz'

log "done"
