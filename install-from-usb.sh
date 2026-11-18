#!/usr/bin/env bash
# ==============================================================================
# install-from-usb.sh — install Tukuk-OS from a USB copy to /opt/tukuk-os.
#
# WHY: the repo is now PRIVATE (tukuk/tukuk-os). Cloning from GitHub on a
# new machine needs an SSH key/PAT — a hassle. The USB carries the code directly,
# so NO auth is needed. The server only needs INTERNET for `npm install` (Node deps).
#
# HOW (on the SERVER, after the USB is plugged in & auto-mounted, usually /media/<user>/...):
#   # copy the repo folder from the USB anywhere, e.g.:
#   cp -r /media/$USER/USB/tukuk-os /tmp/tukuk-os
#   sudo bash /tmp/tukuk-os/scripts/install-from-usb.sh
#
# OR run it straight from the USB (if the USB is mounted & the script is executable):
#   sudo bash /media/$USER/USB/tukuk-os/scripts/install-from-usb.sh
#
# OPTIONS (env):
#   TUKUK_INSTALL_DIR=/opt/tukuk-os   install location (default /opt/tukuk-os)
#   TUKUK_KEEP_NODEMODULES=1          include node_modules from the USB (offline-ish)
#   TUKUK_OFFLINE=1                   skip apt/npm (needs node_modules + binaries
#                                     already on the USB; see README §5 note)
#
# After finishing: fill CF_TUNNEL_TOKEN (and CLOUDFLARE_API_TOKEN for www/edge)
# in /opt/tukuk-os/.env, then run `sudo bash scripts/setup-all.sh`
# again (idempotent) to bring up the tunnel & edge.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${BLUE}➜ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# Repo directory = this script's parent (i.e. the copy on the USB / tmp).
SRC="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${TUKUK_INSTALL_DIR:-/opt/tukuk-os}"
KEEP_NM="${TUKUK_KEEP_NODEMODULES:-0}"
OFFLINE="${TUKUK_OFFLINE:-0}"

[[ -f "$SRC/package.json" && -d "$SRC/src" ]] || die "Not a Tukuk-OS repo folder: $SRC (no package.json/src)."

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || die "Need root (use sudo)."
  exec sudo env "TUKUK_INSTALL_DIR=$INSTALL_DIR" "TUKUK_KEEP_NODEMODULES=$KEEP_NM" "TUKUK_OFFLINE=$OFFLINE" "PATH=$PATH" bash "$0"
fi

command -v rsync >/dev/null || { info "Installing rsync..."; apt-get update -y -qq && apt-get install -y -qq rsync >/dev/null; }

echo -e "${BLUE}========================================================${NC}"
echo -e "${GREEN}  Tukuk-OS — Install from USB${NC}"
echo -e "${BLUE}  Source : $SRC${NC}"
echo -e "${BLUE}  Target : $INSTALL_DIR${NC}"
echo -e "${BLUE}========================================================${NC}"

# ── 1. Copy code to /opt/tukuk-os ────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
if [[ "$SRC" == "$INSTALL_DIR" ]]; then
  info "Source already = target; skip copy."
else
  info "[1/3] Copying files to $INSTALL_DIR ..."
  # Excludes: runtime secrets & large regenerable artifacts.
  EX=(--exclude .git --exclude meili_data --exclude .wrangler --exclude snapshots --exclude dumps --exclude .env)
  [[ "$KEEP_NM" == "1" || "$OFFLINE" == "1" ]] || EX+=(--exclude node_modules)
  rsync -a "${EX[@]}" "$SRC/" "$INSTALL_DIR/"
  ok "Code copied."
fi

cd "$INSTALL_DIR"

# ── 2. .env: merge the public half with the private half ────────────────────
# The USB stick IS the out-of-band channel, so this is the install path where a
# missing deploy/env.secrets is a hard stop rather than a warning: without it the
# tunnel token is nowhere on the box and tukuk.org stays down no matter what the rest
# of the install does. The rsync above excludes .git, node_modules, .env and the
# regenerable data dirs — but never deploy/env.secrets, so the file arrives with the
# tree. Its absence therefore means it was never on the stick.
if [[ ! -f .env ]]; then
  if [[ -f deploy/env.secrets ]]; then
    bash scripts/make-env.sh || die "make-env.sh failed — see its message above."
    ok ".env generated from deploy/env.defaults + deploy/env.secrets."
  else
    die "No deploy/env.secrets on this stick. The tunnel token, the Cloudflare API token, the admin credential and the agent token are not in git any more (they never should have been). Copy deploy/env.secrets onto the stick and re-run."
  fi
fi

# ── 3. Full setup (Node, Meili, services, tunnel, edge) ───────────────────────
if [[ "$OFFLINE" == "1" ]]; then
  warn "OFFLINE MODE: setup-all.sh will TRY apt/npm (may fail without internet)."
  warn "For true offline: make sure node_modules + binaries (node/cloudflared/meilisearch)"
  warn "are already on the USB, and enable the systemd services manually."
fi

info "[2/3] Running setup-all.sh (idempotent) ..."
TUKUK_AUTO_SETUP=1 bash scripts/setup-all.sh

# ── 4. Verification & wrap-up ───────────────────────────────────────────────────
info "[3/3] Verifying ..."
sleep 2
if [[ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/health 2>/dev/null)" == "200" ]]; then
  ok "Search engine up at http://127.0.0.1:3000"
else
  warn "Not responding yet — check: journalctl -u tukuk-os -n 30"
fi

TOKEN="$(grep -E '^CF_TUNNEL_TOKEN=' .env | head -1 | cut -d= -f2- || true)"
if [[ -z "$TOKEN" ]]; then
  echo
  warn "Last step: bring up the domain. The tunnel token is NOT in git — put it in the"
  warn "private half and let make-env.sh rebuild .env:"
  echo "   1. Cloudflare Zero Trust → Tunnels → copy the token into deploy/env.secrets as"
  echo "        CF_TUNNEL_TOKEN=eyJ...      (+ CLOUDFLARE_API_TOKEN=... for www.tukuk.org / edge snapshot)"
  echo "   2. sudo bash scripts/make-env.sh --force"
  echo "   3. sudo bash scripts/setup-all.sh     # only the tunnel/edge steps are repeated"
fi

echo -e "${BLUE}========================================================${NC}"
echo -e "${GREEN}  DONE. Admin: http://127.0.0.1:3000/admin (email + passkey).${NC}"
echo -e "  Log: journalctl -u tukuk-os -f     Manual update: npm run update"
echo -e "${BLUE}========================================================${NC}"
