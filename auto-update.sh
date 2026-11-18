#!/usr/bin/env bash
# ==============================================================================
# auto-update.sh — FULL one-line update: git → (npm) → restart service.
#
#   npm run update            (manual, on the server; needs root)
#   tukuk-update.timer        (every 30 min, automatic — installed by setup-all.sh)
#
# SMART chain (avoids load + hangs on a slow VPS):
#   git fetch + merge --ff-only → if there are NO new commits: exit immediately.
#   if there are: run `npm install` ONLY when package.json/package-lock changed
#   (satu-kata/code/README don't touch dependencies → skip the heavy native download
#   like onnxruntime that can hang), then `systemctl restart
#   tukuk-os` so the new code is loaded. The systemd unit & tunnel are already
#   installed by setup-all.sh, so there's no need for the full postinstall chain daily.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
SECONDS=0
# Nobody is at the keyboard inside a timer. A credential prompt is a hang with no
# output, which is the exact shape of the 31-hour wedge of 24 Oct 2026.
export GIT_TERMINAL_PROMPT=0
# npm install below runs postinstall → pull-before-install.sh. This pull already
# happened; a second one mid-deploy would move the box between the install and the
# restart, which is exactly the "installed one commit, running another" confusion.
export TUKUK_AUTO_UPDATE_RUNNING=1

# Record this attempt where /health can read it (src/update-status.js). Fixed fields
# only — the stage, the result, the two commits, the duration — because /health is
# public and stderr is where paths and hostnames leak.
write_status() { # $1 ok(1/0)  $2 stage  $3 from  $4 to
  node -e '
    const fs = require("fs");
    const [ok, stage, from, to, secs] = process.argv.slice(1);
    fs.mkdirSync("data", { recursive: true });
    fs.writeFileSync("data/update-status.json", JSON.stringify({
      at: new Date().toISOString(), ok: ok === "1", stage,
      from: from || null, to: to || null, seconds: Number(secs) || 0,
    }));
  ' "$1" "$2" "${3:-}" "${4:-}" "$SECONDS" 2>/dev/null \
    || echo "[auto-update] warning: could not write data/update-status.json"
}

INSTALL_DIR="/opt/tukuk-os"
if [[ "$(pwd)" != "$INSTALL_DIR" ]]; then
  echo "[auto-update] only designed to run in $INSTALL_DIR (currently in $(pwd)) — skip."
  exit 0
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "[auto-update] needs root:  sudo bash scripts/auto-update.sh"
  exit 1
fi

BRANCH="$(grep -E '^GIT_BRANCH=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
BRANCH="${BRANCH:-main}"

# The second server (www.tukuk.org on Cloudflare Pages): refresh the static
# mirror at most once an hour, on EVERY cycle — "no new commits" is exactly when
# the mirror still wants the freshest cached pages. Soft by design: no token,
# no python3, a flaky page — the mirror keeps serving its previous snapshot and
# the update itself must never fail because of it.
mirror_refresh() {
  [[ -f scripts/mirror-export.sh && -f scripts/mirror-deploy.sh ]] || return 0
  if [[ -f /tmp/tukuk-mirror.stamp && -n "$(find /tmp/tukuk-mirror.stamp -mmin -60 2>/dev/null)" ]]; then
    return 0   # refreshed within the hour — every other cycle can skip
  fi
  ( set -a; . ./.env 2>/dev/null; set +a
    [[ -n "${MIRROR_API_TOKEN:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || exit 0
    bash scripts/mirror-export.sh && bash scripts/mirror-deploy.sh ) \
    >/tmp/mirror.log 2>&1 \
    && date -Is >/tmp/tukuk-mirror.stamp \
    || echo "[auto-update] mirror refresh skipped/failed this cycle (see /tmp/mirror.log)"
}

# Our own AI model (Tukuk-Brain Mini): retrain from the latest
# production logs. SOFT failure — taskrouter stays regex-only if there is no file.
# Once a day is enough: the timer now fires every 30 minutes, and 48 retrains a day
# is server work nobody asked for. The marker lives in the same place as the log.
train_brain() {
  # No `find | grep -q`: pipefail turns the matched case into a 141 (see watchdog.sh's
  # note on the same trap) — command substitution over find's own output is the honest test.
  if [[ -f /tmp/train-brain.log && -n "$(find /tmp/train-brain.log -mmin -1440 2>/dev/null)" ]]; then
    return 0   # trained within the last 24h — the logs can wait for tomorrow
  fi
  if timeout 300 node scripts/train-brain.js >/tmp/train-brain.log 2>&1; then
    grep -E 'external probes|saved' /tmp/train-brain.log | sed 's/^/[auto-update] /'
  else
    echo "[auto-update] warning: train-brain failed — continuing with old/regex-only model."
  fi
}

echo "[auto-update] $(date -Is) — pulling origin/$BRANCH ..."
# A box installed from a bundle, or from `install-from-usb.sh` (which rsyncs with
# --exclude .git), has no remote at all. That is a supported shape, not a fault — but
# without this check it reports "git fetch failed", which sends the reader looking at the
# network for a problem that is a missing `git remote add`. Say which it is.
if [[ -z "$(git config --get remote.origin.url 2>/dev/null || true)" ]]; then
  echo "[auto-update] this box has no origin remote — nothing to pull from (a bundle or USB"
  echo "               install looks like this). To enable automatic updates:"
  echo "                 git -C $INSTALL_DIR remote add origin <repo-url>"
  write_status 1 no-remote "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  exit 0
fi
OLD="$(git rev-parse HEAD)"
# The attempt is recorded BEFORE the network is touched: if this process is killed or
# wedged, /health still shows a fetch that started at :07 and never finished, instead
# of yesterday's cheerful "done".
write_status 0 fetch "$OLD" "$OLD"
# Ten minutes is generous for a repo this size; unbounded is how a dead connection
# holds the unit open until the next boot.
timeout 600 git fetch origin "$BRANCH"
FETCH_RC=$?
if [[ "$FETCH_RC" -ne 0 ]]; then
  echo "[auto-update] git fetch failed or timed out (exit $FETCH_RC) — skip this cycle."
  write_status 0 fetch-failed "$OLD" "$OLD"
  exit 0
fi
if ! git merge --ff-only "origin/$BRANCH"; then
  echo "[auto-update] working tree changed/diverged — no auto-merge for safety. Check: git status"
  write_status 0 merge-failed "$OLD" "$OLD"
  exit 0
fi
NEW="$(git rev-parse HEAD)"

if [[ "$OLD" == "$NEW" ]]; then
  echo "[auto-update] no new update (at $OLD) — skip npm & restart."
  # Still TRAIN the brain model — production logs (ask/search) grow more today.
  train_brain
  mirror_refresh
  write_status 1 no-change "$OLD" "$NEW"
  exit 0
fi
echo "[auto-update] update $OLD → $NEW."

# ── the ONE folder ────────────────────────────────────────────────────────────
# The repo names /opt/tukuk-os/apps/builder, apps/play, models/, bin/ and game/
# (deploy/paths.sh). A box built before that change still has those files in the old
# top-level places, so the paths the unit, nginx and src/config.js expect would not
# exist on the very deploy that introduces them — a Builder unit that fails to CHDIR
# and a play origin that answers 404. consolidate-layout.sh moves them into the folder
# and leaves the old paths as symlinks, which is also why a failure here must NOT abort:
# the symlinks mean the old names still resolve, so the box keeps serving while it is
# fixed. It runs before the restart for exactly that reason.
if [[ -f scripts/consolidate-layout.sh ]]; then
  bash scripts/consolidate-layout.sh \
    || echo "[auto-update] warning: layout consolidation reported problems (above) — old paths still symlinked, box still serving."
fi

# Only reinstall when dependencies truly changed. This avoids `npm install`
# daily re-fetching the heavy native binary (onnxruntime ~300MB) that can HANG
# on a slow network, and avoids needless reloads.
if git diff --quiet "$OLD" "$NEW" -- package.json package-lock.json; then
  echo "[auto-update] package.json/lock unchanged — skip npm install."
else
  echo "[auto-update] dependencies changed → npm install --omit=dev ..."
  timeout 900 npm install --omit=dev
  NPM_RC=$?
  [[ "$NPM_RC" -eq 0 ]] || echo "[auto-update] WARNING: npm install exited $NPM_RC — continuing to restart."
fi

# setup-all.sh is not only the installer — it is the reconciler that WRITES the systemd
# units and timers. Without npm install (lock unchanged) a committed timer/unit change
# would sit in git forever: the box keeps running the unit it was built with. So when
# THIS run touched setup-all.sh, re-run it. It is idempotent by contract, and the
# --from-npm flag keeps the safety gate exactly where postinstall keeps it.
if ! git diff --quiet "$OLD" "$NEW" -- scripts/setup-all.sh && [[ -f scripts/setup-all.sh ]]; then
  echo "[auto-update] setup-all.sh changed → re-running it to reconcile units/timers ..."
  bash scripts/setup-all.sh --from-npm \
    || echo "[auto-update] warning: setup-all reconcile failed (exit $?) — units stay as they were; run: sudo bash scripts/setup-all.sh"
fi

# Source code may have changed → restart so the process loads new logic (Express
# routes in memory, static mounts, blog index). The unit/tunnel already exist.
# Train the model FIRST — the first restart brings the brain + latest model file.
train_brain
write_status 0 restart "$OLD" "$NEW"
echo "[auto-update] restart tukuk-os ..."
timeout 120 systemctl restart tukuk-os
RESTART_RC=$?
if [[ "$RESTART_RC" -ne 0 ]]; then
  echo "[auto-update] restart FAILED (exit $RESTART_RC) — the old process is still running the old code."
  write_status 0 restart-failed "$OLD" "$NEW"
  exit 1
fi

write_status 1 done "$OLD" "$NEW"
# Fresh code is live — the mirror should show it, not last week's markup.
mirror_refresh
echo "[auto-update] $(date -Is) — done in ${SECONDS}s. Tukuk-OS is now on commit: $(git rev-parse --short HEAD)"
