#!/usr/bin/env bash
# ==============================================================================
# backup-data.sh — copy Tukuk-OS runtime data (chat, leaderboard, publishes,
# comments, plays, stats) to Cloudflare R2 (bucket: tukuk-fallback).
#
# Run by the hourly timer (tukuk-data-backup.timer). ROTATING KEY:
# tukuk-data-<day><hour>.tar.gz (168 slots = a full 7 days) — writing to the
# same slot every week means NO delete API is needed; there are always 168
# recent copies without wasting space.
#
# USE:    BACKUP_WORKER_URL=... BACKUP_UPLOAD_SECRET=... bash scripts/backup-data.sh
#         (old fallback: CLOUDFLARE_API_TOKEN + wrangler — the VPS token has no
#         R2 scope, so the worker path is the primary path)
# RESTORE: bash scripts/restore-data.sh [key]   (empty key → current-hour slot)
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

BUCKET="${R2_BUCKET:-tukuk-fallback}"
DATA_DIR="${DATA_DIR:-data}"
WURL="${BACKUP_WORKER_URL:-}"
WSEC="${BACKUP_UPLOAD_SECRET:-}"
if [[ -z "$WURL" || -z "$WSEC" ]]; then
  # no worker path → try wrangler (only works if the token has R2:Edit)
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { echo "[backup] no BACKUP_WORKER_URL/SECRET & no R2 token — skip."; exit 0; }
fi
[[ -d "$DATA_DIR" ]] || { echo "[backup] $DATA_DIR missing — skip."; exit 0; }

KEY="backups/tukuk-data-$(date -u +%u%H).tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[backup] packing tar $DATA_DIR → $TMP/data.tar.gz ..."
tar czf "$TMP/data.tar.gz" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"; TARRC=$?
# exit 1 = "file changed as we read it": data/ is written live by the app; the
# archive is still valid (that one member may be one flush stale). Only ≥2 is fatal.
if [[ $TARRC -ge 2 ]]; then
  echo "[backup] ERROR: tar failed (rc=$TARRC)" >&2; exit 1
elif [[ $TARRC -eq 1 ]]; then
  echo "[backup] WARN: a file changed mid-read (live writes) — continuing with usable archive" >&2
fi
SIZE="$(du -h "$TMP/data.tar.gz" | cut -f1)"

# Keep the newest archive on the box. Two reasons: a second-provider job can
# mirror a finished file instead of re-reading the live data dir while the app
# writes to it, and a restore can start from the disk it is restoring to. It is
# overwritten in place each run, so this costs one archive (~18 MB), not a slot
# per hour. Written via tmp+mv: a half-written "latest" file is worse than none.
KEEP=/var/backups/tukuk-data-latest.tar.gz
cp "$TMP/data.tar.gz" "$KEEP.part" && mv -f "$KEEP.part" "$KEEP" \
  && chmod 600 "$KEEP" \
  || echo "[backup] WARN: could not retain $KEEP" >&2

echo "[backup] sending $KEY ($SIZE) to R2 ..."
if [[ -n "$WURL" && -n "$WSEC" ]]; then
  # The upload endpoint is a *.workers.dev URL, and 429 there means one of two unrelated
  # things. A root GET answering `error code: 1027` is the ACCOUNT's daily free Worker
  # request cap (Workers Free: 100,000 requests/day, reset at 00:00 UTC) — proved on 30 Oct
  # 2026 by crossing the reset: 429/1027 at 23:59 UTC, this worker's own 403 at 00:02 UTC,
  # and this exact upload landed 90 s later. Anything else is congestion at the shared
  # edge. `curl -f` cannot tell them apart, exits non-zero for BOTH, and — the part that
  # bit once already — it also throws the error page away, so the body has to be captured
  # explicitly: read the status with -w, the page with -o, and drop -f entirely.
  ATTEMPTS=0
  RBODY="$(mktemp)"
  while :; do
    RCODE="$(curl -sS --max-time 120 -o "$RBODY" -w '%{http_code}' -X POST \
       -H "Authorization: Bearer $WSEC" -H "x-content-type: application/gzip" \
       --data-binary "@$TMP/data.tar.gz" "$WURL/?key=$KEY" 2>/dev/null || echo 000)"
    [[ "$RCODE" =~ ^2 ]] && break
    if grep -q "error code: 1027" "$RBODY" 2>/dev/null; then
      echo "[backup] worker refused: the account's daily free Worker request cap is spent (error 1027) — it resets 00:00 UTC, so no retry can help before then" >&2
      WORKER_FAILED=1
      break
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    if [[ $ATTEMPTS -ge 4 ]]; then
      # Workers.dev edge still refused after the full backoff. Do NOT give up: fall
      # through to the wrangler path below. The moment the VPS CLOUDFLARE_API_TOKEN
      # gains Account·R2 Storage·Read & Edit (README §9), uploads self-heal with no
      # further human action — and that path spends zero Worker requests.
      echo "[backup] worker path failed after $ATTEMPTS tries (HTTP $RCODE) — trying wrangler path" >&2
      WORKER_FAILED=1
      break
    fi
    case $ATTEMPTS in 1) SLEEP=8 ;; 2) SLEEP=20 ;; *) SLEEP=45 ;; esac
    echo "[backup] worker POST failed (HTTP $RCODE) — retry $ATTEMPTS/3 in ${SLEEP}s" >&2
    sleep "$SLEEP"
  done
  rm -f "$RBODY"
  if [[ -z "${WORKER_FAILED:-}" ]]; then
    echo "[backup] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [worker]"
    exit 0
  fi
fi
if npx --yes wrangler r2 object put "$BUCKET/$KEY" --file "$TMP/data.tar.gz" --remote >/dev/null 2>&1; then
  echo "[backup] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [wrangler]"
else
  echo "[backup] ERROR: failed to send to R2" >&2; exit 1
fi
