#!/usr/bin/env bash
# ==============================================================================
# mirror-export.sh — snapshot the public site into a static folder for Cloudflare Pages.
#
# WHY THIS EXISTS: the whole site hangs off ONE cloudflared tunnel to THIS box.
# If the box, the tunnel or Node dies, tukuk.org AND www.tukuk.org both go dark —
# a DNS record pointing at the same dead origin is not a backup. The /alat tools
# are fully client-side (that was the design rule from day one), so a static
# snapshot of them is a genuine second server: Cloudflare Pages (free) serving
# www.tukuk.org keeps every converter, calculator and the Design Studio working
# even while this box is offline. Staleness costs freshness, never availability.
#
# WHAT IT COPIES: the hub, every /alat/* page (from the sitemap, so a new tool
# is mirrored the same hour it ships), the home page, and the handful of static
# assets those pages reference. NOT the whole site — live-data pages (/weather,
# /traffic, /api/*) would freeze mid-reading on a mirror and their SSR shells
# fetch nothing useful offline, so they stay out of scope on purpose.
#
# Requests go through the front proxy (127.0.0.1:3000) WITHOUT cookies, so they
# ride the shared nginx cache instead of forcing 100 fresh renders per cycle.
# ==============================================================================
set -uo pipefail
BASE="${MIRROR_BASE:-http://127.0.0.1:3000}"
OUT="${MIRROR_OUT:-/var/tmp/tukuk-mirror}"
# A real browser UA, not curl's default: the GitHub Actions lane of this export
# runs from datacenter IPs, where Cloudflare's bot score files plain `curl/8.x`
# requests out (every save 403s in ~0.3s). Home IPs pass even as curl; the
# runner IP only passes looking like a browser. Harmless on the localhost lane.
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

mkdir -p "$OUT"
FAILED=0

# save <url-path> <output-file-relpath>
save() {
  local p="$1" dest="$OUT/$2"
  mkdir -p "$(dirname "$dest")"
  if curl -sf -m 60 --retry 2 -A "$UA" -o "$dest" "$BASE$p"; then
    return 0
  fi
  echo "[mirror-export] FAILED: $p" >&2
  FAILED=$((FAILED + 1))
}

echo "[mirror-export] $BASE → $OUT"
save '/'                 'index.html'
save '/alat'             'alat.html'
# The site's RSS under its conventional name: a reader pointed at
# www.tukuk.org/feed.xml keeps pulling (yesterday's) items even while the main
# server is offline, instead of going red exactly when people check the site.
save '/blog/rss.xml'     'feed.xml'

# Every tool page, taken from the sitemap so the list can never drift from the app.
SITEMAP="$(mktemp)"
if curl -sf -m 30 -A "$UA" -o "$SITEMAP" "$BASE/sitemap.xml"; then
  while read -r p; do
    [ -n "$p" ] || continue
    rel="${p#/alat/}"                       # /alat/unit → unit.html (Pages pretty URL)
    case "$rel" in */*) continue ;; esac    # safety: nested alat paths are not tools
    save "$p" "alat/${rel}.html"
  done < <(grep -o '<loc>[^<]*/alat/[^<]*</loc>' "$SITEMAP" | sed 's|<loc>https\?://[^/]*||; s|</loc>||')
else
  echo "[mirror-export] warning: sitemap unreachable — only hub + home mirrored" >&2
  FAILED=$((FAILED + 1))
fi
rm -f "$SITEMAP"

# Pages serves 404.html for any path the mirror never captured (live-data pages
# like /weather stay on the main server by design — without this file a visitor
# on www would meet Cloudflare's bare error instead of our own "go to the real
# site" page). Written, not scraped: the app's own 404 answer is a JSON blob
# ({"error":"Route not found"}), useless as a human page.
cat > "$OUT/404.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Not on this mirror — tukuk.org</title>
<link rel="stylesheet" href="/theme.css">
</head>
<body>
<main style="max-width:640px;margin:12vh auto;padding:0 20px;text-align:center">
<h1>Not on this mirror</h1>
<p class="tagline">www.tukuk.org serves the Everyday Tools while the main server rests.
This page lives on the full site instead.</p>
<p style="margin-top:24px">
<a href="https://tukuk.org" rel="canonical">Go to tukuk.org</a> &nbsp;·&nbsp;
<a href="/alat">Everyday Tools (offline-safe)</a>
</p>
</main>
<script src="/theme.js"></script>
</body>
</html>
EOF

# The static things those pages load. pdf-lib/fflate turn /alat/pdf and friends
# from dead forms into working tools on the mirror.
for a in /theme.js /theme.css /favicon.ico /icon.svg /apple-touch-icon.png /og.png \
         /consent.js /read-aloud.js /kamus.js \
         /libs/pdf-lib.min.js /libs/fflate.min.js /libs/qrcode.js; do
  save "$a" "${a#/}"
done

# The mirror must never compete with the real site in search: every snapshot page
# carries a canonical to tukuk.org already, and this header makes the intent
# explicit to any crawler that ignores canonicals.
cat > "$OUT/_headers" <<'EOF'
/*
  X-Robots-Tag: noindex, follow
EOF

TOOLS=$(find "$OUT/alat" -name '*.html' 2>/dev/null | wc -l)
echo "[mirror-export] done: $TOOLS tool pages + hub + home, $FAILED failure(s)"
# Partial failure is still a usable mirror — only shout, do not abort a deploy
# on one flaky page (the previous snapshot for that page stays untouched).
exit 0
