#!/usr/bin/env bash
# ==============================================================================
# pull-before-install.sh — makes plain `npm install` also mean "update".
#
# Runs first in the postinstall chain (before setup-all.sh), and fast-forwards this
# checkout onto origin so the dependencies and the reconciler both work on the NEW
# code. The owner asked for one command for install AND update; this is the piece
# that makes the same command do both.
#
# Refuses, politely (exit 0 — an update that cannot happen must not break an install):
#   * CI runners (GitHub Actions, Cloudflare builds): a runner installs what it CHECKED
#     OUT. Pulling a different commit into the build is exactly the surprise that makes
#     a CI green and production red at the same time.
#   * no origin remote (bundle/USB installs — a supported shape)
#   * a dirty tree: someone is working here; never merge over uncommitted work
#   * diverged history: `git merge --ff-only` says no, and we agree with it
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
export GIT_TERMINAL_PROMPT=0

[[ -n "${GITHUB_ACTIONS:-}${CF_PAGES:-}${CONTINUOUS_INTEGRATION:-}" || "${CI:-}" == "true" ]] && exit 0
[[ -n "${TUKUK_AUTO_UPDATE_RUNNING:-}" ]] && exit 0   # auto-update.sh already pulled; do not pull twice

# Root-owned tree on the box, run as a normal user, or the reverse — declare the one
# directory we are operating on rather than disabling the check globally.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$PWD"

if [[ -z "$(git config --get remote.origin.url 2>/dev/null)" ]]; then
  echo "[pull] no origin remote — nothing to update from (a bundle/USB install looks like this)."
  exit 0
fi
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "[pull] working tree has uncommitted changes — NOT pulling (jangan kacau)."
  echo "[pull]   commit or stash them, or let scripts/auto-update.sh run as root on the box."
  exit 0
fi

BRANCH="$(grep -E '^GIT_BRANCH=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
BRANCH="${BRANCH:-main}"
OLD="$(git rev-parse HEAD)"
timeout 120 git fetch origin "$BRANCH" || { echo "[pull] fetch failed or timed out — installing what is here."; exit 0; }
git merge --ff-only "origin/$BRANCH" >/dev/null || { echo "[pull] not fast-forwardable — installing what is here."; exit 0; }
NEW="$(git rev-parse HEAD)"
[[ "$OLD" == "$NEW" ]] && exit 0

echo "[pull] updated $(git rev-parse --short "$OLD") → $(git rev-parse --short "$NEW")."
# npm resolved dependencies from the OLD lock before this ran. When the pull changed
# dependencies, install them now — exactly one re-entry, guarded so it can never loop.
if ! git diff --quiet "$OLD" "$NEW" -- package.json package-lock.json; then
  if [[ -z "${TUKUK_PULLED_REINSTALL:-}" ]]; then
    echo "[pull] dependencies changed → running npm install once more for the new lockfile ..."
    TUKUK_PULLED_REINSTALL=1 npm install --no-audit --no-fund
  fi
fi
exit 0
