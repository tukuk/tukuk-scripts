#!/usr/bin/env bash
# ── weight-report: what is actually making this box heavy, measured, not guessed ──────────
#
# WHY THIS EXISTS. Asked "what other systems can make the server lighter", the honest first
# answer is that nobody could say, because the numbers were never in one place. The guesses that
# the measurements then threw out, on 23 Oct 2026:
#   * "nginx should serve the static files itself" — 0 requests for a static-extension path in
#     20,000 log lines. There was nothing to offload.
#   * "a longer cache lease would help" — 1,934 of 2,038 distinct URLs were asked for exactly
#     once, so a longer TTL can only ever save the other 862 requests.
#   * "the box needs memory" — 4.7 GB available, load 0.06 on 4 cores, swap untouched.
# What the box really spends is TAIL LATENCY: 25 requests of 2,845 (0.9%) burned 283.9 of the
# 1,506 request-seconds (19%). That number is the whole reason src/outbound.js exists, and it is
# the first line this script prints, because it is the number a change has to move.
#
# READ-ONLY. Nothing here stops, deletes or reconfigures anything: a monitor that acts is a
# second problem to debug (the same rule that keeps the load governor read-only). It is also
# deliberately journal-only and never public — server internals must not reach a page or an API.
#
#   bash scripts/weight-report.sh              # human report, to stdout
#   bash scripts/weight-report.sh --tail 40000 # bigger log window for the latency sections
set -uo pipefail

L=${L:-/var/log/nginx/tukuk-front.log}
H=${H:-http://127.0.0.1:3000/health}
TAIL=${TAIL:-20000}
while [ $# -gt 0 ]; do
  case "$1" in
    --tail) TAIL=${2:-20000}; shift 2 ;;
    *) echo "weight-report: unknown argument '$1' (only --tail N)"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
mb() { echo $(($1 / 1048576)); }

say "═══ tukuk-os weight report — $(date -Is) — uptime$(uptime -p 2>/dev/null | sed 's/^up//') ═══"

# ── 1. the headline: where the request-seconds went ────────────────────────────────────────
say ""
say "── 1. request time, and the tail that spends it"
if [ -r "$L" ]; then
  # What period these numbers actually cover, printed first: the window is the last N lines, so
  # after a quiet night it reaches back a day, and after a crawler burst only an hour. Guessing
  # that from the line count is exactly the kind of unmeasured claim this report replaces.
  tail -n "$TAIL" "$L" | awk 'NR==1 { f = substr($2, 2) } { l = substr($2, 2) }
    END { sub(/\]/, "", f); sub(/\]/, "", l); printf "   window: %s lines, %s -> %s\n", NR, f, l }' | sed 's/^/ /'
  tail -n "$TAIL" "$L" | awk '
    { rt = 0; for (i = 1; i <= NF; i++) if ($i ~ /^rt=/) { v = $i; sub("rt=", "", v); rt = v + 0 }
      if (rt <= 0) next
      n++; total += rt
      if (rt < 0.05) b1++; else if (rt < 0.2) b2++; else if (rt < 1) b3++; else if (rt < 5) b4++; else { b5++; slown++; slowsec += rt }
    }
    END {
      if (n == 0) { print "  (no rt= samples in the window)"; exit }
      printf "  %d requests the box actually worked on (rt=0 cache hits excluded) held it %.1f s, mean %.3fs\n", n, total, total / n
      printf "  <50ms %d   50-200ms %d   0.2-1s %d   1-5s %d   >5s %d\n", b1, b2, b3, b4, b5
      if (slown) printf "  THE TAIL: %d requests (%.1f%%) burned %.1f s = %.1f%% of all request-seconds\n", \
        slown, slown * 100 / n, slowsec, slowsec * 100 / total
      else print "  THE TAIL: nothing over 5 s — the box is answering promptly"
    }' | sed 's/^/ /'
  say "  --- the ten slowest in the window (these are the ones to fix) ---"
  tail -n "$TAIL" "$L" | awk '{ rt = 0; for (i = 1; i <= NF; i++) if ($i ~ /^rt=/) { v = $i; sub("rt=", "", v); rt = v + 0 }
      split($0, a, "\""); st = ""; for (i = 1; i <= NF; i++) if ($i ~ /^status=/) st = $i
      if (rt > 0) printf "%.3f\t%s\t%s\n", rt, a[2], st }' | sort -rn | head -10 | sed 's/^/   /'
  say "  --- which family of pages holds the seconds (top 8 by total rt) ---"
  tail -n "$TAIL" "$L" | awk '{ rt = 0; for (i = 1; i <= NF; i++) if ($i ~ /^rt=/) { v = $i; sub("rt=", "", v); rt = v + 0 }
      f = $4; sub(/\?.*/, "", f); m = split(f, p, "/"); fam = p[2] == "" ? "/" : "/" p[2]
      s[fam] += rt; c[fam]++ }
      END { for (k in s) if (s[k] > 1) printf "%8.1f s over %5d requests  %s\n", s[k], c[k], k }' | sort -rn | head -8 | sed 's/^/   /'
else
  say "  (no $L — is nginx front still configured?)"
fi

# ── 2. the shared cache, and whether it is earning its keep ────────────────────────────────
say ""
say "── 2. the proxy cache (a MISS here is a render the box had to do again)"
if [ -r "$L" ]; then
  tail -n "$TAIL" "$L" | grep -oE 'cache=[A-Z-]+' | sort | uniq -c | sort -rn | awk '
    { out = out sprintf("  %6d %s", $1, substr($2, 7)) }
    END { print out; }' | sed 's/^/ /'
  say "  --- (- means the location has proxy_cache off entirely: /health, /api, /radio, /agent) ---"
  tail -n "$TAIL" "$L" | grep -oE 'cache=[A-Z-]+' | sort | uniq -c | awk '
    { tot += $1; if ($2 == "cache=HIT") hit = $1 }
    END { if (tot) printf "  hit ratio %.1f%% of %d requests\n", hit * 100 / tot, tot }' | sed 's/^/ /'
  say "  --- requests per hour of day (this is what the report timer's hour should be read against) ---"
  tail -n "$TAIL" "$L" | grep -oE 'T[0-9]{2}:' | cut -c2-3 | sort | uniq -c | awk '
    { printf "%s:%s ", $2, $1 } END { print "" }' | fold -w 76 | sed 's/^/   /'
  # Kept because it is a NEGATIVE result worth re-checking: the first survey found zero, which is
  # why nginx does not serve files directly. If this ever stops being ~0, static offload is real.
  # `.json` is deliberately NOT in the list: 186 of the window's file-looking paths are
  # /nasa/iss/live.json, which is a polling APP route on purpose no-store, not a file on disk.
  # Counting it would make this line look like a big win every time the ISS page is open.
  say "  --- requests for a static-file path (nginx serving these itself only pays off above ~0) ---"
  tail -n "$TAIL" "$L" | grep -oE '"(GET|POST) [^"]*' | grep -cE '\.(png|jpg|jpeg|svg|webp|ico|css|js|apk|woff2?)([?" ]|$)' | sed 's/^/   static-file requests: /'
fi

# ── 3. the outbound guard: is a deadline or a cooldown actually firing? ─────────────────────
say ""
say "── 3. upstream calls, per module (src/outbound.js counters via /health)"
HEALTH=$(curl -fsS -m 5 "$H" 2>/dev/null || true)
if [ -z "$HEALTH" ]; then
  say "   (could not read $H — is tukuk-os up, and is that the nginx front port?)"
else
  printf '%s' "$HEALTH" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d.get("outbound") or []
if not rows:
    print("  (no `outbound` key in /health — the guard is not deployed yet)")
else:
    print("   %-13s %8s %8s %7s %7s %9s %7s" % ("module", "through", "deduped", "cooled", "queued", "deadline", "failed"))
    for r in sorted(rows, key=lambda x: -x["through"]):
        print("   %-13s %8d %8d %7d %7d %9d %7d" % (r["name"], r["through"], r["deduped"],
              r["cooled"], r["queued"], r["deadline"], r["failed"]))
    print("   (deadline/failed > 0 means the guard is doing work; all zero on a healthy day is correct)")
' | sed 's/^/ /'
fi

# ── 4. memory, honestly ────────────────────────────────────────────────────────────────────
say ""
say "── 4. memory"
free -m | awk 'NR==2{printf "   total %s MB, used %s MB, AVAILABLE %s MB\n", $2, $3, $7} NR==3 && $2>0 {printf "   swap used %s MB\n", $3}'
# MemoryCurrent counts page cache charged to the cgroup, which for a service reading big files
# looks alarming and is reclaimable. `anon` in memory.stat is the memory the box cannot take
# back, so that is the column this report sorts by. Path is /sys/fs/cgroup + ControlGroup.
for u in $(systemctl list-units --type=service --state=active --no-legend --no-pager | awk '{print $1}'); do
  cg=$(systemctl show "$u" -p ControlGroup --value 2>/dev/null)
  [ -n "$cg" ] || continue
  a=$(awk '/^anon /{print $2}' "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null || echo 0)
  s=$(systemctl show "$u" -p MemoryCurrent --value 2>/dev/null || echo 0)
  [ "${a:-0}" -gt 20971520 ] && printf "  %6s MB anon (%6s MB charged)  %s\n" "$(mb "$a")" "$(mb "$s")" "$u"
done | sort -rn | head -14 | sed 's/^/ /'

# ── 5. disk ───────────────────────────────────────────────────────────────────────────────
say ""
say "── 5. disk"
df -h / | awk 'NR==2{printf "   root: %s used of %s (%s), %s free\n", $3, $2, $5, $4}'
for d in /opt/tukuk-os/node_modules /opt/tukuk-os/.git /opt/tukuk-os/generated /opt/tukuk-os/data \
         /opt/tukuk-os/content /var/log /var/log/journal /var/cache/nginx /var/lib/meilisearch /snap; do
  [ -e "$d" ] && du -sh "$d" 2>/dev/null
done | sort -h | tail -9 | sed 's/^/  /'

# ── 6. background work ─────────────────────────────────────────────────────────────────────
say ""
say "── 6. timers that fire without being asked"
systemctl list-timers --no-legend --no-pager 2>/dev/null | sed 's/  */ /g; s/^/   /' | head -14

say ""
say "   (read-only report — it changes nothing. Sections 1 and 3 are the ones a fix must move.)"
exit 0
