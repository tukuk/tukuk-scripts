#!/usr/bin/env bash
# ==============================================================================
# publish-agent.sh — SEND the Tukuk Agent release built on the LAPTOP to
# the server, then install & start its service there (no heavy build on the VPS).
#
#   bash scripts/build-tukuk-agent.sh            # once, on the laptop
#   bash scripts/publish-agent.sh                    # default tukuk@$TUKUK_HOST
#   bash scripts/publish-agent.sh tukuk@192.168.8.105
#
# Flow:
#   1. rsync code-server/release/ → $DEST:/tmp/tukuk-agent-release/  (as a normal user)
#   2. ssh + sudo: place it at /opt/tukuk-agent/release, create a low-privilege user,
#      install the systemd unit from /opt/tukuk-os/deploy (auto-update must have
#      already pulled the latest commit), enable + restart, confirm active.
#
# Note: sudo runs INTERACTIVELY at the end — you type the server password.
# After the service is up, one final step is not done here: in cloudflared TOKEN
# MODE, the hostname agent.tukuk.org → http://127.0.0.1:8443 MUST be added
# in the Cloudflare dashboard (Zero Trust → Networks → Routes), because the
# local ingress is ignored. After that https://agent.tukuk.org opens up.
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-tukuk@${TUKUK_HOST:-192.168.8.105}}"
if [ -z "$DEST" ]; then
  echo "usage: bash scripts/publish-agent.sh <user@host>   (e.g. tukuk@192.168.8.105)"
  exit 1
fi

REL="code-server/release"
if [ ! -x "$REL/bin/tukuk-agent" ]; then
  echo "✗ $REL/bin/tukuk-agent missing — build first:"
  echo "    bash scripts/build-tukuk-agent.sh"
  exit 1
fi
SIZE=$(du -sh "$REL" | cut -f1)
echo "── 1/3 rsync release ($SIZE) to $DEST ──"
ssh "$DEST" 'rm -rf /tmp/tukuk-agent-release && mkdir -p /tmp/tukuk-agent-release'
rsync -az --delete "$REL/" "$DEST:/tmp/tukuk-agent-release/"

echo "── 2/3 install on the server (you may be prompted for the sudo password) ──"
ssh -t "$DEST" 'sudo bash -se' <<'REMOTE'
set -eu
OS=/opt/tukuk-os
[ -f "$OS/deploy/tukuk-agent.service" ] || { echo "✗ $OS/deploy/tukuk-agent.service missing — run auto-update.sh first."; exit 1; }
mkdir -p /opt/tukuk-agent
rsync -a --delete /tmp/tukuk-agent-release/ /opt/tukuk-agent/release/
rm -rf /tmp/tukuk-agent-release
getent passwd tukuk-agent >/dev/null 2>&1 || useradd --system --home-dir /var/lib/tukuk-agent --shell /usr/sbin/nologin tukuk-agent
install -d -m 0750 -o tukuk-agent -g tukuk-agent /var/lib/tukuk-agent/extensions /var/lib/tukuk-agent/user-data /var/lib/tukuk-agent/projects
chown -R tukuk-agent:tukuk-agent /opt/tukuk-agent
cp "$OS/deploy/tukuk-agent.service" /etc/systemd/system/tukuk-agent.service
systemctl daemon-reload
systemctl enable tukuk-agent >/dev/null
systemctl restart tukuk-agent
sleep 2
systemctl is-active tukuk-agent
REMOTE

echo "── 3/3 done ──"
echo "✓ release at /opt/tukuk-agent/release, tukuk-agent service delivered."
echo "  OPTIONS & IF NEEDED:"
echo "   • Editor password: handled by code-server itself (--auth password),"
echo "     at /var/lib/tukuk-agent/user-data — or change ExecStart to --auth none"
echo "     if authentication is bypassed at the tunnel edge."
echo "   • agent.tukuk.org → http://127.0.0.1:8443 MUST exist as a route in the"
echo "     Cloudflare dashboard (token mode ignores the local ingress)."
echo "   • AGENT_TOKEN (and AGENT_ORIGIN=https://agent.tukuk.org) in the Tukuk-OS env"
echo "     on the server = the same API Key typed in Cline (Base URL"
echo "     https://tukuk.org/api/agent/v1, model tukuk-agent)."
echo "   • The Cline extension (vsix) can be installed later:"
echo "       sudo -u tukuk-agent /opt/tukuk-agent/release/bin/tukuk-agent \\"
echo "         --extensions-dir /var/lib/tukuk-agent/extensions --install-extension cline.vsix"
