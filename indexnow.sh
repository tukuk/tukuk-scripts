#!/usr/bin/env bash
# IndexNow — tell search engines (Bing, Yandex, Naver, Seznam...) when
# tukuk.org content is added / changed / deleted.
# Reference: https://www.indexnow.org/documentation
#
# Usage:
#   ./scripts/indexnow.sh                          # send ALL URLs from the live sitemap.xml
#   ./scripts/indexnow.sh https://tukuk.org/blog   # send ONE URL (GET mode)
#   ./scripts/indexnow.sh URL1 URL2 ...            # send several URLs (POST mode)
#
# Response: 200 = OK, 202 = accepted (key validation pending).
# The key is hosted publicly by design at https://tukuk.org/<key>.txt (IndexNow Option 1).
set -euo pipefail

KEY="${INDEXNOW_KEY:-bd8f0317c5ab4cddb9a3dc62f7ec15ae}"
HOST="tukuk.org"
API="https://api.indexnow.org/indexnow"
KEYLOC="https://tukuk.org/${KEY}.txt"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

submit_get() { # one URL — the URL must be URL-escaped (RFC 3986)
  local code
  code=$(curl -s -o /tmp/indexnow-get.log -w '%{http_code}' --get "$API" \
    --data-urlencode "url=$1" \
    --data-urlencode "key=$KEY" \
    --data-urlencode "keyLocation=$KEYLOC")
  printf 'HTTP %s  %s\n' "$code" "$1"
  case "$code" in 200 | 202) return 0 ;; *)
    sed 's/^/    /' /tmp/indexnow-get.log 2>/dev/null || true
    return 1 ;;
  esac
}

submit_post() { # URL list ($@) — up to 10,000 URLs per POST
  local json_urls url sep=''
  json_urls=''
  for url in "$@"; do
    json_urls+="${sep}\"${url}\""
    sep=','
  done
  local payload="{\"host\":\"${HOST}\",\"key\":\"${KEY}\",\"keyLocation\":\"${KEYLOC}\",\"urlList\":[${json_urls}]}"
  local code
  code=$(curl -s -o /tmp/indexnow-post.log -w '%{http_code}' \
    -X POST "$API" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "$payload")
  printf 'HTTP %s  %s URLs sent\n' "$code" "$#"
  case "$code" in 200 | 202) return 0 ;; *)
    sed 's/^/    /' /tmp/indexnow-post.log 2>/dev/null || true
    return 1 ;;
  esac
}

if [[ $# -ge 1 && "$1" != "-" && "$1" != "all" ]]; then
  if [[ $# -eq 1 ]]; then submit_get "$1"; else submit_post "$@"; fi
  exit $?
fi

# No arguments → collect all URLs from the live sitemap, send them at once.
mapfile -t URLS < <(curl -fsS "https://tukuk.org/sitemap.xml" | grep -oE '<loc>[^<]+' | sed 's/<loc>//')
if [[ ${#URLS[@]} -eq 0 ]]; then
  echo 'Failed: no URLs found in sitemap.xml' >&2
  exit 1
fi
submit_post "${URLS[@]}"
