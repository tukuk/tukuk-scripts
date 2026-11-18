#!/usr/bin/env bash
# ==============================================================================
# tukuk.sh — the ONE script: install, update, dev, repair.
#
#   npm install        fresh machine OR update: pulls GitHub first (when the tree is
#                      clean), then installs. The wiring is postinstall →
#                      scripts/pull-before-install.sh → scripts/setup-all.sh.
#   npm start          local dev server + auto-repair supervisor (restarts on crash)
#   npm run update     the box deploy: auto-update.sh, THEN verify /health, and
#                      ROLL BACK to the previous commit if the new code does not answer
#   npm run repair     one-shot self-heal: git sanity, dependency drift, dead services,
#                      unhealthy app, dead timer — everything fixable without hands
#
# Why this exists next to auto-update.sh: the updater was always safe (bounded fetch,
# no prompts, a status record for /health) but it trusted `systemctl restart` exit 0
# as proof of health. A restart of a process that dies 5 seconds later also exits 0.
# `update` here adds the missing second half — probe, and revert if the probe fails —
# so a bad push is a 30-second incident on a LAN box instead of a morning of 503s.
#
# As used by systemd: the timer still runs scripts/auto-update.sh directly (it has no
# one to roll back FOR — the watchdog owns the running process). Run THIS by hand, or
# through npm, when you want the verify+rollback behaviour.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
export GIT_TERMINAL_PROMPT=0   # a credential prompt inside a timer is a silent hang

INSTALL_DIR="/opt/tukuk-os"
HEALTH_URL="${TUKUK_HEALTH_URL:-http://127.0.0.1:3000/health}"
ON_BOX=0; [[ "$(pwd)" == "$INSTALL_DIR" ]] && ON_BOX=1
IS_ROOT=0; [[ "${EUID}" -eq 0 ]] && IS_ROOT=1
SERVICES=(meilisearch tukuk-os nginx cloudflared)
log() { echo "[tukuk.sh] $*"; }
# A root-owned tree (/opt/tukuk-os is installed by sudo) makes plain `git` refuse to
# run as the normal user: "dubious ownership". Declaring the ONE directory this script
# operates on, through the environment, keeps every later git call — reads AND the
# rollback's `reset --hard` — on the honest error path: stderr is never swallowed here,
# because a silenced reset --hard is a rollback that did not happen.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$PWD"
git_c() { git "$@"; }

have_origin() { [[ -n "$(git_c config --get remote.origin.url)" ]]; }

health_ok() { # $1 = max tries; /health answers 200 once per try, 5s apart
  local n=${1:-3} i
  for ((i = 1; i <= n; i++)); do
    if curl -sf -m 10 -o /dev/null "$HEALTH_URL"; then return 0; fi
    sleep 5
  done
  return 1
}

deps_adrift() { # npm's own record vs the lockfile: missing tree, missing record, or newer lock
  [[ ! -d node_modules || ! -f node_modules/.package-lock.json ]] \
    || [[ package-lock.json -nt node_modules/.package-lock.json ]]
}

cmd="${1:-auto}"

case "$cmd" in

# ── install: the fresh-machine path (and a safe re-run on any machine) ────────
install)
  log "install: pulling GitHub (if clean), then npm install ..."
  bash scripts/pull-before-install.sh || log "warning: pull skipped or failed — installing what is here."
  npm install
  RC=$?
  if [[ $RC -ne 0 ]]; then log "npm install failed (exit $RC) — repair may fix the usual causes: npm run repair"; exit $RC; fi
  if [[ $ON_BOX -eq 1 ]]; then
    health_ok 4 || log "warning: installed but /health did not answer — npm run repair, then check journalctl -u tukuk-os"
  fi
  log "install done."
  ;;

# ── update: the deploy. On the box this wraps auto-update.sh + verify + rollback
update)
  if [[ $ON_BOX -eq 1 && $IS_ROOT -eq 1 ]]; then
    OLD="$(git_c rev-parse HEAD)"
    log "update: $OLD → auto-update.sh, then verify ..."
    bash scripts/auto-update.sh
    RC=$?
    NEW="$(git_c rev-parse HEAD)"
    if [[ "$NEW" == "$OLD" || $RC -ne 0 ]]; then exit $RC; fi   # nothing landed; auto-update already reported why
    if health_ok 4; then
      log "update: $(git_c rev-parse --short HEAD) deployed and /health answers 200. Done."
      exit 0
    fi
    log "update: NEW CODE IS UNHEALTHY — rolling back $NEW → $OLD ..."
    git_c reset --hard "$OLD"
    systemctl restart tukuk-os
    if health_ok 4; then
      log "update: rolled back and the old code answers again. The bad commit is still in"
      log "  origin/main — fix forward, do not re-push it as-is."
    else
      log "update: ROLLBACK DID NOT HELP either — this is not the new code's fault."
      log "  Look now: journalctl -u tukuk-os -n 50 ; systemctl status meilisearch"
    fi
    exit 1
  fi
  # Not the box (a laptop checkout, or run as a normal user): pull + install is the update.
  log "update: not on $INSTALL_DIR as root — doing the dev-tree update (git + npm if needed)."
  bash scripts/pull-before-install.sh || true
  # After a fast-forward, HEAD and the tree agree — `git diff` would answer "nothing
  # changed" even when the pull just landed a new lockfile. mtime answers honestly:
  # a lockfile newer than what npm recorded needs an install.
  if deps_adrift; then
    npm install
  fi
  ;;

# ── dev: the local server with an auto-repair supervisor ──────────────────────
dev)
  [[ -d node_modules ]] || { log "dev: first run — installing dependencies ..."; npm install; }
  # Fail-soft preflight: the app boots without Meilisearch (fallback mode), but the
  # developer should SEE that rather than debug a silent downgrade at 2am.
  curl -sf -m 2 http://127.0.0.1:7700/health >/dev/null 2>&1 \
    || log "dev: note: Meilisearch is not up locally — search will run in fallback mode (npm run meili to start it)."
  local_fails=0; last_start=0
  trap 'log "dev: stopping (Ctrl-C)"; [[ -n "${child:-}" ]] && kill "$child" 2>/dev/null; wait; exit 0' INT TERM
  while true; do
    last_start=$(date +%s)
    log "dev: starting node index.js (auto-repair on; Ctrl-C stops) ..."
    node index.js & child=$!
    wait "$child"
    rc=$?
    now=$(date +%s)
    if [[ $((now - last_start)) -lt 10 ]]; then
      local_fails=$((local_fails + 1))
    else
      local_fails=0
    fi
    if [[ $local_fails -ge 3 ]]; then
      log "dev: crashed 3 times within 10s each — that is a bug, not a hiccup. Fix the error above; not restarting again."
      exit 1
    fi
    log "dev: process exited (rc=$rc) — auto-repair restarts in 2s."
    sleep 2
  done
  ;;

# ── repair: one pass over everything a machine usually fixes itself ───────────
repair)
  fixed=0
  # 1. code: fast-forward when possible; never touch a dirty tree (jangan kacau).
  if have_origin; then
    if bash scripts/pull-before-install.sh; then fixed=$((fixed + 1)); fi
  else
    log "repair: no origin remote (bundle/USB install) — skipping git step."
  fi
  # 2. dependencies: install only when node_modules is missing or older than the lock.
  if deps_adrift; then
    log "repair: dependencies missing or adrift → npm install ..."
    if [[ $ON_BOX -eq 1 ]]; then npm install --omit=dev; else npm install; fi
    fixed=$((fixed + 1))
  fi
  # 3-5 need the box + root; a laptop has no units to chase.
  if [[ $ON_BOX -eq 1 && $IS_ROOT -eq 1 ]]; then
    # 3. services
    for s in "${SERVICES[@]}"; do
      if ! systemctl is-active --quiet "$s"; then
        log "repair: $s is down — starting ..."
        systemctl restart "$s" && fixed=$((fixed + 1))
      fi
    done
    # 4. health: one more tukuk-os restart, then say the truth
    if ! health_ok 2; then
      log "repair: /health silent — restarting tukuk-os once more ..."
      systemctl restart tukuk-os
      health_ok 4 && fixed=$((fixed + 1)) || log "repair: STILL UNHEALTHY — journalctl -u tukuk-os -n 50"
    fi
    # 5. the updater itself: a disabled timer means tomorrow's code never arrives
    if ! systemctl is-active --quiet tukuk-update.timer; then
      log "repair: tukuk-update.timer is not active — enabling ..."
      systemctl enable --now tukuk-update.timer && fixed=$((fixed + 1))
    fi
  fi
  log "repair: done ($fixed thing(s) touched). Health: $(curl -sf -m 10 -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo 'no answer')"
  ;;

# ── auto: what a bare `bash scripts/tukuk.sh` means ───────────────────────────
auto)
  if [[ ! -d node_modules ]]; then exec bash "$0" install; else exec bash "$0" update; fi
  ;;

*)
  echo "usage: tukuk.sh [install|update|dev|repair]  (no arg = auto: install if new, else update)"
  exit 2
  ;;
esac
