#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-all-repos.sh — Penyelenggaraan dan Penyegerakan Repositori Tukuk OS
# ─────────────────────────────────────────────────────────────────────────────

set -e

WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/tukuk-org}"
ORG="tukuk"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

echo "🔄 Menyemak dan menyegerakkan semua repositori bawah GitHub @$ORG..."

REPOS=(
  "tukuk-os"
  "node-tukuk-server"
  "tukuk-mcp-server"
  "tukuk-builder"
  "tukuk-scripts"
  "tukuk-android-apps"
  "tukuk-ai-models"
  "tukuk-arc-2026"
  "station-break"
  "tukuk-agent-editor"
  "tukuk-dashboard"
  "tchat"
  "tukuk-devops"
  "tukuk-ops-docs"
  "tukuk-os-search"
)

for repo in "${REPOS[@]}"; do
  echo "--------------------------------------------------------"
  echo "📦 Repositori: $repo"
  if [ -d "$repo/.git" ]; then
    echo "⬇️ Pulling updates..."
    (cd "$repo" && git pull --rebase origin main || git pull --rebase || true)
  else
    echo "📥 Cloning https://github.com/$ORG/$repo.git..."
    git clone "https://github.com/$ORG/$repo.git" "$repo" || echo "⚠️  Keluaran 404/Kosong: Repositori belum dimuatkan dengan kod."
  fi
done

echo "--------------------------------------------------------"
echo "✅ Penyegerakan semua repositori selesai!"
