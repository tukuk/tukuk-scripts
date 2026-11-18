#!/usr/bin/env bash
# ==============================================================================
# kaggle-gpu-burst.sh — borrow Kaggle's free GPU (30 hours/week) for server
# batch jobs that don't fit on CPU: occasionally, with no cost at all.
#
#   bash scripts/kaggle-gpu-burst.sh smoke                 # demo job (GPU check)
#   KAGGLE_ID=<username-kaggle> bash scripts/kaggle-gpu-burst.sh <job-name>
#
# ONE-TIME PREREQUISITES (needs a Kaggle web login — the author can't automate it):
#   1. Server: kaggle auth login   (or place an old kaggle.json in ~/.kaggle/)
#   2. Replace KAGGLE_ID / pass KAGGLE_ID=<username-kaggle> when invoking.
#
# How it works (per ToS — uses the official kernel API, no browser hacks):
#   [1] kaggle-jobs/<job>.py is submitted as a GPU kernel (kernels push)
#   [2] status is polled until "Complete" (or timeout)
#   [3] the kernel output is downloaded → /opt/tukuk-os/generated/gpu/<job>-<ts>/
#   Any .litertlm/.gguf/.bin files in the output can be imported with
#   scripts/import-trained-model.sh.
#
# LIMITS: 1 kernel at a time; never send secret data (this repo is private;
# the tukuk-brain corpus must NOT be pushed as a dataset to Kaggle).
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

KAGGLE_ID="${KAGGLE_ID:-REPLACE-WITH-USERNAME}"   # Kaggle username only
POLL_MAX_MIN="${POLL_MAX_MIN:-45}"     # small gemma/fit usually finishes <30 min
OUT_ROOT="/opt/tukuk-os/generated/gpu"
JOB="${1:-smoke}"

command -v kaggle >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
command -v kaggle >/dev/null 2>&1 || { echo "✗ kaggle CLI missing (uv tool install kaggle)."; exit 1; }
[ -f "$HOME/.kaggle/kaggle.json" ] || [ -f "$HOME/.kaggle/credentials.json" ] || { echo "✗ no kaggle.json nor credentials.json in ~/.kaggle — run: kaggle auth login"; exit 1; }
SRC="kaggle-jobs/${JOB}.py"
[ -f "$SRC" ] || { echo "✗ job '$JOB' missing — available: $(ls kaggle-jobs/*.py | xargs -n1 basename | sed 's/\.py//' | tr '\n' ' ')"; exit 1; }
case "$KAGGLE_ID" in *REPLACE*) echo "✗ pass KAGGLE_ID=<username-kaggle> (example: KAGGLE_ID=tukuk)"; exit 1;; esac

# ── Account-gate preflight (experience: 7 wasted runs): even when enable_gpu +
# machine_shape + --accelerator + docker_image are all correct, the API still
# silently runs on CPU if the account has never started its first GPU session (can
# only be unlocked once via the Kaggle web UI). The SDK quota_view exposes hasEverRun.
KPY=""
for cand in "$HOME/.local/share/pipx/venvs/kaggle/bin/python3" "$(command -v python3)"; do
  [ -x "$cand" ] && "$cand" -c "import kaggle" 2>/dev/null && { KPY="$cand"; break; }
done
if [ -n "$KPY" ] && [ "${KAGGLE_FORCE:-0}" != "1" ]; then
  HASRUN="$("$KPY" -c 'from kaggle.api.kaggle_api_extended import KaggleApi; a=KaggleApi(); a.authenticate(); q=a.quota_view(); print(str(bool(q.gpu_quota.has_ever_run)).lower())' 2>/dev/null || echo unknown)"
  if [ "$HASRUN" = "false" ]; then
    echo "⚠ Kaggle account gate: no first GPU session yet — the API will run on CPU only."
    echo "  Open it once in a browser: https://www.kaggle.com/code/new → Settings → Accelerator →"
    echo "  GPU T4 x2 → Run (accept terms / phone verification if asked). After that it stays automatic."
    echo "  Skip this check: KAGGLE_FORCE=1 bash scripts/kaggle-gpu-burst.sh $JOB"
    exit 2
  fi
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The kernel API only honors GPU for kernel_type=notebook (community
# proof Aug 2026; .py scripts are silently downgraded to CPU) — so wrap the .py into an .ipynb.
python3 - "$SRC" "$TMP/kernel.ipynb" <<'PY'
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
nb = {
  "cells": [{"cell_type": "code", "id": "tukuk-job",
             "source": src.splitlines(keepends=True),
             "metadata": {}, "outputs": [], "execution_count": None}],
  "metadata": {"accelerator": "nvidiaTeslaT4",
               "kernelspec": {"display_name": "Python 3", "language": "python",
                               "name": "python3"},
               "language_info": {"name": "python", "version": "3.11"},
               "kaggle": {"accelerator": "nvidiaTeslaT4", "isGpuEnabled": True,
                           "isInternetEnabled": True, "language": "python",
                           "sourceType": "script", "dataSources": []}},
  "nbformat": 4, "nbformat_minor": 5,
}
json.dump(nb, open(sys.argv[2], "w", encoding="utf-8"))
PY
TITLE="tukuk-gpu-burst-${JOB}-$(date +%s)"
SLUG="${KAGGLE_ID}/${TITLE}"
cat > "$TMP/kernel-metadata.json" <<EOF
{
  "id": "${SLUG}",
  "title": "${TITLE}",
  "code_file": "kernel.ipynb",
  "language": "python",
  "kernel_type": "notebook",
  "is_private": true,
  "enable_gpu": true,
  "machine_shape": "NvidiaTeslaT4",
  "enable_internet": true,
  "dataset_sources": [],
  "competition_sources": [],
  "kernel_sources": []
}
EOF

echo "── [1] push kernel '$JOB' (GPU) ──"
( cd "$TMP" && kaggle kernels push --accelerator NvidiaTeslaT4 ) || { echo "✗ push failed — check credit/kaggle.json."; exit 1; }
echo "✓ submitted: $SLUG"

echo "── [2] poll until done (max ${POLL_MAX_MIN} min) ──"
DEADLINE=$(( $(date +%s) + POLL_MAX_MIN * 60 ))
while :; do
  ST="$(kaggle kernels status "$SLUG" 2>/dev/null || echo '?')"
  echo "   $(date +%H:%M:%S) $ST"
  case "$ST" in *COMPLETE*) break;; *FAILED*|*ERROR*) echo "✗ kernel failed — log: kaggle kernels output $SLUG"; exit 1;; esac
  [ "$(date +%s)" -lt "$DEADLINE" ] || { echo "✗ timeout ${POLL_MAX_MIN} min — the kernel may still be queued; check later: kaggle kernels status $SLUG"; exit 1; }
  sleep 30
done

echo "── [3] download output ──"
DEST="$OUT_ROOT/${JOB}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
kaggle kernels output "$SLUG" -p "$DEST" || { echo "✗ download failed."; exit 1; }
echo "✓ output at $DEST:"
ls -la "$DEST" | tail -n +2
echo
echo "Import the trained model (if any): sudo bash scripts/import-trained-model.sh <file-in-DEST>"
