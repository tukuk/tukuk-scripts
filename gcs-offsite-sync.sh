#!/usr/bin/env bash
# ==============================================================================
# gcs-offsite-sync.sh — the third copy of the backup artefacts, in Google Cloud.
#
# R2 (bucket tukuk-fallback) is the live vault and Backblaze is the second line. Both
# live at the same two providers as everything else this site runs on, so a billing
# accident or an account problem at either one takes the vault with the site. The
# always-free GCS allowance (5 GB standard, us-central1) is big enough to hold the
# newest slices of the vault: the identity tarball (already AES-encrypted, so nothing
# readable lands in Google), the content snapshot, and the last N data slices.
#
# It never creates artefacts of its own — it mirrors what the R2 timers already wrote,
# so there is exactly one definition of "a backup" in this project.
#
# COST: reads through the worker gateway (Cloudflare egress, free) and writes to GCS
# inside the 5 GB / 5 k class-A-op free tier. The size cap below refuses to run past
# 4 GB so the allowance can never be exceeded by drift.
#
# Reads go to worker.tukuk.org, NOT the *.workers.dev hostname in .env: workers.dev is
# platform-throttled (HTTP 429) under load, which is what silently killed the upload
# timers before they moved onto the zone.
#
# USE:    sudo systemctl start tukuk-gcs-offsite.service   (weekly timer)
# VERIFY: gcloud storage ls -l gs://tukuk-os-offsite/r2/backups/
# ==============================================================================
set -uo pipefail
export PATH="/home/tukuk/google-cloud-sdk/bin:${PATH}"
export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-/home/tukuk/.config/gcloud}"

BUCKET="${GCS_BUCKET:-gs://tukuk-os-offsite}"
DEST="${GCS_PREFIX:-r2}"
MAX_BYTES="${GCS_MAX_BYTES:-4000000000}"
KEEP_DATA="${GCS_KEEP_DATA:-12}"
KEEP_IDENTITY="${GCS_KEEP_IDENTITY:-3}"
ENVF="${TUKUK_ENV_FILE:-/opt/tukuk-os/.env}"

# Same rule as the other backup tracks: read the two values whole after the first `=`
# instead of sourcing .env, whose RP name contains a space.
_env_get() { grep -E "^[[:space:]]*$1=" "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'; }
WURL="${BACKUP_READ_URL:-https://worker.tukuk.org/edge-backup}"
WSEC="${BACKUP_UPLOAD_SECRET:-$(_env_get BACKUP_UPLOAD_SECRET)}"
[[ -n "$WSEC" ]] || { echo "[gcs-offsite] ERROR: BACKUP_UPLOAD_SECRET missing." >&2; exit 1; }
command -v gcloud >/dev/null || { echo "[gcs-offsite] ERROR: gcloud not found." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[gcs-offsite] listing the vault through $WURL ..."
if ! curl -fsS --max-time 60 -H "Authorization: Bearer $WSEC" "$WURL?prefix=backups/" -o "$TMP/list.json"; then
  echo "[gcs-offsite] ERROR: could not list backups/ — nothing mirrored." >&2
  exit 1
fi

# Pick the slices: every identity tarball is tiny and irreplaceable, content is one
# file, data is the rotating 7-day window — keep the newest N of each.
python3 - "$TMP/list.json" "$KEEP_DATA" "$KEEP_IDENTITY" > "$TMP/pick.txt" <<'PY'
import json, sys
objs = json.load(open(sys.argv[1]))['objects']
keep_data, keep_identity = int(sys.argv[2]), int(sys.argv[3])

def newest(pattern, limit):
    hits = [o for o in objs if pattern in o['key']]
    hits.sort(key=lambda o: o.get('uploaded', ''), reverse=True)
    return hits[:limit]

picked = newest('tukuk-identity', keep_identity) + newest('tukuk-content', 2) + newest('tukuk-data', keep_data)
seen = set()
for o in picked:
    if o['key'] in seen:
        continue
    seen.add(o['key'])
    print(f"{o['key']}\t{o['bytes']}")
PY

[[ -s "$TMP/pick.txt" ]] || { echo "[gcs-offsite] ERROR: no backup objects matched — nothing to mirror." >&2; exit 1; }

TOTAL=0
ok=0
failed=0
while IFS=$'\t' read -r key bytes; do
  [[ -n "$key" ]] || continue
  if (( TOTAL + bytes > MAX_BYTES )); then
    echo "[gcs-offsite] cap reached at $(( TOTAL / 1000000 )) MB — remaining slices deferred to next run."
    break
  fi
  remote="$BUCKET/$DEST/$key"
  have="$(gcloud storage ls -l "$remote" --format="value(size)" 2>/dev/null | head -1)"
  if [[ "$have" == "$bytes.so" || "$have" == "$bytes" ]]; then
    echo "  = $key (already $bytes B)"
    TOTAL=$(( TOTAL + bytes ))
    ok=$(( ok + 1 ))
    continue
  fi
  if ! curl -fsS --max-time 300 -H "Authorization: Bearer $WSEC" "$WURL?key=$key" -o "$TMP/obj" 2>/dev/null; then
    echo "  ! $key — download failed" >&2
    failed=$(( failed + 1 ))
    continue
  fi
  got="$(wc -c < "$TMP/obj")"
  if [[ "$got" != "$bytes" ]]; then
    echo "  ! $key — expected $bytes B, downloaded $got B (refusing to mirror a truncated slice)" >&2
    failed=$(( failed + 1 ))
    continue
  fi
  if gcloud storage cp --quiet --no-user-output-enabled "$TMP/obj" "$remote" 2>/dev/null; then
    echo "  + $key ($bytes B)"
    TOTAL=$(( TOTAL + bytes ))
    ok=$(( ok + 1 ))
  else
    echo "  ! $key — upload failed" >&2
    failed=$(( failed + 1 ))
  fi
done < "$TMP/pick.txt"

echo "[gcs-offsite] mirrored $ok slice(s), $(( TOTAL / 1000000 )) MB, $failed failure(s)."
(( failed == 0 )) || exit 1
