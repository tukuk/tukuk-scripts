#!/usr/bin/env bash
# ==============================================================================
# hf-model-pull.sh — install one of OUR published models from Hugging Face onto
# this server, then register it with Ollama.
#
#   sudo bash scripts/hf-model-pull.sh                 # every registry entry
#   sudo bash scripts/hf-model-pull.sh tukuk-builder-mini
#   sudo bash scripts/hf-model-pull.sh tukuk/xyz xyz-q4_k_m.gguf   # ad-hoc
#
# The registry (ai-models/registry.json) is the source of truth: it names the HF
# repo, the GGUF file and the Ollama tag. /api/models derives "installed" from the
# file's presence here, so this script is the only thing that flips it.
#
# INTEGRITY: when the repo publishes metrics.json, its gguf.sha256 is compared with
# the downloaded file. A mismatch ABORTS the install — a truncated download must
# never be registered as a working model.
#
# Rollback: the previous file is kept as <name>.prev next to the new one.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../deploy/paths.sh
. ./deploy/paths.sh

MODEL_DIR="$TUKUK_MODEL_DIR"
STAGING="$TUKUK_MODEL_STAGING"
OLLAMA_HOST_ADDR="${OLLAMA_HOST:-127.0.0.1:11434}"
TARGET="${1:-}"
ADHOC_FILE="${2:-}"

command -v node >/dev/null 2>&1 || { echo "✗ node is required (registry parsing)"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "need root: sudo bash $0 [model-id]"; exit 1; }
mkdir -p "$MODEL_DIR" "$STAGING"

# read_field <model-id> <repo|file|tag>
read_field() {
  node -e '
    const fs = require("fs");
    const reg = JSON.parse(fs.readFileSync("ai-models/registry.json", "utf8"));
    const m = (reg.models || []).find((x) => x.id === process.argv[1]);
    if (!m) process.exit(3);
    const out = { repo: m.hfRepo, file: m.hfFile, tag: m.ollamaTag || "" }[process.argv[2]];
    if (!out) process.exit(4);
    process.stdout.write(String(out));
  ' "$1" "$2"
}

list_ids() {
  node -e '
    const fs = require("fs");
    const reg = JSON.parse(fs.readFileSync("ai-models/registry.json", "utf8"));
    (reg.models || []).forEach((m) => console.log(m.id));
  '
}

download() { # download <repo> <hf-file> <local-name>
  local repo="$1" hf_file="$2" local_name="$3"
  local dest="$STAGING/$local_name"
  local url="https://huggingface.co/${repo}/resolve/main/${hf_file}"
  local auth=()
  [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")
  echo "── download $repo/$hf_file"
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 "${auth[@]}" -o "$dest" "$url"; then
    echo "✗ download failed: $url"; echo "  Private/gated repo? export HF_TOKEN=hf_... then retry."; return 1
  fi
  [ -s "$dest" ] || { echo "✗ downloaded file is empty"; return 1; }
  # A GGUF is a binary, never an HTML error page.
  head -c 4 "$dest" | grep -q 'GGUF' || { echo "✗ not a GGUF file (server returned something else)"; return 1; }
  echo "✓ $(du -h "$dest" | cut -f1)"
}

verify_sha() { # verify_sha <repo> <staging-file>
  local repo="$1" file="$2" expected actual
  expected="$(curl -fsSL --connect-timeout 15 "https://huggingface.co/${repo}/resolve/main/metrics.json" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String((j.gguf&&j.gguf.sha256)||""))}catch{}})')"
  if [ -z "$expected" ]; then
    echo "… metrics.json has no gguf.sha256 — integrity check skipped (not a failure)"
    return 0
  fi
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$expected" != "$actual" ]; then
    echo "✗ sha256 mismatch"; echo "  expected $expected"; echo "  actual   $actual"
    return 1
  fi
  echo "✓ sha256 matches the published metrics.json"
}

install_model() { # install_model <repo> <hf-file> <tag>
  local repo="$1" hf_file="$2" tag="$3"
  local name; name="$(basename "$hf_file")"
  local staged="$STAGING/$name"
  local dest="$MODEL_DIR/$name"

  download "$repo" "$hf_file" "$name" || return 1
  verify_sha "$repo" "$staged" || return 1

  [ -f "$dest" ] && { cp -f "$dest" "$dest.prev"; echo "… previous copy kept at $dest.prev"; }
  install -m 0644 -o tukuk -g tukuk "$staged" "$dest" 2>/dev/null || install -m 0644 "$staged" "$dest"
  echo "✓ installed $dest"

  if [ -z "$tag" ]; then
    echo "… no ollamaTag in the registry — file installed, no Ollama tag created"
    return 0
  fi
  if ! command -v ollama >/dev/null 2>&1; then
    echo "… ollama CLI not found — register later with:"
    echo "   printf 'FROM $dest\\n' > /tmp/Modelfile && OLLAMA_HOST=$OLLAMA_HOST_ADDR ollama create $tag -f /tmp/Modelfile"
    return 0
  fi
  printf 'FROM %s\n' "$dest" > "$STAGING/Modelfile"
  if env OLLAMA_HOST="$OLLAMA_HOST_ADDR" ollama create "$tag" -f "$STAGING/Modelfile" >/dev/null 2>&1; then
    echo "✓ ollama tag created: $tag"
    env OLLAMA_HOST="$OLLAMA_HOST_ADDR" ollama list 2>/dev/null | grep -F "$tag" || true
  else
    echo "✗ ollama create failed — the GGUF is on disk but not registered as '$tag'."
    echo "  Check that the daemon is up: systemctl is-active ollama"
    return 1
  fi
}

rc=0
if [ -n "$TARGET" ] && [ -n "$ADHOC_FILE" ]; then
  install_model "$TARGET" "$ADHOC_FILE" "" || rc=1
elif [ -n "$TARGET" ]; then
  repo="$(read_field "$TARGET" repo)" || { echo "✗ '$TARGET' is not in ai-models/registry.json"; echo "  known ids: $(list_ids | tr '\n' ' ')"; exit 1; }
  file="$(read_field "$TARGET" file)" || { echo "✗ '$TARGET' has no hfFile in the registry"; exit 1; }
  tag="$(read_field "$TARGET" tag || true)"
  install_model "$repo" "$file" "$tag" || rc=1
else
  ids="$(list_ids)"
  [ -n "$ids" ] || { echo "✗ no models in ai-models/registry.json"; exit 1; }
  for id in $ids; do
    repo="$(read_field "$id" repo)" && file="$(read_field "$id" file)" && tag="$(read_field "$id" tag || true)" || { echo "✗ skip $id (incomplete registry entry)"; rc=1; continue; }
    install_model "$repo" "$file" "$tag" || rc=1
  done
fi

echo
if [ "$rc" = 0 ]; then
  echo "✓ done — check https://tukuk.org/models (or curl -s localhost:3000/api/models | grep -A2 publishedModels)"
  echo "  The model is now available to Ollama; add it to LLM_CHAIN/LLM_CLOUD_ORDER only if you want /ask to use it."
else
  echo "⚠ finished with errors — see above. Nothing partial is registered as installed unless the file+variant checks passed."
fi
exit "$rc"
