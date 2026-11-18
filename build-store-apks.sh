#!/usr/bin/env bash
# ==============================================================================
# build-store-apks.sh — build a wrapper APK for EVERY app in apk/catalog.json
# (tukuk.org as its own app store, APKPure-style). It calls build-apk.sh
# with per-app env. AAB is only for T Chat (the one that goes to Play).
#
#   bash scripts/build-store-apks.sh
#
# Needs: node + sharp (icons), Android SDK + JDK (build-apk.sh finds them automatically).
# Run scripts/gen-launcher-icons.js first (or it runs here).
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"

# 1) Make sure launcher icons exist for apps without a dedicated PNG.
node scripts/gen-launcher-icons.js || { echo "build-store: icon generation failed"; exit 1; }

# 2) Emit one row per app: slug|pkg|label|url|icon|media|vc|vn
ROWS="$(node -e '
const fs=require("fs"),p=require("path");
const apps=JSON.parse(fs.readFileSync("apk/catalog.json","utf8")).apps;
for(const a of apps){
  const special=p.join("public","icons","apps",a.slug+"-512.png");
  const icon=fs.existsSync(special)?special:p.join("apk","launcher",a.slug+".png");
  console.log([a.slug,a.pkg,a.label,a.url,icon,a.media?"1":"0",a.vc,a.vn].join("\t"));
}')";

ok=0; fail=0
while IFS=$'\t' read -r slug pkg label url icon media vc vn; do
  [ -z "$slug" ] && continue
  aab=0; [ "$slug" = "chat" ] && aab=1
  echo "───────── $slug ($pkg) media=$media aab=$aab ─────────"
  APP_SLUG="$slug" APP_PKG="$pkg" APP_LABEL="$label" APP_URL="$url" \
  APP_ICON="$icon" APP_MEDIA="$media" APP_VC="$vc" APP_VN="$vn" BUILD_AAB="$aab" \
    bash scripts/build-apk.sh | grep -E "✓|⚠|error|Error|GAGAL" || fail=$((fail+1))
  [ -f "public/downloads/tukuk-$slug.apk" ] && ok=$((ok+1)) || { echo "  ✗ $slug: APK missing!"; fail=$((fail+1)); }
done <<< "$ROWS"

echo "══════════════════════════════════════════"
echo "build-store: $ok APKs succeeded, $fail problems"
ls -1 public/downloads/tukuk-*.apk | sed 's#.*/##'
