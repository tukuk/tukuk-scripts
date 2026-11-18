#!/usr/bin/env bash
# wordbank-sync.sh — pull tukuk.org's first-party word bank off the public GitHub releases and load
# it into Meilisearch (index `kata`).
#
# Direction of travel matters here: the expensive half (building the bank) runs free on GitHub's
# public runners in tukuk/tukuk-devops; this script only DOWNLOADS finished files and LOADS them.
# That keeps the production box light, which is the whole point of the split.
#
# Five rolling releases feed the box:
#   wordbank-latest   en            (WordNet,            wordbank-build.yml)   → kata
#   malaybank-latest  ms+id         (raw wiktextract,    malaybank-build.yml)   → kata
#   wikibank-latest   wiki titles   (en.wiki summaries,  wikibank-build.yml)    → wiki
#   apodbank-latest   dated APODs   (science.nasa.gov pages, apodbank-build.yml) → apod
#   quakebank-latest  35-day quakes (USGS window,       quakebank-build.yml)    → quake
# Every release is DOWNLOADED AND VERIFIED FIRST; only when all checksums pass do we load, and the
# kata load wipes exactly once (WORDBANK_FRESH=1 on the very first file, 0 on the rest). A failed
# download therefore leaves yesterday's index untouched, and a per-file wipe can never erase the
# language loaded before it. wikibank/apodbank/quakebank-latest are optional (each only exists
# once its daily build has run at least once) — a missing or half-finished optional release must
# never block the word banks.
#
# It verifies SHA256SUMS before loading anything. A truncated download on a home connection is not
# a build failure unless we make it one — so we make it one.
#
# Reads env (from /opt/tukuk-os/.env on the server): MEILI_HOST, MEILI_MASTER_KEY.
set -euo pipefail

REPO="${WORDBANK_REPO:-tukuk/tukuk-devops}"
# Space-separated rolling tags, in load order. The first file of the FIRST tag does the kata wipe.
TAGS="${WORDBANK_TAGS:-wordbank-latest malaybank-latest wikibank-latest apodbank-latest quakebank-latest}"
# Tags whose absence is a warning, not a sync failure.
OPTIONAL_TAGS="${WORDBANK_OPTIONAL_TAGS:-wikibank-latest apodbank-latest quakebank-latest}"
DEST="${WORDBANK_DIR:-$(cd "$(dirname "$0")/.." && pwd)/data/wordbank}"
NODE="${NODE:-node}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---- phase 1: download + verify every release (indexes still untouched) ----
ALL_FILES=()
for TAG in $TAGS; do
  IS_OPTIONAL=0
  for o in $OPTIONAL_TAGS; do [ "$o" = "$TAG" ] && IS_OPTIONAL=1 && break; done
  BASE="https://github.com/${REPO}/releases/download/${TAG}"
  DIR="$DEST/$TAG"
  mkdir -p "$DIR"
  cd "$DIR"
  echo "[wordbank] downloading checksums + manifest from ${BASE}"
  if ! curl -fsSL --retry 3 --max-time 60 -o SHA256SUMS "${BASE}/SHA256SUMS" \
    || ! curl -fsSL --retry 3 --max-time 60 -o manifest.json "${BASE}/manifest.json"; then
    if [ "$IS_OPTIONAL" = 1 ]; then
      echo "[wordbank] $TAG not published yet — skipping it (word banks still sync)" >&2
      continue
    fi
    echo "[wordbank] $TAG download FAILED and it is not optional" >&2
    exit 1
  fi

  # Download every data file the manifest declares, then verify the whole set. We trust manifest.json
  # (not SHA256SUMS alone) for the file list because SHA256SUMS also names manifest.json itself.
  mapfile -t FILES < <(python3 -c "import json;[print(f['file']) for f in json.load(open('manifest.json'))['files']]" 2>/dev/null \
    || grep -o '"file": *"[^"]*"' manifest.json | sed 's/.*: *"\(.*\)"/\1/')
  if [ "${#FILES[@]}" -eq 0 ]; then
    if [ "$IS_OPTIONAL" = 1 ]; then
      echo "[wordbank] $TAG manifest lists no files — optional, skipping" >&2
      continue
    fi
    echo "[wordbank] $TAG manifest lists no files — refusing to sync an empty bank" >&2
    exit 1
  fi
  for f in "${FILES[@]}"; do
    echo "[wordbank] fetch $TAG/$f"
    # 600s: wikibank.jsonl.gz grows toward ~150 MB; the word-bank files finish in seconds.
    curl -fsSL --retry 3 --max-time 600 -o "$f" "${BASE}/$f"
  done

  echo "[wordbank] verifying sha256 for $TAG"
  # Verify ONLY the manifest-listed files here; SHA256SUMS was re-downloaded fresh so its own line
  # cannot be checked against itself, but every data file is checked before it is trusted.
  sha256sum -c --ignore-missing SHA256SUMS

  for f in "${FILES[@]}"; do
    ALL_FILES+=("$TAG:$DIR/$f")
  done
done

# ---- phase 2: load everything, kata wiping exactly once at the start ----
FRESH=1
for entry in "${ALL_FILES[@]}"; do
  tag="${entry%%:*}"; path="${entry#*:}"
  if [ "$tag" = "wikibank-latest" ]; then
    # Whole-file snapshot into its own index — wikibank-load.js owns the wipe for `wiki`.
    echo "[wordbank] loading $path into Meilisearch (wiki)"
    "$NODE" "$ROOT/scripts/wikibank-load.js" "$path"
  elif [ "$tag" = "apodbank-latest" ]; then
    # Dated APOD archive into its own `apod` index — apod-load.js owns the wipe.
    echo "[wordbank] loading $path into Meilisearch (apod)"
    "$NODE" "$ROOT/scripts/apod-load.js" "$path"
  elif [ "$tag" = "quakebank-latest" ]; then
    # Rolling 35-day USGS window into its own `quake` index — quake-load.js owns the wipe.
    echo "[wordbank] loading $path into Meilisearch (quake)"
    "$NODE" "$ROOT/scripts/quake-load.js" "$path"
  else
    echo "[wordbank] loading $path into Meilisearch (kata, fresh=$FRESH)"
    WORDBANK_FRESH="$FRESH" "$NODE" "$ROOT/scripts/wordbank-load.js" "$path"
    FRESH=0
  fi
done

echo "[wordbank] sync complete ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
