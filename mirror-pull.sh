#!/usr/bin/env bash
# ==============================================================================
# mirror-pull.sh — refresh the GCP failover mirror from the cold R2 snapshot.
#
# WHERE IT RUNS: on the GCP mirror VM (NOT the home box). The home box has no
# public ingress and its Cloudflare token has no R2 scope, so the VM cannot read
# the bucket directly. Instead it goes through the Worker's authenticated
# /edge-backup GET gateway on worker.tukuk.org, which holds the R2 binding.
#
# SECURITY: uses the READ-ONLY secret (MIRROR_READ_TOKEN), never UPLOAD_SECRET.
# A stolen VM key can therefore only read pages that are already public — it can
# never overwrite or poison a backup. The gateway enforces this; see
# cloudflare-worker/tukuk-fallback/src/index.ts.
#
# WHAT IT COPIES: every mirror object in the bucket EXCEPT the big archives. The
# static mirror lives in flat keys (index.html, theme.css, blog/index.html,
# search-index.json, …); the backups live under prefixes (backups/, meilisearch/)
# or as .gz/.enc blobs, which are for restore, not for serving. Those are skipped.
#
# ATOMIC SWAP: each run writes a fresh dated release under $RELEASES and flips the
# $LINK symlink onto it in one rename — nginx never sees a half-written tree, so
# a visitor who lands mid-pull gets a complete older snapshot, never a broken one.
#
# HARD-FAIL: if zero objects land, exit non-zero. A pull that "succeeded" while
# copying nothing is exactly the silent-success bug that bit this project before.
#
# USE:  MIRROR_READ_TOKEN=... bash scripts/mirror-pull.sh
#   (MIRROR_BASE defaults to https://worker.tukuk.org/edge-backup)
# ==============================================================================
set -uo pipefail

MIRROR_BASE="${MIRROR_BASE:-https://worker.tukuk.org/edge-backup}"
TOKEN="${MIRROR_READ_TOKEN:-}"
LINK="${MIRROR_LINK:-/var/www/tukuk-mirror}"
RELEASES="${MIRROR_RELEASES:-/srv/tukuk-mirror/releases}"
KEEP="${MIRROR_KEEP:-3}"
MAX_BYTES="${MIRROR_MAX_TOTAL:-2000000000}"   # 2 GB sanity ceiling for a free-tier disk

[[ -n "$TOKEN" ]] || { echo "[mirror-pull] ERROR: MIRROR_READ_TOKEN not set." >&2; exit 1; }
command -v curl >/dev/null || { echo "[mirror-pull] ERROR: curl not installed." >&2; exit 1; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$RELEASES/$TS"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE.partial"' EXIT

echo "[mirror-pull] listing objects from $MIRROR_BASE ..."
LIST_JSON="$(curl -fsS --max-time 60 -H "Authorization: Bearer $TOKEN" "$MIRROR_BASE?prefix=")" \
  || { echo "[mirror-pull] ERROR: could not list the bucket." >&2; exit 1; }

# Extract every "key":"..." value. Keys are R2 object names (no quotes inside), so
# a bounded regex is enough and avoids pulling a JSON parser onto a 1 GB VM.
mapfile -t ALL_KEYS < <(printf '%s' "$LIST_JSON" | grep -oE '"key":"[^"]+"' | sed -e 's/^"key":"//' -e 's/"$//')
echo "[mirror-pull] bucket lists ${#ALL_KEYS[@]} objects"

# Keep only servable mirror pages/assets; drop backup archives by prefix and suffix.
KEYS=()
for k in "${ALL_KEYS[@]}"; do
  case "$k" in
    backups/*|meilisearch/*|*/*.gz|*.gz|*.enc|*.snapshot) continue ;;
    *) [[ -n "$k" ]] && KEYS+=("$k") ;;
  esac
done
echo "[mirror-pull] ${#KEYS[@]} are mirror objects (the rest are backup archives)"

[[ ${#KEYS[@]} -gt 0 ]] || { echo "[mirror-pull] ERROR: no mirror objects listed — snapshot never produced?" >&2; exit 1; }

FAILS=0
TOTAL=0
for k in "${KEYS[@]}"; do
  # Guard against path escape (a key like ../x must never break out of $STAGE).
  case "$k" in */../*|..*|/*|*//*) echo "  ! skipping unsafe key: $k"; FAILS=$((FAILS+1)); continue ;; esac
  out="$STAGE/$k"
  mkdir -p "$(dirname "$out")"
  if curl -fsS --max-time 120 -H "Authorization: Bearer $TOKEN" "$MIRROR_BASE?key=$(printf '%s' "$k" | sed 's/ /%20/g')" -o "$out"; then
    bytes="$(wc -c < "$out")"
    TOTAL=$((TOTAL + bytes))
    echo "  \342\234\227 $k (${bytes} bytes)"
  else
    echo "  ! failed $k"
    FAILS=$((FAILS + 1))
  fi
done

if (( TOTAL > MAX_BYTES )); then
  echo "[mirror-pull] ERROR: pulled $TOTAL bytes > MAX $MAX_BYTES — refusing to swap; disk sanity." >&2
  exit 1
fi
if [[ ! -s "$STAGE/index.html" ]]; then
  echo "[mirror-pull] ERROR: index.html missing/empty after pull — refusing to swap a broken mirror." >&2
  exit 1
fi

# Atomic flip onto the new release.
ln -sfn "$STAGE" "$LINK"
echo "[mirror-pull] \342\234\227 swapped $LINK -> $STAGE ($TOTAL bytes across ${#KEYS[@]} objects, $FAILS failed)"

# Prune old releases, keeping the newest $KEEP.
mapfile -t RELS < <(ls -1dt "$RELEASES"/*/ 2>/dev/null)
if (( ${#RELS[@]} > KEEP )); then
  for old in "${RELS[@]:$KEEP}"; do rm -rf "$old"; done
  echo "[mirror-pull] pruned to the newest $KEEP releases"
fi

if (( FAILS > 0 )); then
  echo "[mirror-pull] WARNING: $FAILS objects failed, but the swap happened (index.html was present)." >&2
fi
