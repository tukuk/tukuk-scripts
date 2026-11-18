#!/usr/bin/env bash
# ==============================================================================
# import-trained-model.sh — install a model file trained/downloaded on
# Kaggle/Colab into the Tukuk-OS server safely (one-shot).
#
#   sudo bash scripts/import-trained-model.sh <file-path> [ranks|edge|brain]
#
# Destination by type:
#   ranks → fine-tune/reranker (Meilisearch/onnx reranker) + restart tukuk-os
#   edge  → models/ inside the one folder + litert-lm import (LiteRT edge tier)
#   brain → data/tukuk-brain-v1.json (AI corpus) + rebuild index
#
# Always keep a .prev copy next to the original file for easy rollback.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../deploy/paths.sh
. ./deploy/paths.sh

SRC="${1:?usage: import-trained-model.sh <file-path> [ranks|edge|brain]}"
KIND="${2:-}"
[ -f "$SRC" ] || { echo "✗ file missing: $SRC"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "need root: sudo bash $0 ..."; exit 1; }

if [ -z "$KIND" ]; then
  case "$SRC" in
    *.onnx|*rerank*) KIND=ranks ;;
    *.litertlm|*.gguf) KIND=edge ;;
    *brain*.json) KIND=brain ;;
    *) echo "✗ cannot guess the type — give a second argument: ranks|edge|brain"; exit 1 ;;
  esac
  echo "… type auto-detected: $KIND"
fi

case "$KIND" in
  ranks)
    DEST="fine-tune/reranker/$(basename "$SRC")"
    [ -f "$DEST" ] && cp -f "$DEST" "$DEST.prev"
    install -m 0644 "$SRC" "$DEST"
    systemctl restart tukuk-os && sleep 3 && systemctl is-active tukuk-os
    echo "✓ $DEST installed; tukuk-os restarted. Rollback: mv $DEST.prev $DEST && restart."
    ;;
  edge)
    DEST="$TUKUK_MODEL_DIR/$(basename "$SRC")"
    [ -f "$DEST" ] && cp -f "$DEST" "$DEST.prev"
    install -m 0644 -o tukuk -g tukuk "$SRC" "$DEST"
    sudo -u tukuk env HOME=/home/tukuk /home/tukuk/.local/bin/litert-lm import "$DEST" || exit 1
    systemctl restart litert-lm 2>/dev/null || true
    echo "✓ $DEST imported into the LiteRT registry (list: litert-lm list)."
    ;;
  brain)
    [ -f data/tukuk-brain-v1.json ] && cp -f data/tukuk-brain-v1.json data/tukuk-brain-v1.json.prev
    install -m 0644 "$SRC" data/tukuk-brain-v1.json
    sudo -u tukuk env HOME=/home/tukuk node scripts/train-brain.js || echo "⚠ train-brain failed — run manually."
    systemctl restart tukuk-os && sleep 3 && systemctl is-active tukuk-os
    echo "✓ brain corpus upgraded + index rebuilt."
    ;;
  *) echo "✗ unknown type: $KIND (ranks|edge|brain)"; exit 1 ;;
esac
