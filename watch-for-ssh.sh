#!/usr/bin/env bash
# ==============================================================================
# watch-for-ssh.sh — wait for the server's SSH to come back, then finish the job.
#
# WHY THIS EXISTS: the box at 192.168.8.100 answers `Connection refused` on 22 —
# the machine is up and serving tukuk.org through the Cloudflare Tunnel, but sshd
# is not running, and neither is cockpit.socket. Nothing on the public side can
# start them, so the only repair is the one already pushed to GitHub (c33e394):
# the box pulls on its daily timer, and ~2 minutes later scripts/watchdog.sh runs
# scripts/selfheal-access.sh, which starts both units.
#
# That happens without anyone at a keyboard — but nobody is watching for it, and
# the Builder rebuild still has to follow. So this waits for the port, then does
# the part that still needs doing. Nothing for the owner to remember or run.
#
#   nohup setsid bash scripts/watch-for-ssh.sh >> .artifacts/tukuk-watch.log 2>&1 &
#   TUKUK_HOST=192.168.8.100 WATCH_DEADLINE=3600 bash scripts/watch-for-ssh.sh
#
# The address comes from the ssh alias rather than a constant: DHCP has moved this
# box before, and a stale hardcoded IP is exactly how a deploy "succeeded" against
# the wrong device.
# ==============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

BOX="${TUKUK_HOST:-$(ssh -G tukuk-vps 2>/dev/null | awk '/^hostname /{print $2}')}"
if [ -z "$BOX" ]; then
  echo "✗ cannot find the box: no TUKUK_HOST and no 'tukuk-vps' Host in ~/.ssh/config" >&2
  exit 1
fi

POLL="${WATCH_POLL:-60}"                 # seconds between probes
DEADLINE="${WATCH_DEADLINE:-72000}"      # 20 h: daily pull at 07:04 plus generous headroom
QUIET_EVERY="${WATCH_QUIET:-30}"         # minutes between "still waiting" lines
COMMIT="${WATCH_COMMIT:-c33e394}"        # what the box has to pull to repair itself

say() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Distinguish the two failure modes, because they mean different things:
# refused  = machine up, sshd not running      → repair is pending, keep waiting
# filtered = machine up, something drops 22    → firewall, waiting will not help
state() {
  local out rc
  out="$(timeout 4 bash -c "exec 3<>/dev/tcp/${BOX}/22" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo open; return 0; fi
  if printf '%s' "$out" | grep -qi refused; then echo "refused (sshd not running)"; else echo "filtered (dropped)"; fi
}

say "watching ${BOX}:22 every ${POLL}s, giving up after $((DEADLINE / 3600))h"
say "  now: $(state) — waiting for the box to pull ${COMMIT} and repair itself"

opened=0
end=$(( $(date +%s) + DEADLINE ))
last_quiet=0
while [ "$(date +%s)" -lt "$end" ]; do
  if timeout 4 bash -c "exec 3<>/dev/tcp/${BOX}/22" 2>/dev/null; then
    opened=1
    say "✓ ${BOX}:22 is accepting connections — SSH is back."
    break
  fi
  now=$(date +%s)
  if [ $((now - last_quiet)) -ge $((QUIET_EVERY * 60)) ]; then
    say "still waiting — ${BOX}:22 $(state)"
    last_quiet=$now
  fi
  sleep "$POLL"
done

if [ "$opened" -ne 1 ]; then
  say "✗ gave up: ${BOX}:22 never opened."
  say "  the self-heal did not land. Read: curl -s https://tukuk.org/health | grep -o '\"update\":[^}]*}'"
  say "  if stage says merge-failed the box has local edits and needs someone at the machine."
  exit 1
fi

# Cockpit too, because that is the console the owner was reaching for.
if timeout 4 bash -c "exec 3<>/dev/tcp/${BOX}/9090" 2>/dev/null; then
  say "  ${BOX}:9090 is up as well — Cockpit console reachable at http://${BOX}:9090"
else
  say "  ${BOX}:9090 still closed — SSH works, so cockpit can be started from there"
fi

say "running the Builder deploy automatically (this is the part that fixes the crash)"
if TUKUK_HOST="$BOX" bash scripts/deploy-builder.sh; then
  say "✓ deployed and publicly verified — https://build.tukuk.org is serving the fixed bundle"
  exit 0
fi
say "✗ the deploy ran but public verification FAILED — scroll up in this log for which check"
exit 1
