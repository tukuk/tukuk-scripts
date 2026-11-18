#!/usr/bin/env bash
# ==============================================================================
# build-agent-on-server.sh — Build the Tukuk Agent release DIRECTLY on the server.
#
# The default path is to build on the laptop (build-tukuk-agent.sh) so the VPS stays
# light. But if the laptop lacks RAM/dependencies (kerberos needs libkrb5-dev,
# gulp needs ~4GB), a server with 6.8GB+ can be a more comfortable build home —
# as long as Ollama is stopped temporarily during compilation (the cloud tier
# still answers /ask) and there is ≥8GB of disk space.
#
#   sudo bash scripts/build-agent-on-server.sh            # build + install service
#   sudo bash scripts/build-agent-on-server.sh --keep-ollama
#
# What it does:
#   [1] Preflight: disk, RAM, sudo.
#   [2] apt: development packages (build-essential, python3, libkrb5-dev,
#       libxkbfile-dev, libsecret-1-dev, unzip).
#   [3] Node 24 via nvm (if not already present).
#   [4] Clone the tukuk-agent-editor fork → /opt/tukuk-os/code-server (gitignored)
#       + the lib/vscode submodule (~350MB).
#   [5] Stop ollama (unless --keep-ollama), run build-tukuk-agent.sh,
#       restart ollama.
#   [6] Install the release LOCALLY (no rsync/ssh): /opt/tukuk-agent/release
#       + user + systemd unit + start — the final notes match
#       publish-agent.sh.
# ==============================================================================
set -uo pipefail

INSTALL_DIR=/opt/tukuk-os
FORK_URL="https://github.com/tukuk/tukuk-agent-editor.git"
KEEP_OLLAMA=0
[ "${1:-}" = "--keep-ollama" ] && KEEP_OLLAMA=1

info() { echo -e "\033[1;36m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }
die()  { echo -e "\033[1;31m✗ $*\033[0m"; exit 1; }

[ "$(id -u)" = 0 ] || die "need root: sudo bash $0"
cd "$INSTALL_DIR" 2>/dev/null || die "$INSTALL_DIR missing — this is a Tukuk-OS server script."

# ── [1] Preflight ─────────────────────────────────────────────────────────────
AVAIL_GB=$(df -BG --output=avail "$INSTALL_DIR" | tail -1 | tr -dc '0-9')
[ "${AVAIL_GB:-0}" -ge 8 ] || die "only ${AVAIL_GB}GB disk left — the VS Code build needs ≥8GB (node_modules + out + release)."
RAM_MB=$(free -m | awk '/Mem:/{print $2}')
info "Preflight OK: ${AVAIL_GB}GB free disk, ${RAM_MB}MB RAM."

# ── [2] Development packages (incl. libkrb5-dev — the cause of laptop failures) ─
info "[2] apt development packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates build-essential python3 pkg-config jq \
  libkrb5-dev libxkbfile-dev libsecret-1-dev zip unzip rsync >/dev/null 2>&1 \
  || warn "some packages failed — continuing, but node-gyp may repeat the same error."

# ── [3] Node 24 ───────────────────────────────────────────────────────────────
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" != "24" ]; then
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    info "[3] installing nvm..."
    git clone --depth 1 -b v0.40.1 https://github.com/nvm-sh/nvm.git "$NVM_DIR" >/dev/null 2>&1 \
      || die "nvm clone failed."
  fi
  . "$NVM_DIR/nvm.sh"
  nvm install 24 >/dev/null || die "nvm install 24 failed."
  nvm use 24 >/dev/null
fi
. "$NVM_DIR/nvm.sh" 2>/dev/null || true
ok "Node $(node -v) active."

# ── [4] Fork + submodule (the server's git credentials must reach the private repo ─
#     tukuk/tukuk-agent-editor; on 401: add a PAT, or make the fork public) ──
if [ ! -d code-server/.git ]; then
  info "[4] clone fork → $INSTALL_DIR/code-server (±350MB)..."
  # Reuse the credentials that ALREADY work for the parent auto-update:
  #  • token HTTPS (https://user:token@github.com/...) → the same token;
  #  • SSH (git@github.com:owner/repo.git) → the same server SSH key.
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  CLONE_URL="$FORK_URL"
  if [[ "$ORIGIN_URL" == https://*@github.com/* ]]; then
    CRED="${ORIGIN_URL%%github.com/*}"
    CLONE_URL="${CRED}github.com/tukuk/tukuk-agent-editor.git"
  elif [[ "$ORIGIN_URL" == git@github.com:* || "$ORIGIN_URL" == ssh://git@github.com/* ]]; then
    CLONE_URL="git@github.com:tukuk/tukuk-agent-editor.git"
  fi
  git clone --depth 1 "$CLONE_URL" code-server \
    || { warn "clone with the origin URL failed — trying anonymous HTTPS."; rm -rf code-server; git clone --depth 1 "$FORK_URL" code-server; } \
    || die "clone failed with both the origin identity and anonymous HTTPS. tukuk/tukuk-agent-editor is NOT anonymously readable: publish it, or give this box a read deploy key/PAT for the tukuk account."
fi
( cd code-server && git submodule update --init --depth 1 lib/vscode >/dev/null 2>&1 ) \
  || ( cd code-server && git submodule update --init lib/vscode ) || die "lib/vscode submodule failed."
[ -d code-server/lib/vscode/extensions ] || [ -d code-server/lib/vscode/Extensions ] \
  || die "lib/vscode is still empty."
ok "Sources ready: $(git -C code-server rev-parse --short HEAD) + vscode $(git -C code-server/lib/vscode rev-parse --short HEAD)"

# ── [5] Build (the big source is DOWN temporarily — cloud tier keeps answering /ask) ─
# Lesson: esbuild core-ci was once KILLED by the OOM killer (peak ±3.5GB alone,
# + inherited node workers with a 4GB heap). Safe layers: an extra temporary swap,
# higher swappiness, heap lowered to 3072, meilisearch+ollama resting during the build.
OLLAMA_WAS_ACTIVE=0
if [ "$KEEP_OLLAMA" = 0 ] && systemctl is-active --quiet ollama 2>/dev/null; then
  systemctl stop ollama && OLLAMA_WAS_ACTIVE=1
  warn "ollama STOPPED temporarily for the build (/ask uses the cloud as usual)."
fi
MEILI_WAS_ACTIVE=0
if systemctl is-active --quiet meilisearch 2>/dev/null; then
  systemctl stop meilisearch && MEILI_WAS_ACTIVE=1
  warn "meilisearch STOPPED temporarily for the build (/cari search may be slow)."
fi

TMPSWAP=/swap-agent.tmp
ADDED_SWAP=0
SWAP_GB=$(free -b | awk '/Swap:/{print int($2/1073741824)}')
if [ "${SWAP_GB:-0}" -lt 12 ]; then
  info "[5a] adding 6GB temporary swap (total now ${SWAP_GB}GB)..."
  dd if=/dev/zero of="$TMPSWAP" bs=1M count=6144 status=none \
    && chmod 600 "$TMPSWAP" && mkswap "$TMPSWAP" >/dev/null && swapon "$TMPSWAP" \
    && ADDED_SWAP=1 && ok "extra swap active."
fi
ORIG_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo 60)
sysctl -q -w vm.swappiness=90 2>/dev/null || true

info "[5] build — this takes ~1–2 hours on 4 cores; log: /tmp/tukuk-agent-build.log"
export NODE_OPTIONS=--max-old-space-size=3072
bash scripts/build-tukuk-agent.sh 2>&1 | tee /tmp/tukuk-agent-build.log
BUILD_RC=${PIPESTATUS[0]}

# Restore everything that was paused, whatever the build result.
sysctl -q -w vm.swappiness="$ORIG_SWAPPINESS" 2>/dev/null || true
if [ "$ADDED_SWAP" = 1 ]; then
  swapoff "$TMPSWAP" 2>/dev/null && rm -f "$TMPSWAP" && ok "temporary swap removed."
fi
[ "$MEILI_WAS_ACTIVE" = 1 ] && systemctl start meilisearch && ok "meilisearch restarted."
[ "$OLLAMA_WAS_ACTIVE" = 1 ] && systemctl start ollama && ok "ollama restarted."
[ "$BUILD_RC" = 0 ] || die "build failed (rc=$BUILD_RC) — end of log: $(tail -3 /tmp/tukuk-agent-build.log | tr '\n' ' ')"

# ── [6] Install the release locally ────────────────────────────────────────
info "[6] install → /opt/tukuk-agent/release + service..."
[ -x code-server/release/bin/tukuk-agent ] || die "release/bin/tukuk-agent missing — odd."
mkdir -p /opt/tukuk-agent
rsync -a --delete code-server/release/ /opt/tukuk-agent/release/
getent passwd tukuk-agent >/dev/null 2>&1 || useradd --system --home-dir /var/lib/tukuk-agent --shell /usr/sbin/nologin tukuk-agent
install -d -m 0750 -o tukuk-agent -g tukuk-agent /var/lib/tukuk-agent/extensions /var/lib/tukuk-agent/user-data /var/lib/tukuk-agent/projects
chown -R tukuk-agent:tukuk-agent /opt/tukuk-agent
cp deploy/tukuk-agent.service /etc/systemd/system/tukuk-agent.service
systemctl daemon-reload
systemctl enable tukuk-agent >/dev/null
systemctl restart tukuk-agent
sleep 3
if systemctl is-active --quiet tukuk-agent; then
  ok "tukuk-agent ACTIVE on 127.0.0.1:8443."
else
  warn "service not active yet — check: journalctl -u tukuk-agent -n 30"
fi

cat <<'EOF'
═══════════════════════════════════════════════════════════════════════
Final steps (after the service is active):
  1. The editor can be reached TWO ways:
     a) https://tukuk.org/agent — reverse proxy inside tukuk-os (the main
        path; uses the existing tunnel, NO Cloudflare change), or
     b) agent.tukuk.org — ONLY if feasible: a dashboard route
        (Zero Trust → Networks → Routes) → http://127.0.0.1:8443.
        The current API token does NOT have tunnel permission; only the dashboard can.
  2. The service unit needs an Environment=... --abs-proxy-base-path /agent line
     for path (a) — already set in this fork's ExecStart.
  3. AGENT_TOKEN in /opt/tukuk-os/.env + restart tukuk-os (done by the
     author over SSH, not a manual task).
  4. In Cline (if the vsix is installed later): Provider OpenAI
     Compatible, Base URL https://tukuk.org/api/agent/v1, Key <AGENT_TOKEN>,
     Model tukuk-agent.
═══════════════════════════════════════════════════════════════════════
EOF
