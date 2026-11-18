#!/usr/bin/env bash
# ==============================================================================
# setup-litert-pilot.sh — Enable the LiteRT-LM edge AI tier PILOT on the server.
#
#   sudo bash scripts/setup-litert-pilot.sh            # install + bench
#   sudo bash scripts/setup-litert-pilot.sh --force    # even while a build runs
#
# PREREQUISITES (done by the author over SSH, automatically):
#   • uv + litert-lm v0.18 installed (/home/tukuk/.local/bin)
#   • models imported: gemma3-1b-it-int4 + embeddinggemma-300m
#     (registry: /home/tukuk/.litert-lm/models)
#   • DO NOT run while a Tukuk Agent build is running (CPU/RAM contention).
#
# This script does NOT touch src/answer.js — integration into the cloud rotation
# only after the pilot passes the benchmark and with the author's approval.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

LITERT_BIN=/home/tukuk/.local/bin/litert-lm
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3:1.7b}"

[ "$(id -u)" = 0 ] || { echo "need root: sudo bash $0"; exit 1; }

if pgrep -f build-agent-on-server >/dev/null 2>&1 && [ "${1:-}" != "--force" ]; then
  echo "✗ Tukuk Agent build still running — wait for it to finish (or --force)."
  exit 1
fi

echo "── [1] install litert-lm systemd unit ──"
[ -x "$LITERT_BIN" ] || { echo "✗ litert-lm missing at $LITERT_BIN — redo the CLI install steps."; exit 1; }
install -m 0644 deploy/litert-lm.service /etc/systemd/system/litert-lm.service
systemctl daemon-reload
systemctl enable litert-lm >/dev/null 2>&1
systemctl restart litert-lm
sleep 4
systemctl is-active --quiet litert-lm \
  && echo "✓ litert-lm ACTIVE at 127.0.0.1:8090" \
  || { echo "✗ failed — journalctl -u litert-lm -n 20:"; journalctl -u litert-lm -n 20 --no-pager; exit 1; }

echo "── [2] prepare the Ollama comparison ($OLLAMA_MODEL) ──"
if sudo -u tukuk env HOME=/home/tukuk ollama list 2>/dev/null | grep -q "$OLLAMA_MODEL"; then
  echo "✓ $OLLAMA_MODEL already present."
else
  echo "… pull $OLLAMA_MODEL (low priority; ~1.4GB):"
  sudo -u tukuk env HOME=/home/tukuk nice -n15 ollama pull "$OLLAMA_MODEL" \
    || echo "⚠ ollama pull failed — the Ollama bench will be skipped."
fi

echo "── [3] benchmark apple-to-apple (tok/s + RSS) ──"
sudo -u tukuk env HOME=/home/tukuk node scripts/bench-edge-tier.js --ollama-model "$OLLAMA_MODEL"

cat <<'EOF'
═══════════════════════════════════════════════════════════════════════
Reading the result:
  • LiteRT wins → I register http://127.0.0.1:8090/v1 as an OpenAI-compatible
    provider in the src/answer.js rotation (a separate batch,
    with tests + lint green before commit).
  • Ollama wins → the litert pilot is disabled (systemctl disable --now
    litert-lm), the model stays on disk for reference.
  • tie → consider LFM2-8B-A1B (GGUF 4.8GB — measure RAM first).
EOF
