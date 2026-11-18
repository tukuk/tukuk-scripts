#!/usr/bin/env bash
# ==============================================================================
# setup-all.sh — Full automatic Tukuk-OS setup for a real server.
#
# How to use on an EMPTY machine (Ubuntu 22.04+) — ONE step only:
#   git clone git@github.com:tukuk/tukuk-os.git /opt/tukuk-os
#   cd /opt/tukuk-os
#   npm install     # postinstall -> this script auto-runs, ready 100% at once
#
# (a new machine needs a GitHub SSH key while the repo is private; .env is MERGED by
#  scripts/make-env.sh from deploy/env.defaults (publishable) + deploy/env.secrets (not
#  in git) — the tunnel token comes from that private half, never from a .json file)
#
# Or manual:  sudo bash scripts/setup-all.sh
#
# This script is IDEMPOTENT — you can run it many times; parts that are
# already done will be skipped. When called via npm postinstall, it only
# acts if: (a) TUKUK_AUTO_SETUP=1, OR (b) the app is at /opt/tukuk-os.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${BLUE}➜ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${TUKUK_INSTALL_DIR:-/opt/tukuk-os}"
# ONE FOLDER: every other path this script needs derives from the install dir (see
# deploy/paths.sh). TUKUK_ROOT is exported first so an overridden TUKUK_INSTALL_DIR
# moves the Builder and the game source with it instead of splitting them across two
# roots — the exact kind of disagreement this file exists to prevent.
export TUKUK_ROOT="$INSTALL_DIR"
if [[ -f "$REPO_DIR/deploy/paths.sh" ]]; then
  # shellcheck source=../deploy/paths.sh
  . "$REPO_DIR/deploy/paths.sh"
fi
FROM_NPM=0
[[ "${1:-}" == "--from-npm" ]] && FROM_NPM=1

# ── Safety gate: do not auto-modify the system unless it really is a server ────
# Recursion guard: prevent nested npm install from triggering setup repeatedly.
if [[ "${TUKUK_SETUP_RUNNING:-0}" == "1" ]]; then
  info "setup-all already running in the parent process — skipping."
  exit 0
fi
export TUKUK_SETUP_RUNNING=1

if [[ $FROM_NPM -eq 1 ]]; then
  if [[ "${TUKUK_AUTO_SETUP:-0}" != "1" && "$REPO_DIR" != "$INSTALL_DIR" ]]; then
    info "postinstall: auto-setup skipped (not a server). To run it on a server:"
    echo "   sudo bash scripts/setup-all.sh     ATAU   TUKUK_AUTO_SETUP=1 npm install"
    exit 0
  fi
fi

# ── Require root; escalate to sudo automatically ──────────────────────────────
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null; then
    exec sudo env "TUKUK_AUTO_SETUP=${TUKUK_AUTO_SETUP:-1}" "TUKUK_SETUP_RUNNING=1" "PATH=$PATH" bash "$0" "${@:---from-server}"
  fi
  die "Need root (use sudo)."
fi

command -v apt-get >/dev/null || die "This script is for Ubuntu/Debian."

echo -e "${BLUE}========================================================${NC}"
echo -e "${GREEN}  Tukuk-OS — Auto Setup (server + Cloudflare Tunnel)${NC}"
echo -e "${BLUE}========================================================${NC}"

# ── [1] .env file (keys & API) — merged from the two bundled halves ──────────
# deploy/env.defaults is publishable; deploy/env.secrets is not in git. make-env.sh
# joins them, and exits 3 when the private half is missing. That is a WARNING here and
# not a death: setup-all runs from npm postinstall, and killing `npm install` on a
# laptop that has no tokens is worse than telling the operator once, in the tunnel step
# below and again in make-env's own output, what is missing.
bash "$REPO_DIR/scripts/make-env.sh" || warn ".env is incomplete — the tunnel and admin bootstrap need deploy/env.secrets (see the list above)."
[[ -f "$REPO_DIR/.env" ]] && chmod 600 "$REPO_DIR/.env"
get_env() { [[ -f "$REPO_DIR/.env" ]] && grep -E "^$1=" "$REPO_DIR/.env" | head -1 | cut -d= -f2- | sed 's/^["'"'"']//; s/["'"'"']$//' || true; }

# Mutation routes (/crawl, /crawl/batch, /documents, /settings) are FAIL-OPEN: if
# API_KEY is empty, requireApiKey() just lets the request through — anyone on the
# internet could inject documents into our search index or wipe it. Generate a key
# as soon as .env exists so a new server is secure by default.
if [[ -f "$REPO_DIR/.env" && -z "$(get_env API_KEY)" ]]; then
  echo "API_KEY=$(head -c 24 /dev/urandom | base64 | tr -d '=+/')" >> "$REPO_DIR/.env"
  warn "API_KEY generated in .env — send it as the X-API-Key header for mutation routes."
fi

# ── [2] Base packages + memory tuning (2GB RAM) ───────────────────────────────
info "[1/8] Base packages & kernel tuning..."
apt-get update -y -qq
apt-get install -y -qq curl wget git unzip rsync zram-tools ca-certificates >/dev/null
[[ -f /etc/default/zramswap ]] || cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=75
PRIORITY=100
EOF
systemctl enable --now zramswap >/dev/null 2>&1 || true
cat > /etc/sysctl.d/99-tukuk-os.conf << 'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
EOF
sysctl --system > /dev/null
ok "System tuning done."

# ── [3] Node.js 22 LTS ─────────────────────────────────────────────────────────
info "[2/8] Node.js..."
if ! command -v node >/dev/null || [[ "$(node -v | cut -c2-3)" -lt 20 ]]; then
  # NodeSource publishes apt suites per Ubuntu release, and a freshly formatted box can be
  # newer than the newest suite it carries. Under `set -e` a failing `bash -` here aborted
  # the entire install at step [2/8], so it is allowed to fail and the failure must name the
  # fix rather than leave a half-installed box.
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null \
    || warn "NodeSource setup failed for this release — falling back to the distro package"
  apt-get install -y -qq nodejs >/dev/null 2>&1 || true
  command -v node >/dev/null || die "nodejs is not installed. Fix: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - && sudo apt-get install -y nodejs"
fi
ok "Node $(node -v) / npm $(npm -v)"

# ── [4] Meilisearch ────────────────────────────────────────────────────────────
info "[3/8] Meilisearch..."
if ! command -v meilisearch >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/meilisearch/meilisearch/latest/scripts/install-meilisearch.sh | bash >/dev/null 2>&1 \
    || { ARCH=$(dpkg --print-architecture); wget -q "https://github.com/meilisearch/meilisearch/releases/latest/download/meilisearch-linux-${ARCH}" -O /usr/local/bin/meilisearch && chmod +x /usr/local/bin/meilisearch; }
fi
ok "meilisearch: $(command -v meilisearch || echo 'NONE — install it yourself')"

MEILI_KEY="$(get_env MEILI_MASTER_KEY)"
if [[ -z "$MEILI_KEY" ]]; then
  MEILI_KEY="$(head -c 24 /dev/urandom | base64 | tr -d '=+/')"
  echo "MEILI_MASTER_KEY=$MEILI_KEY" >> "$REPO_DIR/.env"
  warn "A new MEILI_MASTER_KEY was generated and stored in .env."
fi

# ── [3b] Unprivileged service user ────────────────────────────────────────────
# Both long-running services run as `tukuk-os`, never as root. This is not cosmetic:
# /api/admin/terminal (src/server.js) executes shell commands as the user the web
# service runs under, so `User=root` there meant any admin-session bug was a root
# shell on the box. The code tree stays root-owned and READ-ONLY to the service;
# only the runtime dirs handed over below are writable.
info "[3b/8] Service user..."
SVC_USER="tukuk-os"
getent passwd "$SVC_USER" >/dev/null 2>&1 || \
  useradd --system --no-create-home --home-dir /var/lib/tukuk-os \
    --shell /usr/sbin/nologin --comment "Tukuk-OS web + search services" "$SVC_USER"
install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" /var/lib/tukuk-os
ok "Service user: $SVC_USER"

cat > /etc/systemd/system/meilisearch.service << EOF
[Unit]
Description=Meilisearch (Tukuk-OS index engine)
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
# The key is read from .env at start, never interpolated into the unit. Interpolating it
# (what this script used to do) leaves the secret world-readable in /etc/systemd/system
# AND freezes it: once .env was rotated on the box, the unit kept the old literal, every
# search answered 403 and src/meili.js silently served the 30-document mock instead of the
# real 859-document index. /health still said "meilisearch":"available" throughout.
EnvironmentFile=$INSTALL_DIR/.env
User=$SVC_USER
Group=$SVC_USER
# systemd defaults the working directory to /, and ProtectSystem=strict below makes /
# read-only -- so meilisearch aborts at startup with "Read-only file system (os error
# 30)" and Restart=always spins it forever (seen on a rebuilt box, 30 Oct 2026: restart
# counter 52, /health "meilisearch":"unreachable"). Point the cwd at the one path this
# unit is allowed to write.
WorkingDirectory=$INSTALL_DIR/meili_data
ExecStart=$(command -v meilisearch) --db-path $INSTALL_DIR/meili_data --master-key \${MEILI_MASTER_KEY} --http-addr 127.0.0.1:7700
Restart=always
RestartSec=3
MemoryMax=1G

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=$INSTALL_DIR/meili_data

[Install]
WantedBy=multi-user.target
EOF

# ── [5] Place the app at /opt/tukuk-os + git branch ready ──────────────────────
info "[4/8] Application & git..."
if [[ "$REPO_DIR" != "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR"
  # --delete with the payload dirs EXCLUDED. apps/ (the Builder), models/, bin/ and game/
  # are box-local data living INSIDE the checkout — deploy/paths.sh made them subdirectories
  # of the folder, so an ordinary "copy this checkout over that one" would now delete 1-2 GB
  # of Builder node_modules and the published game. `--exclude` also protects a path from
  # --delete, which is why these are excluded rather than merely ignored by .gitignore.
  rsync -a --delete --exclude node_modules --exclude meili_data --exclude snapshots --exclude dumps \
    --exclude apps --exclude models --exclude bin --exclude game \
    "$REPO_DIR/" "$INSTALL_DIR/"
fi
cd "$INSTALL_DIR"
git config --global --add safe.directory "$INSTALL_DIR" || true
if [[ -d .git ]]; then
  DEFAULT_BRANCH="$(get_env GIT_BRANCH)"; DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  git fetch --all --prune -q || true
  git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH" || true
  git pull --ff-only -q origin "$DEFAULT_BRANCH" || warn "git pull skipped (local overrides)."
  ok "Git branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
fi
[[ -d node_modules ]] || npm install --omit=dev --no-audit --no-fund
mkdir -p meili_data snapshots dumps data

# Hand the RUNTIME dirs to the service user. `content/blog` and `public/downloads` are
# also runtime: the admin post editor rewrites markdown there and /api/apk writes the
# built APKs there. Everything else in $INSTALL_DIR stays root-owned (read-only to Node).
for d in data snapshots dumps meili_data content/blog public/downloads; do
  install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 "$INSTALL_DIR/$d"
  chown -R "$SVC_USER:$SVC_USER" "$INSTALL_DIR/$d"
  chmod -R g+rwX "$INSTALL_DIR/$d"
  find "$INSTALL_DIR/$d" -type d -exec chmod g+s {} +
  # ROOT timers (auto-update, every backup) also write into these dirs. A file written
  # by a root script would otherwise be group-read-only and the app would silently stop
  # persisting to it after the first root-written file landed — the same class of silent
  # failure as a frozen secret. The default ACL keeps every new file group-writable.
  if command -v setfacl >/dev/null; then
    setfacl -R -m "g:$SVC_USER:rwX" "$INSTALL_DIR/$d" 2>/dev/null || true
    find "$INSTALL_DIR/$d" -type d -exec setfacl -m "d:g:$SVC_USER:rwX" {} + 2>/dev/null || true
  fi
done
# .env holds ADMIN_PASSWORD / MEILI_MASTER_KEY / API_KEY. It keeps its 0600 owner; the
# service user gets read through a one-off ACL so nothing else changes hands.
if [[ -f "$INSTALL_DIR/.env" ]] && command -v setfacl >/dev/null; then
  setfacl -m "u:$SVC_USER:r--" "$INSTALL_DIR/.env" 2>/dev/null || true
fi
ok "Runtime dirs owned by $SVC_USER (root timers stay writable via a default ACL)."

# ── [5b] ONE FOLDER: pull the stragglers in before anything references them ────
# The units and nginx blocks below name paths inside $INSTALL_DIR; a box that still has
# /opt/tukuk-builder, /var/www/tukuk-play, ~/models, ~/bin or ~/station-break would
# otherwise install a unit pointing at nothing and serve 404s. Idempotent, and it leaves
# the old paths as symlinks, so an nginx config or a script that was not reinstalled
# still resolves. Its failure is not fatal: with the symlinks in place the box serves.
if [[ -f "$INSTALL_DIR/scripts/consolidate-layout.sh" ]]; then
  info "Consolidating everything under $INSTALL_DIR ..."
  bash "$INSTALL_DIR/scripts/consolidate-layout.sh" \
    || warn "layout consolidation reported problems — see above. The old paths are symlinked, so services still resolve."
fi

# ── [6] systemd services (tukuk-os + watchdog) ──────────────────────────────
info "[5/8] Tukuk-OS service..."
cat > /etc/systemd/system/tukuk-os.service << EOF
[Unit]
Description=Tukuk-OS Search Engine
After=network-online.target meilisearch.service
Wants=meilisearch.service
StartLimitIntervalSec=0

[Service]
Type=simple
# NEVER root: see [3b]. The code tree is read-only to the service; the only writable
# paths are the three listed in ReadWritePaths (data, blog markdown, APK output).
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$INSTALL_DIR/.env
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=1024
Environment=PORT=3000
Environment=HOST=127.0.0.1
ExecStart=$(command -v node) index.js
Restart=always
RestartSec=3
MemoryMax=1536M
TasksMax=512

# --- sandbox ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=$INSTALL_DIR/data $INSTALL_DIR/content/blog $INSTALL_DIR/public/downloads

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/tukuk-os-watchdog.service << EOF
[Unit]
Description=Watchdog Tukuk-OS
After=tukuk-os.service meilisearch.service

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/scripts/watchdog.sh
EOF

cat > /etc/systemd/system/tukuk-os-watchdog.timer << 'EOF'
[Unit]
Description=Watchdog Tukuk-OS every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s
Unit=tukuk-os-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now meilisearch >/dev/null
systemctl enable --now tukuk-os >/dev/null
systemctl enable --now tukuk-os-watchdog.timer >/dev/null
ok "tukuk-os + meilisearch + watchdog running."

# ── [6b] Tukuk Agent (editor + AI build-agent) — unit is always installed;
#     the service can ONLY start once a ready-built release from the laptop has
#     been rsync'd to /opt/tukuk-agent/release (no heavy build on the VPS). ────
if [[ -f "$INSTALL_DIR/deploy/tukuk-agent.service" ]]; then
  getent passwd tukuk-agent >/dev/null 2>&1 || \
    useradd --system --home-dir /var/lib/tukuk-agent --shell /usr/sbin/nologin tukuk-agent 2>/dev/null || true
  install -d -m 0750 -o tukuk-agent -g tukuk-agent \
    /var/lib/tukuk-agent/extensions /var/lib/tukuk-agent/user-data /var/lib/tukuk-agent/projects 2>/dev/null || true
  cp "$INSTALL_DIR/deploy/tukuk-agent.service" /etc/systemd/system/tukuk-agent.service
  systemctl daemon-reload
  systemctl enable tukuk-agent >/dev/null 2>&1 || true
  if [[ -x /opt/tukuk-agent/release/bin/tukuk-agent ]]; then
    chown -R tukuk-agent:tukuk-agent /opt/tukuk-agent 2>/dev/null || true
    systemctl restart tukuk-agent >/dev/null 2>&1 \
      && ok "Tukuk Agent running on 127.0.0.1:8443 — https://agent.tukuk.org (through the tunnel)." \
      || warn "tukuk-agent failed to start — check: journalctl -u tukuk-agent -n 30"
  else
    warn "Tukuk Agent unit installed, but no release yet at /opt/tukuk-agent/release."
    echo "   Build on the LAPTOP:  bash scripts/build-tukuk-agent.sh"
    echo "   Push to the server:   bash scripts/publish-agent.sh <user@host>"
    echo "   then rerun setup-all.sh (or: sudo systemctl restart tukuk-agent)."
  fi
fi

# ── [7] Cloudflare Tunnel automatic ────────────────────────────────────────────
info "[6/8] Cloudflare Tunnel..."
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  # The suite is per codename and this line used to say `jammy` outright. On a box formatted
  # with a newer Ubuntu that is either an empty repo or a dependency fight, and the
  # `apt-get update` below it ran under `set -e` — so it killed the install BEFORE the .deb
  # fallback could ever run. Ask the running system, check that Cloudflare publishes the
  # suite, and treat every step as optional until cloudflared answers.
  CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
  CODENAME="${CODENAME:-jammy}"
  if ! curl -fsI "https://pkg.cloudflare.com/cloudflared/dists/$CODENAME/Release" >/dev/null 2>&1; then
    warn "Cloudflare publishes no apt suite for '$CODENAME' — installing the release .deb instead."
    CODENAME=""
  fi
  if [ -n "$CODENAME" ]; then
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $CODENAME main" | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update -y -qq || warn "apt-get update failed after adding the Cloudflare repo"
    apt-get install -y -qq cloudflared >/dev/null 2>&1 || true
  fi
  if ! command -v cloudflared >/dev/null; then
    CF_ARCH="$(dpkg --print-architecture)"
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb" \
      && dpkg -i "cloudflared-linux-${CF_ARCH}.deb" && rm -f "cloudflared-linux-${CF_ARCH}.deb"
  fi
  command -v cloudflared >/dev/null || die "cloudflared is not installed — no apt suite for $CODENAME and the .deb download failed (needs internet)"
fi

CF_TOKEN="$(get_env CF_TUNNEL_TOKEN)"
CF_ID="$(get_env CF_TUNNEL_ID)"
# A real cloudflared token ALWAYS starts with "eyJ" (JSON base64). Reject broken
# /placeholder values so a new server doesn't die on `service install <garbage>`.
if [[ -n "$CF_TOKEN" && "$CF_TOKEN" != eyJ* ]]; then
  warn "CF_TUNNEL_TOKEN is not a valid cloudflared token (it must start with 'eyJ…'). Ignored."
  CF_TOKEN=""
fi
mkdir -p /etc/cloudflared
if [[ -n "$CF_TOKEN" ]]; then
  # ── TOKEN MODE (most portable — NO .json credentials file needed) ──
  # config.yml is built from the template: the `credentials-file:` line is replaced
  # with `token: <TOKEN>`. Ingress stays in this file (not dependent on the dashboard).
  # IMPORTANT: `cloudflared service install` REJECTS a `token:` config (it wants
  # credentials-file), BUT `cloudflared tunnel run --config` ACCEPTS a token.
  # So the systemd unit is written directly (ExecStart `--config ... tunnel run`), not
  # via `service install` — this is how a new server can be 100% automatic.
  [[ -n "$CF_ID" ]] || die "CF_TUNNEL_TOKEN set but CF_TUNNEL_ID empty — put the tunnel UUID."
  sed -e "s#<TUNNEL_ID>#$CF_ID#g" \
      -e "s#^credentials-file:.*#token: $CF_TOKEN#" \
      "$INSTALL_DIR/deploy/cloudflared/config.yml" > /etc/cloudflared/config.yml
  chmod 600 /etc/cloudflared/config.yml   # config now contains a secret token
  cat > /etc/systemd/system/cloudflared.service << 'EOF'
[Unit]
Description=cloudflared Tunnel (Tukuk-OS, token mode)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudflared >/dev/null && systemctl restart cloudflared >/dev/null \
    && ok "Cloudflare Tunnel ($CF_ID) running in TOKEN MODE (portable, no .json)." \
    || die "Failed to start cloudflared service — check: journalctl -u cloudflared -n 30"
elif [[ -n "$CF_ID" ]]; then
  # ── NAMED/JSON MODE (fallback: needs a <CF_ID>.json file on this server) ──
  CRED_SRC=""
  for cand in "$INSTALL_DIR/deploy/cloudflared/$CF_ID.json" "$HOME/.cloudflared/$CF_ID.json" "/root/.cloudflared/$CF_ID.json" "/home/tukuk/.cloudflared/$CF_ID.json"; do
    [[ -f "$cand" ]] && CRED_SRC="$cand" && break
  done
  [[ -n "$CRED_SRC" ]] || die "No CF_TUNNEL_TOKEN & credentials $CF_ID.json not found. Easiest: Cloudflare dashboard → Networks → Tunnels → $CF_ID → copy the TOKEN, put CF_TUNNEL_TOKEN=<eyJ…> in .env, rerun setup-all.sh. OR scp the .json file from the old server."
  cp "$CRED_SRC" "/etc/cloudflared/$CF_ID.json" && chmod 600 "/etc/cloudflared/$CF_ID.json"
  sed "s#<TUNNEL_ID>#$CF_ID#g" "$INSTALL_DIR/deploy/cloudflared/config.yml" > /etc/cloudflared/config.yml
  cloudflared service install >/dev/null && systemctl enable --now cloudflared >/dev/null \
    && ok "Cloudflare Tunnel ($CF_ID) installed from the local JSON credentials." \
    || die "Failed to install cloudflared service — check /etc/cloudflared/config.yml."
else
  warn "CF_TUNNEL_TOKEN / CF_TUNNEL_ID not yet set in .env — tunnel skipped."
  echo "   Recommended way (TOKEN MODE, portable to all servers):"
  echo "   Cloudflare One → Tunnels → $CF_ID (or create a new one) → copy the TOKEN (starts 'eyJ'),"
  echo "   paste CF_TUNNEL_TOKEN=<token> + CF_TUNNEL_ID=<uuid> into $INSTALL_DIR/.env,"
  echo "   then:  sudo bash scripts/setup-all.sh   (only the tunnel step is rerun)"
  echo "   Quick test without a token:  cloudflared tunnel --url http://localhost:3000"
  # A tunnel token can be READ back from the account API — this is a GET, verified to
  # return the same value on repeated calls, so it does not rotate or invalidate the
  # connector credential the box is already using. It works with the API token already
  # in this file, and needs no dashboard click and no Zone DNS permission.
  echo "   Re-read the live token for any tunnel UUID (no dashboard needed):"
  echo "     curl -s -H \"Authorization: Bearer \$(get_env CLOUDFLARE_API_TOKEN)\" \"https://api.cloudflare.com/client/v4/accounts/\$(get_env CLOUDFLARE_ACCOUNT_ID)/cfd_tunnel/<uuid>/token\" | sed 's/.*\"result\":\"//; s/\".*//'"
  echo "   (ONE tunnel: c1d8ea0f-b512-487b-b7e7-ad730c24da9e routes tukuk.org, www and tchat — the owner freeze; agent/play/build are parked commented in config.yml until routed in the dashboard. Admin panel: https://tukuk.org/admin)"
fi

# ── [7b] ONE connector — a second tunnel is an error now, not a missing feature ─
# play / tchat / build once rode a SECOND tunnel (a3af5bb4) because the main tunnel is
# TOKEN mode and ignores a local ingress. That split cost a second credential file, a
# second unit, and a second thing to forget on a rebuild — and forgetting it 530'd a
# production hostname. All of them are routes on the ONE tunnel now (dashboard → Zero
# Trust → Networks → Routes, connector c1d8ea0f). This block installs nothing; it
# retires the old layout so a box upgraded from it converges on the new one.
info "[+] one tunnel only (play / tchat / build ride c1d8ea0f)..."
# `systemctl cat`, NOT `list-unit-files | grep -q`: under pipefail a grep -q that matches early
# leaves systemctl dead of SIGPIPE and the pipeline returns 141, so an installed unit reads as
# absent. Same failure mode scripts/selfheal-access.sh was caught in on 2026-11-01.
if systemctl cat cloudflared-build.service >/dev/null 2>&1; then
  # The second connector's credential is not in git, so a box upgraded from the old layout can
  # still be the only thing keeping those hostnames alive. Retiring it before the dashboard
  # routes exist would take three live hostnames down — and put nothing in the log to say why.
  # So the order is prove-then-retire: every hostname it carries must answer 200 FIRST.
  UNROUTED=()
  for h in build.tukuk.org tchat.tukuk.org play.tukuk.org; do
    c=$(curl -4 -s -o /dev/null -w '%{http_code}' -m 12 "https://$h/" 2>/dev/null || echo 000)
    [[ "$c" == "200" ]] || UNROUTED+=("$h ($c)")
  done
  if [[ ${#UNROUTED[@]} -gt 0 && "${RETIRE_SECOND_TUNNEL:-0}" != "1" ]]; then
    warn "cloudflared-build is still installed and was NOT retired — ${UNROUTED[*]} does not answer 200"
    echo "   Add each of them as a public hostname on the ONE tunnel (Zero Trust → Networks → Routes,"
    echo "   connector c1d8ea0f; service = HTTP localhost:3000, except build = HTTP 127.0.0.1:5174),"
    echo "   confirm they answer 200, then rerun this script to retire the second connector."
    echo "   Force it anyway (takes those hostnames down): sudo RETIRE_SECOND_TUNNEL=1 bash scripts/setup-all.sh"
  else
    systemctl disable --now cloudflared-build >/dev/null 2>&1 || true
    # `mv`, not `rm`: the old credential stays recoverable while the dashboard routes settle.
    if [[ -f /etc/cloudflared/config-build.yml ]]; then
      mv /etc/cloudflared/config-build.yml /etc/cloudflared/config-build.yml.retired
    fi
    if [[ -f /etc/systemd/system/cloudflared-build.service ]]; then
      mv /etc/systemd/system/cloudflared-build.service /etc/systemd/system/cloudflared-build.service.retired
    fi
    systemctl daemon-reload
    ok "cloudflared-build retired — one connector left (cloudflared), its hostnames proved 200 first"
  fi
else
  ok "one connector (cloudflared) — no cloudflared-build unit installed"
fi
if [[ "$(systemctl is-active cloudflared 2>/dev/null)" == active ]]; then
  ok "cloudflared (c1d8ea0f) active"
else
  warn "cloudflared is not active — every hostname is down; check: journalctl -u cloudflared -n 40"
fi

# ── [8] Cloudflare R2 cold backup — edge is WORKERLESS (see README §9) ────
info "[7/8] Cloudflare (R2 cold backup — NO Worker on the request path)..."
CF_API="$(get_env CLOUDFLARE_API_TOKEN)"
CF_ACC="$(get_env CLOUDFLARE_ACCOUNT_ID)"
if [[ -n "$CF_API" ]]; then
  export CLOUDFLARE_API_TOKEN="$CF_API"
  # wrangler finds the account from this one variable. Without it the deploy answers
  # "Failed to automatically retrieve account IDs for the logged in user", which reads as a
  # permissions problem and is not one — the token is fine, the account id was never passed.
  if [[ -n "$CF_ACC" ]]; then export CLOUDFLARE_ACCOUNT_ID="$CF_ACC"; fi
  command -v wrangler >/dev/null || npm install -g wrangler --silent || true
  # WORKERLESS: the tukuk.org/www Worker route is intentionally gone — a route that
  # fetch()ed its own zone doubled the request count and spent the account's DAILY FREE
  # WORKER REQUEST CAP, which is what "429 · error code: 1027" means (not a zone WAF rule —
  # verified 30 Oct 2026 by crossing the 00:00 UTC reset, when the same URLs came back to
  # life). Both hosts are plain tunnel CNAMEs now, and origin-down failover lives in
  # nginx (@down / @down_json), so DO NOT deploy or route worker/ here: visitor traffic
  # behind a Worker would re-spend that same cap and take the R2 backup uploads down with
  # it. Global wrangler above stays only because snapshot-r2.sh can
  # fall back to a wrangler R2 upload when BACKUP_WORKER_URL is not set.
  # snapshot-r2.sh reads its whole configuration from the environment and this is the only
  # call that runs it without systemd's EnvironmentFile: invoked from npm's postinstall there
  # is no .env in scope, so BACKUP_WORKER_URL/SECRET are empty, every upload falls back to a
  # wrangler call that cannot authenticate, and the log reads like the edge mirror is down —
  # while the timer's own run (which does load .env) keeps it fresh. Hand it the keys here.
  ( export BACKUP_WORKER_URL="$(get_env BACKUP_WORKER_URL)" \
           BACKUP_UPLOAD_SECRET="$(get_env BACKUP_UPLOAD_SECRET)" \
           MEILI_MASTER_KEY="$(get_env MEILI_MASTER_KEY)" \
           MEILI_HOST="$(get_env MEILI_HOST)" \
           R2_BUCKET="$(get_env R2_BUCKET)"
    bash "$INSTALL_DIR/scripts/snapshot-r2.sh" ) || true
  cat > /etc/systemd/system/tukuk-snapshot.service << EOF
[Unit]
Description=Snapshot Tukuk-OS site to R2
After=tukuk-os.service

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$INSTALL_DIR/.env
ExecStart=/bin/bash $INSTALL_DIR/scripts/snapshot-r2.sh
EOF
  cat > /etc/systemd/system/tukuk-snapshot.timer << 'EOF'
[Unit]
Description=R2 snapshot every 6 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Unit=tukuk-snapshot.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now tukuk-snapshot.timer >/dev/null
  ok "6-hour snapshot timer active — site snapshots kept in R2 as a cold disaster backup."
else
  warn "No CLOUDFLARE_API_TOKEN — R2 snapshot step skipped (site still serves fine via tunnel + nginx)."
fi

# ── T Chat backup (chat.json + chat-media) → R2, every 6 hours ──
if [ -f "$INSTALL_DIR/scripts/backup-chat.sh" ]; then
  chmod +x "$INSTALL_DIR/scripts/backup-chat.sh" 2>/dev/null || true
  # SNAP_DIR defaults to $INSTALL_DIR/snapshots, which is a root-owned tree while this unit
  # runs as tukuk: tar died with "Cannot open: Permission denied" every 6 hours, so the chat
  # backup never happened. Give the unit a directory its user actually owns.
  install -d -o tukuk -g tukuk -m 750 /var/backups/tukuk-chat
  cat > /etc/systemd/system/chat-backup.service << EOF
[Unit]
Description=Backup T Chat data (chat.json + media)
After=tukuk-os.service

[Service]
Type=oneshot
User=tukuk
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$INSTALL_DIR/.env
Environment=SNAP_DIR=/var/backups/tukuk-chat
ExecStart=/bin/bash $INSTALL_DIR/scripts/backup-chat.sh
EOF
  cat > /etc/systemd/system/chat-backup.timer << 'EOF'
[Unit]
Description=Backup T Chat data every 6 hours

[Timer]
OnCalendar=*-*-* 01,07,13,19:15:00
Persistent=true
Unit=chat-backup.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now chat-backup.timer >/dev/null 2>&1 || true
  ok "6-hour T Chat backup timer active (chat-backup.timer)."
fi

# Auto-update every 30 minutes: git pull → npm install (only if the lock changed)
# → restart (only if code changed). Every half hour is cheap because a quiet box pays
# for it with ONE bounded `git fetch` — the owner asked for GitHub code to be live
# within 30 minutes, and the pull model costs zero CI minutes. :07/:37 keeps the run
# clear of the :00/:15 backup lanes. Disable with GIT_AUTO_UPDATE=0 in .env.
if [[ "$(get_env GIT_AUTO_UPDATE)" != "0" ]]; then
  cat > /etc/systemd/system/tukuk-update.service << 'EOF'
[Unit]
Description=Update Tukuk-OS (git + npm + services + edge)

[Service]
Type=oneshot
WorkingDirectory=/opt/tukuk-os
ExecStart=/bin/bash /opt/tukuk-os/scripts/auto-update.sh
EOF
  cat > /etc/systemd/system/tukuk-update.timer << 'EOF'
[Unit]
Description=Auto-update Tukuk-OS every 30 minutes

[Timer]
OnCalendar=*-*-* *:07,37:00
RandomizedDelaySec=180
Persistent=true
Unit=tukuk-update.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now tukuk-update.timer >/dev/null
  ok "Auto-update every 30 min active (tukuk-update.timer :07/:37). Manual: npm run update"
fi

# ── [8c] nginx front proxy ────────────────────────────────────────────────────
# The tunnel ingress sends every public hostname to 127.0.0.1:3000, and on the live
# box that port is NGINX, with Node behind it on 3001. Without this step a fresh
# box serves the same hostname straight from Node: no shared cache, no front-set
# CSP/permissions headers, and `tukuk-front.conf`'s edge rules never apply — the
# site looks alive while behaving like a different site. Idempotent: the installer
# detects Node already on 3001 and just reloads the config.
info "[+] nginx front proxy..."
if ! command -v nginx >/dev/null; then
  apt-get install -y -qq nginx >/dev/null || warn "nginx install failed — the front proxy step is skipped."
fi
if command -v nginx >/dev/null && [[ -f "$INSTALL_DIR/deploy/nginx/install-tukuk-front.sh" ]]; then
  # Is the front already cut over? nginx on 3000 AND Node on 3001 is the finished shape.
  front_live() { ss -ltn 2>/dev/null | grep -E '127\.0\.0\.1:3000 ' >/dev/null && ss -ltn 2>/dev/null | grep -E '127\.0\.0\.1:3001 ' >/dev/null; }
  if front_live; then
    bash "$INSTALL_DIR/deploy/nginx/install-tukuk-front.sh" reload >/dev/null 2>&1 \
      && ok "nginx front already live — config reloaded from the repo copy." \
      || warn "front reload failed — sudo nginx -t"
  else
    # The installer refuses to `cut` until the proxy passed its checks on VERIFY_PORT
    # (8080), so the automatic path has to honour that staging rather than fight it:
    # verify (installs the conf on 8080) → the non-interactive harness → cut.
    # nginx-front-check.js exits 1 on any failed check, which is the gate that keeps a
    # half-installed proxy from stealing the port the tunnel dials.
    if bash "$INSTALL_DIR/deploy/nginx/install-tukuk-front.sh" verify >/dev/null 2>&1 \
       && node "$INSTALL_DIR/scripts/nginx-front-check.js" 8080 >/tmp/tukuk-front-check.log 2>&1; then
      bash "$INSTALL_DIR/deploy/nginx/install-tukuk-front.sh" cut >/dev/null 2>&1 \
        && ok "nginx fronts the app (hostnames -> nginx :3000 -> Node :3001); front checks passed." \
        || warn "cut-over failed after passing checks — sudo bash deploy/nginx/install-tukuk-front.sh status"
    else
      warn "front proxy NOT enabled: nginx-front-check.js on 8080 did not pass."
      echo "   Node keeps serving :3000 directly (site works, without the front cache/headers)."
      echo "   Last failing checks: $(grep -c '^FAIL' /tmp/tukuk-front-check.log 2>/dev/null || echo '?') — see /tmp/tukuk-front-check.log"
      echo "   Redo by hand once nginx is sane: sudo bash deploy/nginx/install-tukuk-front.sh verify"
    fi
  fi
fi
# play.tukuk.org is a second server block on the same :3000 listener, and its
# `location = /index.pck.zip` + `= /index.wasm.zip` aliases are the only reason the
# Godot pack and binary get cached at the edge. install-tukuk-front.sh has never copied
# this conf (it only knows about the front one), so without the step below a rebuilt box
# serves the game from the wrong root — and the page still looks fine locally while every
# visitor streams 500 MB off this VPS. The installer also puts the publisher and its
# sudoers grant in place, and proves the grant works, because a detached --deploy build
# fails on sudo authorization minutes after the export finished.
if [[ -f "$INSTALL_DIR/deploy/godot/install-on-box.sh" ]] && command -v nginx >/dev/null; then
  if bash "$INSTALL_DIR/deploy/godot/install-on-box.sh"; then
    ok "play.tukuk.org origin installed (nginx block + publisher + sudoers grant)."
  else
    warn "play.tukuk.org origin install failed — the game may be serving uncached artifacts; run: sudo bash $INSTALL_DIR/deploy/godot/install-on-box.sh"
  fi
fi

# ── [8d] every other unit the running box has ─────────────────────────────────
# These files live in deploy/ and are part of the box, but nothing above installed
# them, so a rebuild silently lost backups, indexnow, load governance and the
# builder. tukuk-os.service is deliberately NOT in this list: the deploy copy is
# the developer variant (/home/tukuk paths, WantedBy=default.target) and would
# overwrite the working unit written in [5] with one that cannot start here.
info "[+] remaining services & timers..."
for u in tukuk-data-backup.service tukuk-data-backup.timer \
         tukuk-identity-backup.service tukuk-identity-backup.timer \
         tukuk-content-backup.service tukuk-content-backup.timer \
         meili-backup.service meili-backup.timer \
         indexnow-submit.service indexnow-submit.timer \
         load-governor.service load-governor.timer \
         weight-report.service weight-report.timer \
         builder-idle-stop.service builder-idle-stop.timer \
         cloudflared-update.service cloudflared-update.timer \
         tukuk-builder.service tukuk-builder-wake.service; do
  [[ -f "$INSTALL_DIR/deploy/$u" ]] || continue
  cp "$INSTALL_DIR/deploy/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
for t in tukuk-data-backup tukuk-identity-backup tukuk-content-backup meili-backup \
         indexnow-submit load-governor weight-report builder-idle-stop cloudflared-update; do
  systemctl enable --now "$t.timer" >/dev/null 2>&1 || true
done
# ── [8d-bis] the Builder's SOURCE is not this repo ────────────────────────────
# tukuk-builder.service has WorkingDirectory=$INSTALL_DIR/apps/builder — inside the app
# folder, but NOT part of it: the Builder is its own git repo. A rebuild that only brings
# this repo ends up with the unit ENABLED and nothing under it:
# build.tukuk.org answers 502 and no log line says why.
# Install and build run ON
# THE BOX, mirroring scripts/deploy-builder.sh, because a laptop-side build would not
# match the server's node22. Both steps are gated on the source or node_modules being
# absent, so a routine deploy pays nothing here.
BUILDER_DIR="${TUKUK_BUILDER_DIR:-$INSTALL_DIR/apps/builder}"
BUILDER_LOG=/var/log/tukuk-builder-install.log
if [[ ! -f "$BUILDER_DIR/package.json" ]]; then
  info "[+] App Builder source missing — cloning tukuk/tukuk-builder into $BUILDER_DIR..."
  # [5b] creates the layout, but it is deliberately non-fatal: it warns and carries on so a
  # stale box keeps serving. That means this clone can be reached with apps/ missing, so it
  # cannot assume the parent it is about to write into exists. (git itself does create
  # missing parents — verified — which is exactly why this was invisible in testing.)
  mkdir -p "$(dirname "$BUILDER_DIR")"
  # The Builder has its OWN repo, and that repo is not anonymously readable — it used to be
  # cloned from an account where it WAS public, so this step worked with no credentials at
  # all and the install never said otherwise. Reuse whatever identity already reaches the
  # parent repo (a token embedded in origin's URL, or the box's SSH key), then try anonymous
  # HTTPS in case it gets published. Same pattern as scripts/build-agent-on-server.sh.
  BUILDER_URL="https://github.com/tukuk/tukuk-builder.git"
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$ORIGIN_URL" == https://*@github.com/* ]]; then
    BUILDER_URL="${ORIGIN_URL%%github.com/*}github.com/tukuk/tukuk-builder.git"
  elif [[ "$ORIGIN_URL" == git@github.com:* || "$ORIGIN_URL" == ssh://git@github.com/* ]]; then
    BUILDER_URL="git@github.com:tukuk/tukuk-builder.git"
  fi
  if git clone --depth 1 "$BUILDER_URL" "$BUILDER_DIR" >>"$BUILDER_LOG" 2>&1; then
    ok "Builder source cloned."
  elif [[ "$BUILDER_URL" != https://github.com/tukuk/tukuk-builder.git ]] \
    && git clone --depth 1 https://github.com/tukuk/tukuk-builder.git "$BUILDER_DIR" >>"$BUILDER_LOG" 2>&1; then
    ok "Builder source cloned anonymously."
  else
    warn "Builder clone failed — build.tukuk.org answers 502 until it succeeds. The reason is most"
    warn "  likely auth, not network: tukuk/tukuk-builder is NOT readable anonymously."
    if [[ -z "$ORIGIN_URL" || "$ORIGIN_URL" == *.bundle || "$ORIGIN_URL" == /media/* ]]; then
      warn "  This box has no GitHub identity at all (installed from a bundle or a USB copy). Fix:"
      warn "  copy the Builder source onto the box and run: sudo bash scripts/deploy-builder.sh <that path>"
    else
      warn "  Fix one of: publish tukuk/tukuk-builder, or give this box a read key/PAT for it, then:"
      warn "    sudo git clone --depth 1 $BUILDER_URL $BUILDER_DIR"
    fi
  fi
fi
if [[ -f "$BUILDER_DIR/package.json" && ! -d "$BUILDER_DIR/node_modules" ]]; then
  info "[+] installing Builder dependencies + building — 1-2 GB and several minutes, first time only..."
  corepack disable >/dev/null 2>&1 || true
  command -v pnpm >/dev/null || npm i -g pnpm@9.15.9 --silent
  if ( cd "$BUILDER_DIR" && pnpm install --frozen-lockfile --prefer-offline && pnpm build ) >>"$BUILDER_LOG" 2>&1; then
    ok "App Builder installed at $BUILDER_DIR (log: $BUILDER_LOG)."
  else
    warn "Builder install/build failed — tail $BUILDER_LOG. The unit will stay up but answer 502."
  fi
fi

# The wake front door FIRST, so :5174 is never briefly empty (same ordering rule as
# scripts/deploy-builder.sh). It used to be missing from this list: [8d] copies
# tukuk-builder-wake.service into /etc/systemd/system but nothing enabled or started it,
# so a rebuilt box had a live connector, a built Builder on :5176, and NOTHING on the
# :5174 that the build route points at — build.tukuk.org 502 with no log line naming
# the cause. Verified on a rebuild, 30 Oct 2026.
for s in tukuk-builder-wake tukuk-builder; do
  systemctl enable --now "$s" >/dev/null 2>&1 || true
done
ok "backup / indexnow / governance timers enabled."

# ── [8e] Cockpit — the console that would have made this rebuild a non-event ──
# Installed because "no remote shell" is what turned a broken network setting into
# a full reinstall. LAN address ONLY: the socket drop-in clears the default
# 0.0.0.0/:: listeners (systemd list-type options APPEND, so the empty assignment
# is required) and re-listens on the box's own LAN IPv4. Nothing is exposed to the
# internet, and no firewall rule is added — automating ufw over SSH is how boxes
# get locked out a second time.
info "[+] Cockpit (LAN-only console)..."
apt-get install -y -qq cockpit >/dev/null 2>&1 || warn "cockpit install failed (not fatal)."
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -1)"
# The address is RE-DERIVED, never stored. Freezing the lease this script happens to
# see is how the console went unreachable on 28 Oct 2026: the drop-in still pointed at
# 192.168.8.104 while the box had moved to .100/.101, so cockpit.socket reported
# "active" and refused every LAN connection. deploy/cockpit-lan-socket.sh rewrites the
# drop-in from `ip` at every boot; this call fixes it right now.
if [[ -f "$INSTALL_DIR/deploy/cockpit-lan-socket.sh" ]]; then
  install -m 0755 "$INSTALL_DIR/deploy/cockpit-lan-socket.sh" /usr/local/sbin/cockpit-lan-socket
  # Before=cockpit.socket is what makes this a fix rather than a correction: cockpit.socket
  # starts from sockets.target, i.e. EARLIER than multi-user.target. Without the ordering it
  # comes up first on a stale drop-in and the console is dead for the first seconds of every
  # boot after a lease change, until the regenerator restarts it.
  # DefaultDependencies=no is the other half, learned the hard way on 4 Nov 2026: the implicit
  # After=basic.target pulls this unit in behind sockets.target, and Before=cockpit.socket then
  # forms the cycle cockpit.socket → this unit → network-online → NetworkManager → basic.target
  # → sockets.target → cockpit.socket. systemd's fix is to DELETE cockpit.socket's start job —
  # a console that never comes up, and a blocking restart from inside this unit deadlocks on its
  # own job queue. So: no implicit deps, only the three orderings spelled out below.
  cat > /etc/systemd/system/cockpit-lan-socket.service << 'EOF'
[Unit]
Description=Cockpit socket: bind to the LAN addresses this boot actually has
DefaultDependencies=no
After=network-online.target
Wants=network-online.target
Before=cockpit.socket

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cockpit-lan-socket

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable cockpit-lan-socket.service >/dev/null 2>&1 || true
  bash /usr/local/sbin/cockpit-lan-socket || warn "cockpit LAN socket bind failed — check: sudo bash $INSTALL_DIR/deploy/cockpit-lan-socket.sh"
  ok "Cockpit: http://${LAN_IP:-<lan-ip>}:9090 (127.0.0.1 kept for an ssh tunnel). Addresses re-derived at boot."
else
  warn "deploy/cockpit-lan-socket.sh missing — Cockpit left on its default listener. Bind it before relying on it."
fi

# ── [8f] The Godot HD build — opt-in, because it is 1.3 GB of downloads ────────
# INSTALL_GAME=1 makes play.tukuk.org reproducible from this script alone. Default is
# OFF: pulling Godot plus the export templates on every `npm install` would make a
# routine deploy take half an hour and a gigabyte for a page most deploys never touch.
if [[ "${INSTALL_GAME:-0}" == "1" ]]; then
  info "[+] Godot web build (INSTALL_GAME=1)..."
  GAME_DIR="${STATION_BREAK_DIR:-${TUKUK_GAME_DIR:-$INSTALL_DIR/game}}"
  GBIN="${GODOT_BIN:-${TUKUK_GODOT_BIN:-$INSTALL_DIR/bin/godot}}"
  # Source: the game lives in its own private repo (tukuk/station-break). A handover
  # USB carries it as a bundle, which needs no GitHub auth on a machine that has no key yet.
  if [[ ! -f "$GAME_DIR/project.godot" ]]; then
    BUN="${TUKUK_GAME_BUNDLE:-}"
    if [[ -n "$BUN" && -f "$BUN" ]]; then
      git clone -b game "$BUN" "$GAME_DIR" >/dev/null 2>&1 || true
      [[ -f "$GAME_DIR/project.godot" ]] && ok "game source cloned from the bundle."
    fi
  fi
  if [[ ! -f "$GAME_DIR/project.godot" ]]; then
    warn "no game source at $GAME_DIR — set STATION_BREAK_DIR, or TUKUK_GAME_BUNDLE=/media/…/code/station-break-game.bundle"
  elif ! "$GBIN" --version >/dev/null 2>&1; then
    warn "Godot not runnable at $GBIN — install the headless 4.x binary there (or set GODOT_BIN), then rerun."
    echo "   It must match the installed export templates; a mismatch fails the export silently." >&2
  else
    # The boot overlay. The builder falls back to the copy committed beside it, so this is
    # only a report of WHICH copy is going into the shell — said before a ~20 minute export,
    # not after. The builder's own `grep -q tb-bytes index.html` stays the real gate: a shell
    # that silently fell back to the stock template must never be published.
    if [[ -f "$GAME_DIR/web-head.html" ]]; then
      info "boot overlay: $GAME_DIR/web-head.html (box copy wins)"
    elif [[ -f "$INSTALL_DIR/deploy/godot/web-head.html" ]]; then
      info "boot overlay: deploy/godot/web-head.html (the copy rescued into git)"
    else
      warn "no boot overlay anywhere — the builder will refuse to run. play.tukuk.org would show a bare progress bar."
    fi
    # The publisher, the sudoers grant and the nginx block were installed back in [8c] by
    # deploy/godot/install-on-box.sh, which also proved the grant works. Nothing is
    # installed here: this section only spends the ~20 minutes an export takes.
    if sudo -u tukuk -H env "HOME=/home/tukuk" STATION_BREAK_DIR="$GAME_DIR" GODOT_BIN="$GBIN" \
         bash "$INSTALL_DIR/deploy/godot/build-web.sh"; then
      sudo -u tukuk /usr/local/sbin/publish-tukuk-play "$GAME_DIR/web-build" \
        && ok "Godot build published; the publisher printed its own edge-cache MISS/HIT verdict." \
        || warn "publisher refused to publish — read its FATAL line (pack size or mainPack alias)."
    else
      warn "Godot export failed — tail: \${WEB_BUILD_LOG:-$GAME_DIR/../web-latest.log}"
    fi
  fi
fi

# ── [9] Final verification ────────────────────────────────────────────────────
info "[8/8] Verifying..."
sleep 3
for svc in meilisearch tukuk-os cloudflared nginx; do
  printf "  %-14s %s\n" "$svc" "$(systemctl is-active $svc 2>/dev/null || echo inactive)"
done
if [[ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/health 2>/dev/null)" == "200" ]]; then
  ok "Search engine is live at http://127.0.0.1:3000"
else
  warn "Server not responding yet — check: journalctl -u tukuk-os -n 30"
fi

# T Chat custom domain (tchat.tukuk.org) — check whether the hostname is configured.
TCHAT_H="$(get_env TCHAT_HOST)"; TCHAT_H="${TCHAT_H:-tchat.tukuk.org}"
TCHAT_CODE=$(curl -s -m6 -o /dev/null -w '%{http_code}' "https://$TCHAT_H/" 2>/dev/null || echo 000)
if [[ "$TCHAT_CODE" == "200" ]]; then
  ok "T Chat custom domain is live at https://$TCHAT_H (HTTP 200)."
elif [[ "$TCHAT_CODE" == "000" ]]; then
  warn "https://$TCHAT_H does not resolve in DNS yet — add a public hostname in Cloudflare Zero Trust → Networks → Routes (full guide in .env.example)."
else
  warn "https://$TCHAT_H replied HTTP $TCHAT_CODE — check the tunnel route + the TCHAT_HOST gate in src/server.js."
fi

# ── [9b] The three things a rebuild loses SILENTLY ────────────────────────
# Proven by the 30 Oct 2026 rebuild, where each of these was wrong and nothing said
# so: the box came up green and serving 200 while it was in fact (a) answering every
# question from the 30-document mock, because data/ is gitignored and therefore absent
# from a fresh clone, (b) running with no LLM provider key at all, and (c) unable to
# write a single backup — which is exactly how (a) and (b) get lost a second time. All
# three cost one second to check here, and this list is the only place an operator ever
# reads them at install time.
info "[+] what a fresh clone cannot have (check before you trust this box)..."

# 1. the corpus. books-shelves/ is ~2500 crawled reading lists; rebuilding it is a
#    ~30-minute Internet Archive crawl and it exists in no git object anywhere.
if [[ -d "$INSTALL_DIR/data/books-shelves" ]]; then
  ok "data/ corpus present ($(find "$INSTALL_DIR/data/books-shelves" -name '*.json' 2>/dev/null | wc -l) shelves)."
else
  warn "data/ has NO crawled corpus — search and /books are serving the mock. Restore it:"
  echo "     bash scripts/restore-data.sh <slot>   # slot = weekday+hour, e.g. 207. Find a copy:"
  echo "     R2_BUCKET=tukuk-fallback bash scripts/r2-inventory.sh   (run where wrangler is logged in)"
fi

# 2. the LLM chain. Every key lives in .env only, so a rebuild drops the brain to its
#    extractive floor — which still answers, so nothing looks broken.
if grep -qE '^(GROQ|OPENROUTER|OPENAI|HUGGINGFACE)_API_KEY=.+' "$INSTALL_DIR/.env" 2>/dev/null; then
  ok "LLM provider key(s) present in .env."
else
  warn "no LLM provider key in .env — cloud answers are OFF (extractive floor only)."
  echo "     They were never in git. Recover them from the encrypted identity copy:"
  echo "     sudo bash scripts/restore-identity.sh          # verify + stage; --apply to install"
fi

# 3. the backup tracks. A timer that fails every night is worse than no timer, because
#    it reads as coverage. Result is the unit's own verdict ("success" | "exit-code"),
#    but a unit that has NEVER run reports "success" too — so the start timestamp is
#    what separates "covered" from "never tried". Verified on a rebuild, 30 Oct 2026.
for t in tukuk-data-backup tukuk-identity-backup tukuk-content-backup meili-backup; do
  res=$(systemctl show "$t.service" -p Result --value 2>/dev/null || echo -)
  started=$(systemctl show "$t.service" -p ExecMainStartTimestamp --value 2>/dev/null || echo -)
  if [[ -z "$started" || "$started" == "n/a" || "$started" == "-" ]]; then
    warn "$t has never run — no off-box copy of that track yet"
  elif [[ "$res" == "success" ]]; then
    ok "$t last run: ok"
  else
    warn "$t last run: $res — this box has NO working copy of that track"
  fi
done
if [[ ! -r /root/tukuk-backup-key ]]; then
  warn "/root/tukuk-backup-key is missing, so backup-identity.sh refuses to upload unencrypted and"
  echo "     the tunnel keys, .env and signing keystore have no off-box copy at all. The laptop holds"
  echo "     the same passphrase at ~/.config/tukuk/backup-key; put it back with:"
  echo "     scp ~/.config/tukuk/backup-key tukuk@<lan-ip>:/tmp/k && sudo install -m 400 /tmp/k /root/tukuk-backup-key"
fi

echo -e "${BLUE}========================================================${NC}"
echo -e "${GREEN}  DONE. Admin panel: /admin — email login + passkey.${NC}"
echo -e "  Server: $INSTALL_DIR | Log: journalctl -u tukuk-os -f"
echo -e "${BLUE}========================================================${NC}"
