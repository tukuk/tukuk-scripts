#!/usr/bin/env bash
# public-canary.sh — the check that does NOT live on the box.
#
# Every other monitor in this project runs on the VPS: watchdog.sh restarts a dead
# service, re-registers a tunnel that lost its edge registrations, and shouts when the
# public edge answers 530. All of that is worthless when the box itself is gone — and
# on 31 Oct 2026 the site answered 530 from the public edge while all four LAN
# addresses were unreachable from the dev laptop. Nothing in the stack could have
# reported it, because the reporter was inside the failure.
#
# So this runs from somewhere else: a laptop, a CI runner, a cron on another host.
# It checks the surface Google actually judges — availability, sitemap shape, the
# crawl budget, and whether an unapproved AdSense account is shipping units.
#
#   bash scripts/public-canary.sh                 # human table, exit 1 on any failure
#   CANARY_BASE=http://127.0.0.1:3000 bash scripts/public-canary.sh   # against local
#   CANARY_DASHBOARD_URL=http://127.0.0.1:3000/                       # local, retired-host check
#   CANARY_ADSENSE=on bash scripts/public-canary.sh                   # after approval
#   bash scripts/public-canary.sh --json          # one JSON object, for machines
#
# Exit codes: 0 all good · 1 something is wrong · 2 the edge itself is unreachable ·
#             3 the edge is healthy but it is refusing US, which is not the same finding.
#
# Only curl, sed, grep and wc are assumed. No npm, no node, no repo.
set -uo pipefail

BASE="${CANARY_BASE:-https://tukuk.org}"
TIMEOUT="${CANARY_TIMEOUT:-15}"
ADSENSE="${CANARY_ADSENSE:-off}"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
SKIPS=0
ROWS=""
UNREACHABLE=0
ORIGIN_DOWN=0
BLOCKED=0
CHECKS=0

# code_for <path> — HTTP status, or 000 when curl could not connect at all. curl prints its own
# 000 to stdout on a connection failure, so only the last three characters are trusted.
# Headers are kept alongside the body because a status code alone cannot say WHO answered: on
# this zone the Cloudflare security layer, the fallback Worker and the app all speak in codes,
# and "403 from GitHub's IPs but 200 from a laptop" is a different bug from "503 everywhere".
code_for() {
  local c
  c="$(curl -s -D "$TMP/hdr" -o "$TMP/body" -w '%{http_code}' -m "$TIMEOUT" "$BASE$1" 2>/dev/null)"
  c="${c: -3}"
  printf '%s' "${c:-000}"
}

# who_answered — appended to a failing row so the issue body is evidence rather than a number.
# Header names are matched case-insensitively and stripped by position, because the casing of an
# edge response is not ours to dictate.
who_answered() {
  local srv cf body
  srv="$(grep -i '^server:' "$TMP/hdr" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
  cf="$(grep -i '^cf-mitigated:' "$TMP/hdr" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
  body="$(tr -d '\r\n' < "$TMP/body" 2>/dev/null | cut -c1-90)"
  printf '%s' " [server=${srv:-none}${cf:+ mitigated=$cf} body=${body:-(empty)}]"
}

row() { # $1 ok|fail|skip  $2 name  $3 detail
  CHECKS=$((CHECKS + 1))
  case "$1" in
    fail) FAILS=$((FAILS + 1)); LABEL=FAIL ;;
    skip) SKIPS=$((SKIPS + 1)); LABEL=SKIP ;;
    *)    LABEL=PASS ;;
  esac
  ROWS="${ROWS}$(printf '%-5s %-34s %s' "$LABEL" "$2" "$3")"$'\n'
}

# expect <name> <path> <wanted-code-regex> [text-that-must-appear]
expect() {
  local name="$1" path="$2" want="$3" must="${4:-}"
  local code; code="$(code_for "$path")"
  [ "$code" = "000" ] && UNREACHABLE=$((UNREACHABLE + 1))
  # 530 is Cloudflare's "no connector"; 521-524 and 502 are the same story told by a
  # different hop. All of them mean the box did not answer, which is a different failure
  # from "the box answered with a bug" — and the only one the on-box watchdog cannot report.
  case "$code" in 502|503|521|522|523|524|530) ORIGIN_DOWN=$((ORIGIN_DOWN + 1)) ;; esac
  # A 403 that carries Cloudflare's own challenge/block shape is the security layer speaking,
  # not the app. It gets its own verdict because the two readings are opposites: the site can be
  # perfect for every visitor while this check's datacenter IP is blocked, and the case that
  # matters — a rule that also catches Googlebot — is exactly how a site vanishes from search
  # while looking fine from a laptop. `server: cloudflare` alone proves nothing: every response
  # on this zone carries it.
  if [ "$code" = "403" ] && { grep -qi '^cf-mitigated:' "$TMP/hdr" 2>/dev/null \
    || grep -qiE 'code 1020|attention required|have been blocked|security policy' "$TMP/body" 2>/dev/null; }; then
    BLOCKED=$((BLOCKED + 1))
  fi
  if ! printf '%s' "$code" | grep -qE "^($want)$"; then
    row fail "$name" "want $want, got $code$(who_answered)"
    return 1
  fi
  if [ -n "$must" ] && ! grep -qF -- "$must" "$TMP/body"; then
    row fail "$name" "missing text: $must$(who_answered)"
    return 1
  fi
  row ok "$name" "$code"
  return 0
}

locs() { grep -o '<loc>' "$TMP/body" | wc -l | tr -d ' '; }

# --- 1. the front door -------------------------------------------------------
expect "home"              "/"               "200"
expect "health"            "/health"         "200"
expect "blog"              "/blog"           "200"
expect "privacy"           "/privacy"        "200"
expect "terms"             "/terms"          "200"
expect "contact"           "/contact"        "200"
expect "404 is a real 404" "/canary-no-such-page-$$" "404"

# --- 1b. a retired hostname must not come back ------------------------------
# The admin panel is /admin on the apex. dashboard.tukuk.org served the same app on the same
# port, so "is it up" was never the question — the only thing worth pinning is that it is not
# serving again. A second door to the login page is a second thing that can 502 on its own.
# CANARY_DASHBOARD_URL exists only so the probe can be run against a local edge in the test
# suite; the default is the real retired hostname and nothing else changes.
DASH_URL="${CANARY_DASHBOARD_URL:-https://dashboard.tukuk.org/}"
DASH_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$DASH_URL" 2>/dev/null)"
DASH_CODE="${DASH_CODE: -3}"
case "${DASH_CODE:-000}" in
  200) row fail "dashboard hostname stays retired" "200 — remove the route, the panel is /admin" ;;
  *)   row ok   "dashboard hostname stays retired" "http ${DASH_CODE:-000}" ;;
esac

# --- 2. what crawlers are told ----------------------------------------------
if expect "robots.txt" "/robots.txt" "200" "Sitemap:"; then
  if grep -qE '^Disallow: /$' "$TMP/body"; then
    row fail "robots.txt allows crawling" "site blocks itself with Disallow: /"
  else
    row ok "robots.txt allows crawling" ""
  fi
fi

# The personal AdSense account that used to be pinned here was scrubbed 2026-11-01; ads.txt is
# deliberately seller-less until the owner arranges a new account. Pass CANARY_PUB=pub-XXXX on
# the day that happens, and the canary re-arms this check — until then it only insists the file
# is served, which is what keeps Google's crawler from flagging a 404.
if expect "ads.txt" "/ads.txt" "200"; then
  CANARY_PUB="${CANARY_PUB:-}"
  if [ -n "$CANARY_PUB" ]; then
    if grep -qF "$CANARY_PUB" "$TMP/body"; then
      row ok "ads.txt names the publisher" "$CANARY_PUB"
    else
      row fail "ads.txt names the publisher" "no $CANARY_PUB line"
    fi
  else
    row ok "ads.txt served (no publisher configured yet)" ""
  fi
fi

# --- 3. sitemap shape, which is the crawl budget made visible ---------------
if expect "sitemap.xml" "/sitemap.xml" "200"; then
  N="$(locs)"; [ "$N" -ge 10 ] && row ok "sitemap.xml has entries" "$N loc" || row fail "sitemap.xml has entries" "$N loc"
fi

if expect "sitemap index (geo)" "/sitemap-geo.xml" "200"; then
  N="$(locs)"
  if [ "$N" -ge 600 ]; then row ok "geo index reaches children" "$N children"
  else row fail "geo index reaches children" "$N children (expected >= 600)"; fi
fi

# A cluster far above CRAWL_INDEX_MAX_ITEMS must advertise hubs only. This is the
# single check that notices if the 254,655-page settlements shard comes back.
if expect "crawl budget: settlements" "/sitemap-settlements.xml" "200"; then
  N="$(locs)"
  if [ "$N" -le 20 ]; then row ok "crawl budget: settlements" "$N loc (hubs only)"
  else row fail "crawl budget: settlements" "$N loc — item URLs are back in the sitemap"; fi
fi

# --- 4. the policy on a real item page --------------------------------------
# The hub only links continents, and a continent page renders ~100,000 cards, so the cheap
# way to a real item is a small country page. Qatar has 8 settlements in the dataset: a
# page small enough to fetch every 30 minutes, and still an item far above any sane line.
ITEM=""
for C in qatar panama jamaica; do
  curl -s -m "$TIMEOUT" -o "$TMP/ctry" "$BASE/settlements/n/$C" 2>/dev/null || continue
  ITEM="$(grep -o 'href="/settlements/[^"]*"' "$TMP/ctry" | sed 's/href="//; s/"$//' \
        | grep -vE '^/settlements/(africa|americas|antarctica|asia|europe|oceania)$' \
        | grep -vE '^/settlements/n/' | head -1)"
  [ -n "$ITEM" ] && break
done
if [ -n "$ITEM" ]; then
  if expect "shard item page" "$ITEM" "200"; then
    if grep -qiE '<meta[^>]+name="robots"[^>]+noindex' "$TMP/body"; then
      row ok "shard item is noindex" "$ITEM"
    else
      row fail "shard item is noindex" "$ITEM — meta robots is not noindex,follow"
    fi
    # The computed facts are the difference between a profile and a Wikipedia wrapper:
    # if this row disappears, the page has silently regressed to name + country + dot.
    if grep -qF 'Distance to the equator' "$TMP/body" && grep -qF 'Closest ' "$TMP/body"; then
      row ok "computed facts on the item" ""
    else
      row fail "computed facts on the item" "$ITEM lacks the computed-fact rows"
    fi
    if [ "$ADSENSE" = "on" ]; then
      grep -qF 'pagead2.googlesyndication.com' "$TMP/body" \
        && row ok "approved: units present" "" || row fail "approved: units present" "no AdSense loader on the page"
    else
      if grep -qF 'pagead2.googlesyndication.com' "$TMP/body" || grep -qF '<ins class="adsbygoogle"' "$TMP/body"; then
        row fail "unapproved: no ad units" "$ITEM still ships AdSense"
      else
        row ok "unapproved: no ad units" ""
      fi
    fi
  fi
else
  row skip "shard item discovery" "no country page yielded an item link"
fi

# --- verdict ----------------------------------------------------------------
# Three distinct tragedies, three distinct verdicts. EDGE_DOWN (exit 2) means requests are not
# reaching the origin at all — dead box, dead tunnel, dead datacentre — and no amount of
# on-box monitoring will have noticed. BLOCKED (exit 3) means the edge is alive and has decided
# not to talk to this client: fix the rule, do not redeploy. DEGRADED (exit 1) means the origin
# answered and got something wrong, which is fixable by deploying.
if [ "$UNREACHABLE" -ge 3 ] || [ "$ORIGIN_DOWN" -ge 3 ]; then VERDICT="EDGE_DOWN"
elif [ "$BLOCKED" -ge 3 ]; then VERDICT="BLOCKED"
else VERDICT="$([ "$FAILS" -eq 0 ] && echo OK || echo DEGRADED)"; fi

if [ "$JSON" = "1" ]; then
  printf '{"base":"%s","verdict":"%s","checks":%d,"fails":%d,"skips":%d,"unreachable":%d,"origin_down":%d,"blocked":%d,"adsense":"%s","at":"%s"}\n' \
    "$BASE" "$VERDICT" "$CHECKS" "$FAILS" "$SKIPS" "$UNREACHABLE" "$ORIGIN_DOWN" "$BLOCKED" "$ADSENSE" "$(date -u +%FT%TZ)"
else
  printf '%s\n' "$ROWS"
  printf '%s — %d checks, %d failed, %d skipped, %d unreachable, %d origin-down, %d blocked (%s)\n' \
    "$VERDICT" "$CHECKS" "$FAILS" "$SKIPS" "$UNREACHABLE" "$ORIGIN_DOWN" "$BLOCKED" "$(date -u +%FT%TZ)"
fi

[ "$VERDICT" = "EDGE_DOWN" ] && exit 2
[ "$VERDICT" = "BLOCKED" ] && exit 3
[ "$FAILS" -eq 0 ] || exit 1
exit 0
