#!/usr/bin/env bash
# ==============================================================================
# publish-model-hf.sh — upload a model artifact from THIS box to the Hugging Face
# hub (the fallback path: normally the Kaggle kernel pushes it itself, because the
# 3-4 GB GGUF does not need to travel through the server).
#
#   HF_TOKEN=hf_... bash scripts/publish-model-hf.sh <file.gguf> [repo]
#   HF_TOKEN=hf_... bash scripts/publish-model-hf.sh <file.gguf> --id tukuk-builder-mini
#
# Sidecar files uploaded when present next to <file.gguf>:
#   metrics.json  — honest numbers from the training run (sha256, loss, wall clock)
#   README.md     — model card
#
# The token is required and never stored. Use a 'write' scoped token; no pip install
# happens unless HF_ALLOW_PIP=1 is set explicitly.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: HF_TOKEN=hf_... bash scripts/publish-model-hf.sh <file> [repo|--id <model-id>]"; exit 1; }
[ -f "$SRC" ] || { echo "✗ file not found: $SRC"; exit 1; }
shift

DEFAULT_REPO="$(node -e '
  try {
    const reg = require("./ai-models/registry.json");
    process.stdout.write(String((reg.models && reg.models[0] && reg.models[0].hfRepo) || ""));
  } catch {}
')"

REPO=""
if [ "${1:-}" = "--id" ]; then
  REPO="$(node -e '
    const fs = require("fs");
    const reg = JSON.parse(fs.readFileSync("ai-models/registry.json", "utf8"));
    const m = (reg.models || []).find((x) => x.id === process.argv[1]);
    process.stdout.write(String((m && m.hfRepo) || ""));
  ' "${2:-}")"
  [ -n "$REPO" ] || { echo "✗ --id '${2:-}' has no hfRepo in ai-models/registry.json"; exit 1; }
else
  REPO="${1:-$DEFAULT_REPO}"
fi
[ -n "$REPO" ] || { echo "✗ no repo given and the registry has no entry — pass user/name"; exit 1; }

[ -n "${HF_TOKEN:-}" ] || { echo "✗ HF_TOKEN is empty — create a write token at https://huggingface.co/settings/tokens"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "✗ python3 is required"; exit 1; }

if ! python3 -c "import huggingface_hub" >/dev/null 2>&1; then
  if [ "${HF_ALLOW_PIP:-0}" = "1" ]; then
    echo "… installing huggingface_hub (HF_ALLOW_PIP=1)"
    python3 -m pip install --quiet --user "huggingface_hub>=0.24" || { echo "✗ pip install failed"; exit 1; }
  else
    echo "✗ python3 has no huggingface_hub."
    echo "  Install it explicitly, then re-run:  python3 -m pip install --user 'huggingface_hub>=0.24'"
    echo "  (or set HF_ALLOW_PIP=1 to let this script do it)"
    exit 1
  fi
fi

FILE_NAME="$(basename "$SRC")"
DIR_NAME="$(dirname "$SRC")"
export HF_TOKEN REPO SRC FILE_NAME DIR_NAME

echo "── upload $FILE_NAME → $REPO"
python3 - "$REPO" "$SRC" "$DIR_NAME" <<'PY'
import os, sys

repo, src, dir_name = sys.argv[1], sys.argv[2], sys.argv[3]
from huggingface_hub import HfApi

api = HfApi(token=os.environ["HF_TOKEN"])
api.create_repo(repo_id=repo, repo_type="model", exist_ok=True)

uploaded = [api.upload_file(path_or_fileobj=src, path_in_repo=os.path.basename(src),
                            repo_id=repo, commit_message=f"publish {os.path.basename(src)}")]
for sidecar in ("metrics.json", "README.md"):
    path = os.path.join(dir_name, sidecar)
    if os.path.exists(path):
        uploaded.append(api.upload_file(path_or_fileobj=path, path_in_repo=sidecar, repo_id=repo,
                                        commit_message=f"publish {sidecar}"))
    else:
        print(f"… {sidecar} not found next to the model — skipped (metrics stay honest: absent, not invented)")

for info in uploaded:
    print(f"✓ {info.path_in_repo}")
print(f"PUBLISHED https://huggingface.co/{repo}")
PY
rc=$?
if [ "$rc" = 0 ]; then
  echo
  echo "Install it here: sudo bash scripts/hf-model-pull.sh <model-id>"
else
  echo "✗ upload failed (exit $rc)"
fi
exit "$rc"
