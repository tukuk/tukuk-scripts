#!/usr/bin/env bash
# ==============================================================================
# arc-2026-push.sh — embed the ARC solver into the Kaggle notebook and run it.
#
#   bash scripts/arc-2026-push.sh --dry-run          # build + verify, do not submit
#   bash scripts/arc-2026-push.sh                    # push a PRIVATE run
#   bash scripts/arc-2026-push.sh --public           # the submission notebook
#   ARC_COMPETITION=arc-prize-2026 bash scripts/arc-2026-push.sh
#
# WHY a generator instead of a self-contained notebook: the notebook is the code
# submission the paper links to, so it must run exactly the solver that produced
# the numbers in arc-2026/results/. Copy-pasting the modules by hand is how a
# paper ends up describing code that is no longer in the repo. This script reads
# arc-2026/arc/*.py, embeds them verbatim into
# kaggle-jobs/arc-2026-solver.generated.py (gitignored), byte-compiles that file,
# and only then submits it.
#
# PREREQUISITES (browser, one time — the CLI cannot accept rules on your behalf):
#   1. kaggle auth login   (or ~/.kaggle/kaggle.json)
#   2. Join the competition and accept its rules, otherwise attaching it fails.
#   3. For the Paper Track submission the notebook must be PUBLIC and joined to
#      a real ARC-AGI-2 / ARC-AGI-3 competition — hence --public and ARC_COMPETITION.
#
# The solver is pure CPU (no GPU quota is touched, no account gate applies).
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

JOB="arc-2026-solver"
SRC="kaggle-jobs/${JOB}.py"
GEN="kaggle-jobs/${JOB}.generated.py"
MODULE_DIR="arc-2026/arc"
COMPETITION="${ARC_COMPETITION:-}"
POLL_MAX_MIN="${POLL_MAX_MIN:-60}"
PRIVATE=1
PUSH=1

for arg in "$@"; do
  case "$arg" in
    --public) PRIVATE=0 ;;
    --dry-run) PUSH=0 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "✗ unknown argument: $arg (accepted: --public, --dry-run)"; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "✗ python3 is required"; exit 1; }
[ -f "$SRC" ] || { echo "✗ ${SRC} is missing"; exit 1; }

mapfile -t MODULES < <(ls "$MODULE_DIR"/*.py 2>/dev/null)
[ "${#MODULES[@]}" -ge 5 ] || { echo "✗ ${MODULE_DIR}/*.py not found — expected grid, dsl, learn, search, solver, evaluate"; exit 1; }

# ── [1] embed: arc-2026/arc/*.py → SOLVER_SOURCES in the generated notebook ────
echo "── [1/4] embedding ${#MODULES[@]} module(s) from ${MODULE_DIR} ──"
python3 - "$SRC" "$GEN" "$MODULE_DIR" <<'PY'
import json
import os
import sys

src_path, gen_path, module_dir = sys.argv[1:4]
template = open(src_path, encoding="utf-8").read()

sources = {}
for name in sorted(os.listdir(module_dir)):
    if not name.endswith(".py"):
        continue
    # Keys are the paths the notebook writes out: root/arc/<name>.py, so that
    # `from arc.grid import ...` resolves after sys.path.insert(0, root).
    sources["arc/" + name] = open(os.path.join(module_dir, name), encoding="utf-8").read()

begin = "# === BEGIN EMBEDDED SOLVER (generated) ==="
end = "# === END EMBEDDED SOLVER ==="
if begin not in template or end not in template:
    raise SystemExit("✗ the BEGIN/END EMBEDDED SOLVER markers are missing from " + src_path)
if "SOLVER_SOURCES = {}" not in template:
    raise SystemExit("✗ expected an empty `SOLVER_SOURCES = {}` stub in " + src_path)

head, rest = template.split(begin, 1)
_, tail = rest.split(end, 1)

# json.dumps of a str→str map is also a valid Python dict literal (no true/false/null
# can appear), so no hand-rolled quoting is needed. ensure_ascii keeps the file safe
# for any editor that reloads it.
payload = json.dumps(sources, ensure_ascii=True, indent=0, sort_keys=True)
block = "%s\nSOLVER_SOURCES = %s\n%s" % (begin, payload, end)

# Knobs travel as env defaults inside the notebook: os.environ is empty on Kaggle,
# so the caller's ARC_LIMIT/ARC_BUDGET/ARC_ATTEMPTS are baked in right before the
# constants are read.
knobs = []
for var in ("ARC_LIMIT", "ARC_BUDGET", "ARC_ATTEMPTS"):
    value = os.environ.get(var)
    if value:
        knobs.append('os.environ.setdefault(%s, %s)' % (json.dumps(var), json.dumps(value)))
knob_block = "\n" + "\n".join(knobs) + "\n" if knobs else ""

generated = head + block + knob_block + tail
open(gen_path, "w", encoding="utf-8").write(generated)
print("   %s  (%d modules, %d bytes)" % (gen_path, len(sources),
                                         len(generated.encode("utf-8"))))
PY
[ $? -eq 0 ] || { echo "✗ embedding failed"; exit 1; }

# ── [2] verify: the generated notebook must compile AND carry every module ─────
echo "── [2/4] verifying the generated notebook ──"
python3 -m py_compile "$GEN" || { echo "✗ ${GEN} does not compile — refusing to submit"; exit 1; }
python3 - "$GEN" "$MODULE_DIR" <<'PY' || exit 1
import importlib.util
import os
import sys

gen_path, module_dir = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("_arc_gen", gen_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

expected = sorted("arc/" + n for n in os.listdir(module_dir) if n.endswith(".py"))
missing = [k for k in expected if k not in mod.SOLVER_SOURCES]
extra = [k for k in mod.SOLVER_SOURCES if k not in expected]
if missing or extra:
    raise SystemExit("✗ embedded set mismatch — missing %s · unexpected %s" % (missing, extra))
if not mod.SOLVER_SOURCES.get("arc/grid.py", "").strip():
    raise SystemExit("✗ arc/grid.py embedded empty")
print("   ok: %d module(s) embedded: %s" % (len(expected), ", ".join(expected)))
PY
[ $? -eq 0 ] || { echo "✗ verification failed"; exit 1; }

if [ "$PUSH" = 0 ]; then
  echo
  echo "✓ dry run — nothing was submitted. The notebook to push is ${GEN}"
  exit 0
fi

# ── [3] submit as a Kaggle kernel ─────────────────────────────────────────────
KAGGLE_ID="${KAGGLE_ID:-}"
case "$KAGGLE_ID" in
  ""|*REPLACE*) echo "✗ export KAGGLE_ID=<your kaggle username> first (example: KAGGLE_ID=tukuk)"; exit 1 ;;
esac
command -v kaggle >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
command -v kaggle >/dev/null 2>&1 || { echo "✗ kaggle CLI missing: uv tool install kaggle (or pipx install kaggle)"; exit 1; }
{ [ -f "$HOME/.kaggle/kaggle.json" ] || [ -f "$HOME/.kaggle/credentials.json" ]; } \
  || { echo "✗ no ~/.kaggle credentials — run: kaggle auth login"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 - "$GEN" "$TMP/kernel.ipynb" <<'PY'
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
nb = {
  "cells": [{"cell_type": "code", "id": "tukuk-arc",
             "source": src.splitlines(keepends=True),
             "metadata": {}, "outputs": [], "execution_count": None}],
  "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python",
                               "name": "python3"},
               "language_info": {"name": "python", "version": "3.11"},
               "kaggle": {"accelerator": "none", "isGpuEnabled": False,
                           "isInternetEnabled": True, "language": "python",
                           "sourceType": "script", "dataSources": []}},
  "nbformat": 4, "nbformat_minor": 5,
}
json.dump(nb, open(sys.argv[2], "w", encoding="utf-8"))
PY

TITLE="tukuk-arc-2026-$(date +%s)"
SLUG="${KAGGLE_ID}/${TITLE}"
PRIVATE_JSON=$([ "$PRIVATE" = 1 ] && echo true || echo false)
COMP_JSON="[]"
[ -n "$COMPETITION" ] && COMP_JSON="[\"${COMPETITION}\"]"

cat > "$TMP/kernel-metadata.json" <<EOF
{
  "id": "${SLUG}",
  "title": "${TITLE}",
  "code_file": "kernel.ipynb",
  "language": "python",
  "kernel_type": "notebook",
  "is_private": ${PRIVATE_JSON},
  "enable_gpu": false,
  "enable_internet": true,
  "dataset_sources": [],
  "competition_sources": ${COMP_JSON},
  "kernel_sources": []
}
EOF

echo "── [3/4] pushing ${SLUG} (private=${PRIVATE_JSON}, competition=${COMPETITION:-none}) ──"
if [ "$PRIVATE" = 0 ]; then
  echo "   NOTE: --public makes this notebook VISIBLE TO EVERYONE. That is what the"
  echo "   Paper Track requires; make sure the write-up is ready before you push."
fi
( cd "$TMP" && kaggle kernels push ) || { echo "✗ push failed — check credit/kaggle.json and competition rules."; exit 1; }
echo "✓ submitted: https://www.kaggle.com/code/${SLUG}"

# ── [4] poll + download ───────────────────────────────────────────────────────
echo "── [4/4] polling (max ${POLL_MAX_MIN} min) ──"
DEADLINE=$(( $(date +%s) + POLL_MAX_MIN * 60 ))
while :; do
  ST="$(kaggle kernels status "$SLUG" 2>/dev/null || echo '?')"
  echo "   $(date +%H:%M:%S) $ST"
  case "$ST" in
    *COMPLETE*) break ;;
    *FAILED*|*ERROR*|*CANCELLED*) echo "✗ kernel did not complete — log: kaggle kernels output $SLUG -p /tmp/arclog"; exit 1 ;;
  esac
  [ "$(date +%s)" -lt "$DEADLINE" ] || {
    echo "✗ timeout after ${POLL_MAX_MIN} min — the kernel may still be queued."
    echo "  Check later: kaggle kernels status $SLUG"
    exit 1
  }
  sleep 30
done

DEST="arc-2026/results/kaggle-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
kaggle kernels output "$SLUG" -p "$DEST" || { echo "✗ output download failed"; exit 1; }
echo "✓ output at ${DEST}:"
ls -la "$DEST" | tail -n +2

cat <<EOF

Next:
  # measured accuracy from this run (if the evaluation split was attached)
  python3 -c "import json,sys;d=json.load(open('${DEST}/eval_metrics.json'));print(d)" 2>/dev/null \\
    || echo "  (no eval_metrics.json — solutions were not mounted, which is normal)"

  # put the numbers into the write-up (never type them by hand)
  \$EDITOR arc-2026/paper/writeup.md
EOF
