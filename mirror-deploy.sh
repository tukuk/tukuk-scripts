#!/usr/bin/env bash
# ==============================================================================
# mirror-deploy.sh — push the snapshot folder to the tukuk-mirror Pages project.
#
# WHY wrangler AND NOT THE REST API: the direct-upload endpoint (a multipart
# POST of a JSON manifest + attachment parts) was tried first and won't be:
# `-F "manifest=@file"` answers 8000096 "manifest not provided", the one form
# it accepts (`manifest={<file}`) then reports deploy "success" while every
# served path is a 404 — the attachments never associate with the manifest,
# whatever hash flavour (md5, blake2b-512, blake2b digest_size=20) or part
# naming is used. wrangler is the reference implementation of that protocol
# and it works on the first try, so we simply call it through npx — cached
# after the first run, no repo dependency, nothing npm-installed mid-deploy.
#
# Needs in the environment (see .env.example):
#   MIRROR_API_TOKEN      API token with Accounts · Cloudflare Pages: Edit
#   CLOUDFLARE_ACCOUNT_ID account id (already used by other Cloudflare tooling)
#   MIRROR_PROJECT        optional, defaults to tukuk-mirror
#
# Custom domain www.tukuk.org is attached to the project ONCE (dashboard or
# deploy/setup-mirror-domain.sh); every deployment below inherits it, so a
# server that comes back online never has to re-point DNS by hand.
# ==============================================================================
set -uo pipefail
OUT="${1:-${MIRROR_OUT:-/var/tmp/tukuk-mirror}}"
PROJECT="${MIRROR_PROJECT:-tukuk-mirror}"
# Assigned-from-default before checking: a bare `${X:?msg}` is a read under
# set -u and scripts/check-shell-vars.js (rightly) refuses it — same rule that
# protects every other install script from the unbound-variable rebuild deaths.
MIRROR_API_TOKEN="${MIRROR_API_TOKEN:-}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
if [ -z "$MIRROR_API_TOKEN" ] || [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
  echo "[mirror-deploy] MIRROR_API_TOKEN (Cloudflare Pages: Edit) and CLOUDFLARE_ACCOUNT_ID must be set — see .env.example" >&2
  exit 1
fi

if [ ! -d "$OUT/alat" ]; then
  echo "[mirror-deploy] $OUT looks empty (no alat/ folder) — run scripts/mirror-export.sh first" >&2
  exit 1
fi

# The live-first failover rule (www serves the running apex when it answers,
# the snapshot only when it does not) travels with every deployment: Pages
# runs a _worker.js found at the project root in front of all assets. Copy
# it in right here so a refresh can never deploy the dumb-mirror behaviour
# by forgetting a step — the file's absence simply keeps the static fallback.
if [ -f deploy/pages-worker.js ]; then
  cp deploy/pages-worker.js "$OUT/_worker.js"
fi

# wrangler reads the token from its own env var name; map ours onto it.
# --commit-dirty: the snapshot lives in /var/tmp but wrangler is invoked from
# the repo cwd, and a server tree with touched data/ files must not stall it.
LOG="$(mktemp)"
URL="$(CLOUDFLARE_API_TOKEN="$MIRROR_API_TOKEN" CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID" \
  npx --yes wrangler@latest pages deploy "$OUT" --project-name="$PROJECT" --commit-dirty=true 2>&1 \
  | tee "$LOG" \
  | grep -oE 'https://[a-f0-9]+\.tukuk-mirror\.pages\.dev' | tail -1)"
if [ -z "$URL" ]; then
  echo "[mirror-deploy] FAILED — wrangler output:" >&2
  tail -20 "$LOG" >&2
  rm -f "$LOG"
  exit 1
fi
rm -f "$LOG"
echo "[mirror-deploy] deployed: $URL"

# Prove it actually serves before declaring victory — a green CLI and a broken
# site look identical from here. Since the _worker.js failover landed, the
# deployment URL proxies the live apex: verify arrives as this curl, and the
# apex's bot rule answers a generic curl UA from a datacenter IP with a 403 —
# honest traffic gets through, so prove with a browser UA like mirror-export
# already does.
sleep 5
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -L \
  -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  "$URL/alat")"
echo "[mirror-deploy] verify /alat on the new deployment: HTTP $CODE"
[ "$CODE" = "200" ] || exit 1
