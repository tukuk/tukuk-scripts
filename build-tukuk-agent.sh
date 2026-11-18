#!/usr/bin/env bash
# ==============================================================================
# build-tukuk-agent.sh — Build the Tukuk Agent release (VS Code editor + AI agent) on
# the LAPTOP, then embed the Cline extension + the Tukuk-OS MCP configuration.
#
#   bash scripts/build-tukuk-agent.sh [path/to/cline.vsix]
#
# Why on the laptop, not the VPS: building VS Code needs Node 24 + the lib/vscode
# submodule (~1GB) + a heavy toolchain. The VPS ONLY runs a ready release (rsync'd),
# in line with the "no Docker / lightweight server" policy (see deploy/tukuk-agent.service).
#
# Requirements (once, on the laptop):
#   • Node 24 (nvm install 24). code-server engines: node "24".
#   • System libraries for node-gyp: sudo apt install libkrb5-dev
#     build-essential python3 pkg-config libxkbfile-dev libsecret-1-dev
#     (a 'gssapi/gssapi.h' failure in kerberos = libkrb5-dev not installed).
#   • Alternative: build DIRECTLY on the server → scripts/build-agent-on-server.sh.
#   • git submodule update --init code-server/lib/vscode   (large files).
#   • The Cline .vsix file. Download from Open VSX (pinned version) to
#     code-server/vendor/extensions/cline.vsix — OR pass the path as $1.
#     Roo Code / Kilo Code are drop-in replacements (same config).
#
# Output: code-server/release/  (bin/tukuk-agent + bundled node + extensions+config).
# This is what gets rsync'd to /opt/tukuk-agent/release on the VPS.
#
# IMPORTANT: extensions are installed into a SEPARATE --extensions-dir (vendor/extensions
# → release/extensions) so startup is clean & repeatable. Config files from
# tukuk-agent.defaults/ are copied as templates; AGENT_TOKEN/base URL must be
# aligned with the real .env before deploy.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

CS="code-server"
RELEASE="$CS/release"
DEFAULTS="tukuk-agent.defaults"
CS_BIN="$RELEASE/bin/tukuk-agent"

# ── 0. Environment preflight (fail early, not after a 20-minute build) ──
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" != "24" ]; then
  echo "⚠ The Tukuk Agent build needs Node 24 (engines), currently v$NODE_MAJOR."
  echo "  Use:  nvm install 24 && nvm use 24   (do not run this on the VPS)"
  [ -t 1 ] && { echo "  (continuing at your own risk — press Ctrl-C)"; sleep 5; }
fi

if [ ! -d "$CS/lib/vscode/Extensions" ] && [ -z "$(ls -A "$CS/lib/vscode" 2>/dev/null)" ]; then
  echo "✗ lib/vscode submodule is EMPTY. Run:"
  echo "    git -C $CS submodule update --init lib/vscode"
  exit 1
fi

# ── 1. Build tukuk-agent + a standalone release (KEEP_MODULES=1 → bin + node) ──
# foundry-local-sdk downloads OnnxRuntime ±139MB from NuGet for LOCAL VS Code AI
# inference — we don't use it (AI via the cloud /api/agent) and that download
# often times out on slow links. Official skip (the script itself supports it).
export FOUNDRY_LOCAL_SKIP_INSTALL=1

echo "── npm ci (in $CS) ──"
( cd "$CS" && npm ci ) || { echo "✗ npm ci failed"; exit 1; }

echo "── npm run build ──"
( cd "$CS" && npm run build ) || { echo "✗ code-server build failed"; exit 1; }

# build-code-server.sh ONLY compiles the wrapper (tsc). What generates
# lib/vscode-reh-web-linux-x64 (the VS Code web server the release expects) is
# build-vscode.sh — the longest gulp phase (±1–2 hours) and it needs VERSION.
#
# Loose-Copilot patch: the pinned vscode tree runs
# prepareBuiltInCopilotRipgrepShim UNCONDITIONALLY while packaging REH, but
# official Microsoft gets copilot from a prebuilt VSIX while a from-source build
# strips @github/copilot/** per .moduleignore — so a from-source build ALWAYS dies
# with "Copilot SDK directory not found". Tukuk Agent has no Copilot (the agent =
# Cline via /api/agent); the task is loosened to a warning only. Idempotent —
# guarded by the TIADA-COPILOT-SDK marker.
CS_COPILOT_TS="$CS/lib/vscode/build/lib/copilot.ts" node - <<'NODE' || { echo "✗ copilot patch failed"; exit 1; }
const fs = require('node:fs');
const f = process.env.CS_COPILOT_TS;
let s = fs.readFileSync(f, 'utf8');
if (s.includes('TIADA-COPILOT-SDK')) { console.log('\u2713 copilot.ts already patched'); process.exit(0); }
const old = 'throw new Error(`[prepareBuiltInCopilotRipgrepShim] Copilot SDK directory not found at ${copilotSdkBase}`);';
if (!s.includes(old)) { console.error('\u2717 copilot throw pattern not found in ' + f + ' — check the vscode pin manually.'); process.exit(1); }
s = s.replace(old, '/* TIADA-COPILOT-SDK: loose for builds without VSIX */ console.warn("[copilot-shim] SDK missing — skip"); return;');
fs.writeFileSync(f, s);
console.log('\u2713 copilot.ts patched — the REH shim is now loose (warn, not abort).');
NODE

echo "── npm run build:vscode (gulp REH web — long phase) ──"
( cd "$CS" && VERSION="$(node -p "require('./package.json').version")" MINIFY=true npm run build:vscode ) \
  || { echo "✗ build:vscode failed"; exit 1; }

# Copilot is removed outright from the REH output: its node_modules are already
# stripped by .moduleignore (a dist without the sdk throws an activation error at
# editor startup), and we don't use it anyway — the agent is Cline.
rm -rf "$CS/lib/vscode-reh-web-linux-x64/extensions/copilot"

echo "── KEEP_MODULES=1 npm run release (self-contained release/) ──"
( cd "$CS" && KEEP_MODULES=1 MINIFY=true npm run release ) || { echo "✗ release failed"; exit 1; }

[ -x "$CS_BIN" ] || { echo "✗ $CS_BIN missing after release"; exit 1; }
echo "✓ release ready: $RELEASE (bin/tukuk-agent exists)"

# ── 2. Determine the Cline vsix (arg $1 OR vendor/extensions/cline.vsix) ──
VSIX="${1:-$CS/vendor/extensions/cline.vsix}"
EXTDIR="$RELEASE/extensions"
mkdir -p "$EXTDIR"

if [ -f "$VSIX" ]; then
  echo "── installing extension: $VSIX ──"
  # --extensions-dir directs the install into our controlled directory (not ~/.vscode).
  "$CS_BIN" --extensions-dir "$EXTDIR" --install-extension "$VSIX" --force \
    || echo "⚠ install-extension failed (try manually on the VPS: bin/tukuk-agent --install-extension)"
else
  echo "⚠ No vsix at $VSIX."
  echo "  Download Cline from Open VSX (pinned) → put it at $CS/vendor/extensions/cline.vsix"
  echo "  or pass it:  bash scripts/build-tukuk-agent.sh /path/cline.vsix"
  echo "  (the release build is still valid; the extension can be installed later on the VPS.)"
fi

# ── 3. Seed the Tukuk-OS (MCP) config + VS Code settings as templates ──
# VS Code settings.json → <user-data>/User/settings.json (example; the VPS roots
# user-data at /var/lib/tukuk-agent/user-data).
SEED="$RELEASE/tukuk-agent-seed"
mkdir -p "$SEED/User"
cp "$DEFAULTS/settings.json" "$SEED/User/settings.json"
# mcp_settings.json → Cline's globalStorage (the exact location depends on the Cline
# version; copy/enter it via the Cline UI 'Edit MCP Settings' if needed).
cp "$DEFAULTS/mcp_settings.json" "$SEED/mcp_settings.json"
echo "✓ config templates copied to $SEED (settings.json + mcp_settings.json)"

# ── 4. Deploy-step summary ──
cat <<EOF

════════════════════════════════════════════════════════════════════════
Tukuk Agent release ready at: $RELEASE
Next (VPS, NO heavy build there):
  1. rsync $RELEASE/ → /opt/tukuk-agent/release/  (chown tukuk-agent)
  2. set up the user + service:  see the DEPLOY NOTES in deploy/tukuk-agent.service
  3. put AGENT_TOKEN + AGENT_ORIGIN in /home/tukuk/.config/tukuk-os/env
     (the same matching value the Cline extension uses as its API Key)
  4. in Cline (UI): Provider=OpenAI Compatible,
       Base URL  https://tukuk.org/api/agent/v1
       API Key   <AGENT_TOKEN>
       Model     tukuk-agent
     MCP is already registered: tukuk-os (tukuk_search/ask/plan/scaffold/review/agent)
  5. systemctl enable --now tukuk-agent  →  https://agent.tukuk.org
════════════════════════════════════════════════════════════════════════
EOF
