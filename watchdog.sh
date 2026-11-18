#!/usr/bin/env bash
# Tukuk-OS watchdog — keep the search engine always up AND responsive.
#
# systemd `Restart=always` only kicks in when the process dies. This watchdog
# handles the other cases:
#   1. process dead             → systemctl start
#   2. process alive but hung   → systemctl restart
#   3. Meilisearch dead         → cascade restart
#   4. edge problem (Cloudflare 429 — plan cap or zone rule — tunnel/internet drop) → log LOUDLY.
#      tukuk.org is WORKERLESS now (no R2 fallback to lean on), so a non-2xx at the
#      public edge means real visitors are getting an error page even if Node is fine.
#   4b. a tunnel connector that is running but has LOST its edge registrations → 530 at the
#      public URL with a 200 from the local origin, which `is-active` cannot see. Re-registered
#      by restarting that unit (see re_register below).
#   5. the 30-minute update gone quiet → nudge tukuk-update.service (see below)
#
# Run every 2 minutes via a systemd timer.

set -uo pipefail

APP="tukuk-os.service"
MEILI="meilisearch.service"
URL="${WATCHDOG_URL:-http://127.0.0.1:3000/health}"
THRESHOLD="${WATCHDOG_THRESHOLD:-2}"
STAMP="/tmp/tukuk-os-watchdog.fail"

log() { logger -t tukuk-os-watchdog -- "$*"; echo "[watchdog] $*"; }

# --- 0. the management plane must always be reachable -----------------------
# A box you cannot log into is a box you cannot fix. On 29 Oct 2026 the site was
# healthy while sshd dropped every SYN and cockpit.socket refused connections on
# the address the box actually held — the socket was still bound to the one it had
# at boot (see deploy/cockpit-lan-socket.sh), and the firewall no longer allowed 22.
# Neither is visible through Cloudflare, because the tunnel is outbound-only, so no
# other check in this stack ever notices. Runs FIRST, so it still fires on the
# early-exit paths below. The stamp is only refreshed when something is missing, so on a healthy
# box this check runs on EVERY cycle (every 2 minutes) at the cost of two `ss` calls and one local
# HTTP probe — which is the intent for the owner's own way into the machine.
# `grep -q` is deliberately NOT used here: see scripts/selfheal-access.sh — under `set -o pipefail`
# a `systemctl/ss | grep -q` that DOES match can return 141 (SIGPIPE) and invent a failure.
ACCESS_STAMP="/tmp/tukuk-os-watchdog.access"
if [ ! -f "$ACCESS_STAMP" ] || [ -n "$(find "$ACCESS_STAMP" -mmin +30 2>/dev/null)" ]; then
  MISSING=""
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -E '[:.]22[[:space:]]'   >/dev/null || MISSING="ssh"
    ss -ltn 2>/dev/null | grep -E '[:.]9090[[:space:]]' >/dev/null || MISSING="${MISSING:+$MISSING+}cockpit"
  fi
  # A listening fd is not a console. cockpit can hold an address no client can route to (it did, on
  # a CloudflareWARP tunnel address), so ask the loopback listener for the login page he actually
  # opens. 2xx = fine; anything else means he is locked out of his own box.
  if [ -z "$MISSING" ] && command -v curl >/dev/null 2>&1; then
    CCODE=$(curl -sk -m 6 -o /dev/null -w '%{http_code}' https://127.0.0.1:9090/login 2>/dev/null)
    case "${CCODE:-000}" in
      2[0-9][0-9]) ;;
      *) MISSING="cockpit-not-answering(${CCODE:-000})" ;;
    esac
  fi
  if [ -n "$MISSING" ]; then
    log "🔑 admin access missing ($MISSING) — re-asserting via scripts/selfheal-access.sh"
    bash "$(dirname "$0")/selfheal-access.sh" 2>&1 | while IFS= read -r l; do log "  $l"; done
    touch "$ACCESS_STAMP"
  fi
fi

if ! systemctl is-active --quiet "$MEILI"; then
  log "Meilisearch not active — restart"
  systemctl restart "$MEILI"
fi

# --- tunnel (system service; we can only log, restart needs sudo) ---
if ! systemctl is-active --quiet cloudflared.service 2>/dev/null; then
  log "cloudflared (system) not active — run: sudo systemctl restart cloudflared.service"
fi

# --- public edge: is tukuk.org actually answering VISITORS through Cloudflare? ----------
# The local :3000 check further down cannot see an EDGE fault. This box once sat behind a
# site-wide "429 · error code: 1027" with Node perfectly healthy: a Worker route was
# fetching its own zone, and the doubled request count spent the ACCOUNT's daily free
# Worker request cap (100,000/day, reset 00:00 UTC). 1027 is that cap page — it is NOT a
# WAF rule, which is worth knowing because the two have different fixes and only one of
# them clears by itself at midnight.
# Since the site is workerless (no R2 fallback), anything other than a 2xx here means real
# visitors are being served an error, so a sustained problem is logged loudly (first attempt
# and then every 15th ≈ 30 min) and every state change (healthy→bad, bad→healthy) is logged
# once. The status code, not `curl -f`, decides: 429 is called out as the edge-block case.
probe_edge() { # $1 = url → echoes the HTTP code, or 000 when curl itself could not connect
  local c; c=$(curl -s -o /dev/null -w '%{http_code}' -m 12 "$1" 2>/dev/null); echo "${c:-000}";
}
PUB="${WATCHDOG_PUBLIC_URL:-https://tukuk.org/health}"
PUB_ASSET="${WATCHDOG_PUBLIC_ASSET:-https://tukuk.org/libs/leaflet.min.js}"
PUB_STAMP="/tmp/tukuk-os-watchdog.public"
CODE=$(probe_edge "$PUB")
PREV=$(cat "$PUB_STAMP" 2>/dev/null || echo ok)
# The 30-31 Oct edge outage went unreported by THIS COUNTER, not by the match patterns. When
# the stamp file is absent PREV is the literal "ok"; `${PREV#err:}` strips nothing, so N is
# SET-but-non-numeric, and `${N:-0}` only substitutes for unset-or-empty — it hands "ok"
# straight to `$(( ok + 1 ))`, which reads an unset identifier inside arithmetic, and `set -u`
# makes that FATAL: the unit died on the old line 94 with "ok: unbound variable" without ever
# reaching the log call, every two minutes, for the whole outage. A watchdog that crashes at
# the exact moment the edge breaks is worse than no watchdog — `systemctl is-failed` is the
# only clue and nobody watches it. Only an all-digits test is a real guard, so one helper owns
# the counter now and no branch can reintroduce the old form.
# `2??` was wrong too, though not the cause: `?` matches ANY character, so the pattern means
# "a 2 then any two characters", not "2xx". curl's %{http_code} is always three digits, so
# 530/503 did fall through into `*)` — measured, not assumed — and that is exactly where they
# met the crash above. Match the digits explicitly so the next reader never has to work out
# which of the two was hiding the outage.
bump() { # $1 = stamp prefix, $2 = previous stamp content → echoes the new count
  local n; n=${2#"$1"}; case "$n" in ''|*[!0-9]*) n=0 ;; esac; echo $((n + 1));
}
case "$CODE" in
  2[0-9][0-9])
    [ "$PREV" != ok ] && { log "Public edge RECOVERED — $PUB answering HTTP $CODE (was: $PREV)"; rm -f "$PUB_STAMP"; }
    ;;
  429)
    N=$(bump "429:" "$PREV"); echo "429:$N" > "$PUB_STAMP"
    [ "$N" -eq 1 ] || [ $((N % 15)) -eq 0 ] && log "⛔ CLOUDFLARE EDGE 429: $PUB — every visitor is being refused; Node is NOT the cause (attempt $N). If the body says 'error code: 1027' the account's daily free Worker request cap is spent (resets 00:00 UTC, and it also blocks the R2 backup uploads) — check for a Worker route fetching its own zone. Any other 429 is a zone rule: tukuk.org → Security → Events + WAF → Rate limiting rules."
    ;;
  000)
    N=$(bump "000:" "$PREV"); echo "000:$N" > "$PUB_STAMP"
    [ "$N" -eq 1 ] || [ $((N % 15)) -eq 0 ] && log "⚠ Public edge UNREACHABLE — curl to $PUB failed (tunnel/internet down, not an app fault) (attempt $N)"
    ;;
  *)
    N=$(bump "err:" "$PREV"); echo "err:$N" > "$PUB_STAMP"
    [ "$N" -eq 1 ] || [ $((N % 15)) -eq 0 ] && log "⚠ Public edge answered HTTP $CODE (non-2xx) — bad deploy or origin error surfacing through Cloudflare (attempt $N). For a Worker/fallback answer the LOCAL :3000 check cannot see it, so this line is the only evidence the apex is not on the box — compare /zones/…/workers/routes."
    ;;
esac
# A self-hosted vendored library missing at the edge (the exact class of bug that blanked
# the /traffic map) — catch it here so a broken /libs/ path never waits for a human report.
ACODE=$(probe_edge "$PUB_ASSET")
case "$ACODE" in
  2[0-9][0-9]) ;;
  *) log "⚠ Public self-hosted asset $PUB_ASSET returned HTTP $ACODE — a vendored /libs/ file may be missing or misconfigured" ;;
esac

# --- the tunnel connector can be running AND serving nobody -------------------
# 30 Oct 2026, 08:44 local: `cloudflared` was `active`, its process healthy, the
# wake front door answered 200 on 127.0.0.1:5174 — and build/play/tchat.tukuk.org all
# served 530 (error code 1033, "no connector available"). The edge had dropped all four
# registrations at 00:22Z; the connector logged "Registered tunnel connection" after that
# and the dashboard still showed 0 connections, so nothing was wedged locally — it needed
# a fresh hello. `systemctl is-active` cannot see this state at all, which is why the
# public code is the instrument: 530 means the request never reached the box, so ONLY
# re-registering helps. 502 deliberately does NOT: that means the connector delivered the
# request and the ORIGIN failed, which the checks below handle. Restarts are stamped to
# one per 30 minutes so a genuinely gone tunnel cannot put the unit in a restart loop.
# One tunnel serves every hostname now, so two hostnames can report the SAME fault and
# the fix is one restart of one unit: the gate below is per UNIT, not per hostname.
probe_local() { # $1 = port → echoes the HTTP code of the origin that connector fronts
  local c; c=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:$1/" 2>/dev/null); echo "${c:-000}";
}
re_register() { # $1 = public url, $2 = local port, $3 = unit, $4 = stamp file
  local code lcode gate
  gate="/tmp/tukuk-os-watchdog.${3%%.*}.gate"
  code=$(probe_edge "$1"); lcode=$(probe_local "$2")
  if [ "$code" = "530" ] && [ "$lcode" = "200" ]; then
    # The gate is per unit, so two hostnames reporting the same dead registration cause
    # ONE restart. Without it the second call would restart the connector again seconds
    # after the first, resetting the very handshake the first restart was making.
    if [ -f "$gate" ] && [ -n "$(find "$gate" -mmin -30 2>/dev/null)" ]; then return 0; fi
    if [ ! -f "$4" ] || [ -n "$(find "$4" -mmin +30 2>/dev/null)" ]; then
      log "🚇 $1 gives HTTP 530 while 127.0.0.1:$2 answers 200 — $3 lost its edge registrations; restarting the unit to re-register (no config or credential touched)"
      touch "$4" "$gate"
      systemctl restart "$3" || log "could not restart $3"
    fi
  elif [ "$code" = "200" ] && [ -f "$4" ]; then
    log "$1 answering 200 again — $3 re-registered"
    rm -f "$4"
  fi
}
re_register "${WATCHDOG_BUILD_URL:-https://build.tukuk.org/}" 5174 cloudflared.service /tmp/tukuk-os-watchdog.buildtunnel
re_register "${WATCHDOG_MAIN_URL:-https://tukuk.org/}"          3000 cloudflared.service /tmp/tukuk-os-watchdog.maintunnel

# --- 5. did the auto-update actually run? --------------------------------------
# The update is silent by design, so a timer that died in March looks exactly like
# "nothing to do": a wedged fetch sat in the oneshot unit for 31 hours on 24 Oct 2026
# and nothing anywhere said so. /health carries the last attempt now, and this is the only
# thing that reads it. One nudge per six hours — a stale record means the last run never
# finished, and starting it every two minutes would only pile up attempts.
UPD_STAMP="/tmp/tukuk-os-watchdog.update"
HEALTH_JSON="$(curl -sf -m 10 "$URL" 2>/dev/null || true)"
if [ -n "$HEALTH_JSON" ]; then
  UPD_STATE="$(printf '%s' "$HEALTH_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const u=JSON.parse(s).update;if(!u){process.stdout.write("none");return}process.stdout.write((u.stale?"stale":"fresh")+" "+(u.ageSeconds===null?"?":u.ageSeconds)+"s "+(u.stage||"?"))}catch{process.stdout.write("unknown")}})' 2>/dev/null)"
  case "$UPD_STATE" in
    stale*)
      if [ ! -f "$UPD_STAMP" ] || [ -n "$(find "$UPD_STAMP" -mmin +360 2>/dev/null)" ]; then
        log "Auto-update looks stale ($UPD_STATE) — starting tukuk-update.service"
        systemctl start --no-block tukuk-update.service || log "could not start tukuk-update.service"
        touch "$UPD_STAMP"
      fi
      ;;
    unknown)
      if [ ! -f "$UPD_STAMP" ] || [ -n "$(find "$UPD_STAMP" -mmin +1440 2>/dev/null)" ]; then
        log "Update record is present but unreadable — check src/update-status.js and data/update-status.json"
        touch "$UPD_STAMP"
      fi
      ;;
  esac
fi

if ! systemctl is-active --quiet "$APP"; then
  log "Search engine not active — start"
  systemctl start "$APP"
  rm -f "$STAMP"
  exit 0
fi

if curl -sf -m 10 -o /dev/null "$URL"; then
  if [ -f "$STAMP" ]; then
    log "Healthy again after $(cat "$STAMP") consecutive failures"
    rm -f "$STAMP"
  fi
  exit 0
fi

COUNT=$(cat "$STAMP" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$STAMP"
log "Health check failed (attempt $COUNT/$THRESHOLD): $URL"

if [ "$COUNT" -ge "$THRESHOLD" ]; then
  log "Threshold exceeded — restart $APP"
  systemctl restart "$APP"
  rm -f "$STAMP"
fi

exit 0