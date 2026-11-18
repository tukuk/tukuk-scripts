#!/usr/bin/env bash
# ==============================================================================
# kaggle-train-model.sh — one command: free Kaggle GPU → train our model →
# publish it on Hugging Face → (optional) install it on this server.
#
#   KAGGLE_ID=tukuk bash scripts/kaggle-train-model.sh
#   KAGGLE_ID=tukuk bash scripts/kaggle-train-model.sh --pull
#
# It is a thin, opinionated wrapper around scripts/kaggle-gpu-burst.sh:
#   [1] preflight: kaggle CLI + credentials + account GPU gate (same gate as burst)
#   [2] reminder: HF_TOKEN must exist as a KAGGLE SECRET (Add-ons → Secrets), so the
#       kernel can push the GGUF to the hub without the 4 GB passing through here
#   [3] submit kaggle-jobs/tukuk-builder-mini.py as a GPU notebook and wait
#   [4] --pull: sudo bash scripts/hf-model-pull.sh tukuk-builder-mini
#
# Nothing is charged. Nothing is faked: if a step fails the script stops and says
# which step failed; no model is ever reported as trained when it was not.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

JOB="tukuk-builder-mini"
PULL=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "✗ unknown argument: $arg (only --pull is accepted)"; exit 1 ;;
  esac
done

[ -f "kaggle-jobs/${JOB}.py" ] || { echo "✗ kaggle-jobs/${JOB}.py is missing"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "✗ node is required"; exit 1; }

KAGGLE_ID="${KAGGLE_ID:-}"
case "$KAGGLE_ID" in
  ""|*REPLACE*) echo "✗ export KAGGLE_ID=<your kaggle username> first (example: KAGGLE_ID=tukuk)"; exit 1 ;;
esac

command -v kaggle >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
command -v kaggle >/dev/null 2>&1 || { echo "✗ kaggle CLI missing: uv tool install kaggle (or pipx install kaggle)"; exit 1; }
{ [ -f "$HOME/.kaggle/kaggle.json" ] || [ -f "$HOME/.kaggle/credentials.json" ]; } \
  || { echo "✗ no ~/.kaggle credentials — run: kaggle auth login"; exit 1; }

REPO="$(node -e '
  const fs = require("fs");
  const reg = JSON.parse(fs.readFileSync("ai-models/registry.json", "utf8"));
  const m = (reg.models || []).find((x) => x.id === process.argv[1]);
  process.stdout.write(String((m && m.hfRepo) || ""));
' "$JOB")"
[ -n "$REPO" ] || { echo "✗ '$JOB' has no hfRepo in ai-models/registry.json"; exit 1; }

cat <<EOF
── target ─────────────────────────────────────────────────────────────
  job        : kaggle-jobs/${JOB}.py
  hf repo    : ${REPO}
  base model : $(node -e 'const r=require("./ai-models/registry.json");const m=r.models.find(x=>x.id===process.argv[1]);process.stdout.write(String((m&&m.base)||"?"))' "$JOB")
  GPU        : Kaggle T4 (free tier)
───────────────────────────────────────────────────────────────────────
BEFORE YOU RUN (one-time, browser):
  1. https://www.kaggle.com/code/new → Settings → Accelerator → GPU T4 x2 → Run once
     (an account that has never opened a GPU session gets CPU-only kernels silently).
  2. Kaggle → Add-ons → Secrets → add HF_TOKEN (write token from
     https://huggingface.co/settings/tokens) and enable it for your notebooks.
     Without it the kernel still trains and leaves the GGUF in /kaggle/working;
     publish it later with scripts/publish-model-hf.sh.
EOF

echo
echo "── [1/2] submit + wait for the GPU kernel ──"
KAGGLE_ID="$KAGGLE_ID" bash scripts/kaggle-gpu-burst.sh "$JOB"
TRAIN_RC=$?
if [ "$TRAIN_RC" != 0 ]; then
  echo "✗ training kernel did not complete (exit $TRAIN_RC) — nothing was published."
  echo "  Logs: kaggle kernels output ${KAGGLE_ID}/tukuk-gpu-burst-${JOB}-* -p /tmp/klog"
  exit "$TRAIN_RC"
fi

echo
echo "── [2/2] verify the hub ──"
if curl -fsSL --connect-timeout 15 "https://huggingface.co/api/models/${REPO}" >/dev/null 2>&1; then
  echo "✓ https://huggingface.co/${REPO} exists — check metrics.json there for the real numbers."
  echo "  Install on this server: sudo bash scripts/hf-model-pull.sh ${JOB}"
  if [ "$PULL" = 1 ]; then
    echo
    sudo bash scripts/hf-model-pull.sh "$JOB" || { echo "✗ pull failed — the model is on the hub but not installed here."; exit 1; }
  fi
else
  echo "… ${REPO} is not reachable yet."
  echo "  Either the kernel had no HF_TOKEN (download its output and run"
  echo "  scripts/publish-model-hf.sh), or the upload is still finishing."
fi
