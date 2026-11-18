#!/usr/bin/env bash
# deploy-builder.sh — send the Tukuk Builder fork (bolt.diy) to the server over the LAN.
#
# USAGE:
#   1) Once on the server: the systemd + env files already live in deploy/.
#   2) On the laptop: node scripts/lint.js, then run this script.
#
# What happens: rsync source (without node_modules/.git/build) to the Builder's
# directory INSIDE the app folder (/opt/tukuk-os/apps/builder, from deploy/paths.sh),
# install dependencies + build ON THE SERVER (node22 is
# already there), then restart tukuk-builder.service. The first pass is slow (the
# pnpm download is ~1-2 GB); after that it is incremental only.
set -euo pipefail

TUKUK_HOST="${TUKUK_HOST:-}"
if [ -z "$TUKUK_HOST" ]; then
  cat >&2 <<'MSG'
✗ TUKUK_HOST is not set.

  There is deliberately NO default: the box takes its address over DHCP and a stale
  hardcoded one (192.168.8.105) is how a deploy "ran" and shipped nothing — rsync
  failed, the script carried on, and the browser kept loading the old bundle.

  Find the box first (it must answer on port 22, not just ping):
    for i in $(seq 1 254); do timeout 1 bash -c "</dev/tcp/192.168.8.$i/22" 2>/dev/null && echo "192.168.8.$i"; done
    TUKUK_HOST=192.168.8.101 bash scripts/deploy-builder.sh
MSG
  exit 1
fi
HOST="${BUILDER_HOST:-tukuk@${TUKUK_HOST}}"
PASS="${1:-${BUILDER_PASS:-1}}"
# shellcheck source=../deploy/paths.sh
. "$(cd "$(dirname "$0")/.." && pwd)/deploy/paths.sh"
DEST="$TUKUK_BUILDER_DIR"
SRC="$(cd "$(dirname "$0")/.." && pwd)/bolt.diy"

# Reachability gate: ping proves the host is up, not that sshd is listening. The 2026-10-29
# run pinged fine and every inbound port was closed (the box is reachable only outbound via
# the Cloudflare Tunnel), so refuse now instead of after a half-finished rsync.
if ! timeout 8 bash -c "</dev/tcp/${TUKUK_HOST}/22" 2>/dev/null; then
  echo "✗ ${TUKUK_HOST}:22 does not accept connections — sshd is down, firewalled, or that is not the box."
  echo "  ping answering is not enough. Nothing was changed. Check: systemctl status ssh on the box."
  exit 1
fi

ssh_run() { sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$HOST" "echo $PASS | sudo -S $1"; }

echo "[builder] rsync source → $DEST"
# `P` = protect from THIS command's --delete, without excluding it from the transfer:
# .env.production holds the Builder's TUKUK_API_KEY and is written on the server, so a
# deploy must not delete it just because the laptop's checkout does not carry it.
# NOTE: sudo -S ONLY applies to the first command — an && chain must be wrapped in sh -c.
ssh_run "sh -c 'mkdir -p $DEST && chown -R tukuk:tukuk $DEST'" || true
rsync -a --delete -e "sshpass -p $PASS ssh -o StrictHostKeyChecking=no" \
  --exclude .git --exclude node_modules --exclude build --exclude dist \
  --exclude .env.local \
  --filter='P .env.production' \
  --exclude benchmarks --exclude e2e-tests --exclude playwright-report \
  "$SRC/" "$HOST:$DEST/"

echo "[builder] install pnpm (once) + install + build on the server"
# All via sh -c: sudo -S only applies to the first command, and
# the `command`/`cd` builtins cannot be piped straight into sudo.
ssh_run "sh -c 'corepack disable >/dev/null 2>&1 || true; command -v pnpm >/dev/null || npm i -g pnpm@9.15.9 --silent; pnpm -v'"
ssh_run "sh -c 'cd $DEST && pnpm install --frozen-lockfile --prefer-offline 2>&1 | tail -3'"
ssh_run "sh -c 'cd $DEST && pnpm build 2>&1 | tail -5'"

echo "[builder] ship the wake-on-request front door (lives in the main repo, not the fork)"
# builder-wakekeeper.js + its unit own port 5174 (what cloudflared reaches) and forward to the
# builder here on 5176. They are part of THIS repo's deploy/, so copy them to the server's
# /opt/tukuk-os/deploy rather than relying on the main-repo checkout being up to date.
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)/deploy"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$DEPLOY_DIR/builder-wakekeeper.js" "$DEPLOY_DIR/tukuk-builder-wake.service" "$HOST:/tmp/" || true
ssh_run "sh -c 'mv /tmp/builder-wakekeeper.js /tmp/tukuk-builder-wake.service /opt/tukuk-os/deploy/ && chmod +x /opt/tukuk-os/deploy/builder-wakekeeper.js'" || true

echo "[builder] install systemd units + restart"
ssh_run "sh -c 'cp /opt/tukuk-os/deploy/tukuk-builder.service /opt/tukuk-os/deploy/tukuk-builder-wake.service /etc/systemd/system/ && systemctl daemon-reload'"
ssh_run "systemctl enable tukuk-builder tukuk-builder-wake >/dev/null 2>&1 || true"
ssh_run "systemctl restart tukuk-builder-wake"   # front door first, so 5174 is never briefly empty
ssh_run "systemctl restart tukuk-builder"
sleep 3
# builder origin (5176) must answer directly; the front door (5174) must proxy it end to end.
ssh_run "systemctl is-active tukuk-builder && curl -s -o /dev/null -w 'builder:5176 http=%{http_code}\n' http://127.0.0.1:5176/"
ssh_run "curl -s -o /dev/null -w 'frontdoor:5174 http=%{http_code}\n' -H 'Host: build.tukuk.org' http://127.0.0.1:5174/"
echo "[builder] done. https://build.tukuk.org is the ONLY builder origin (one tunnel, one route). dashboard.tukuk.org is retired — do not route the builder there again: that host's /api and /admin belong to Tukuk-OS. Do not drop allowedHosts .tukuk.org in vite.config.ts."

# Verify from the OUTSIDE, which is the only place the user's crash is visible. Every check
# above ran on the box and several end in `|| true`, so a green "done" is not evidence.
echo
echo "[builder] verifying the PUBLIC origin (scripts/verify-builder-fix.sh)"
if bash scripts/verify-builder-fix.sh; then
  echo "[builder] public verification PASSED."
else
  echo "[builder] ⚠ the box restarted but the public origin does not show the fix — see above."
  echo "[builder]   Most likely the Cloudflare edge is still serving the old asset, or the"
  echo "[builder]   alias host is not reaching this unit. Do not report this deploy as done."
  exit 1
fi
