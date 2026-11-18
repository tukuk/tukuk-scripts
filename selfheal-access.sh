#!/usr/bin/env bash
# ==============================================================================
# selfheal-access.sh — make sure the owner can ALWAYS get back into this box.
#
# WHY THIS EXISTS: on 29 Oct 2026 the site was perfectly healthy (HTTP 200 through
# the tunnel, /health reporting ok) while the owner was locked out of his own
# machine: sshd dropped every SYN and cockpit.socket answered `refused` on the
# box's current address. Neither failure needs the box to be broken —
#   * cockpit.socket is bound to the addresses the box had AT BOOT
#     (deploy/cockpit-lan-socket.sh), so a DHCP lease change leaves it listening
#     on an address that no longer exists: `systemctl is-active` says active,
#     every connection is refused.
#   * the firewall's `allow 22` can disappear from a ufw reset/reload while every
#     other rule survives, which turns a reachable sshd into silent packet drops
#     (a timeout, not "connection refused").
# Both are invisible from the public side because cloudflared only connects
# OUTBOUND — the tunnel keeps the site up while the management plane is gone.
#
# So: re-derive the address, re-assert the units, re-open the LAN. Safe by
# design — it only ADDS access paths (start/enable a unit, allow the LAN), never
# removes one, and every step is idempotent so it can run on a schedule.
#
#   sudo bash scripts/selfheal-access.sh      # at the console
#   scripts/watchdog.sh                       # every 2 min, only when missing
# ==============================================================================
set -uo pipefail

say() { printf '[selfheal] %s\n' "$*"; }
warn() { printf '[selfheal] ⚠ %s\n' "$*" >&2; }

# Root is needed for systemctl/ufw. A non-root caller (the app runs as its own
# user) must not silently pretend it fixed anything.
if [[ "${EUID}" -ne 0 ]]; then
  say "not root — nothing changed. Run: sudo bash $0"
  exit 0
fi

REPO="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
fails=0

# --- the LAN prefixes this box actually has right now ------------------------
# `ip route show scope link` already carries the real prefix length, so a box on
# a /16 is described correctly instead of being guessed as /24.
declare -a NETS=()
while IFS= read -r net; do
  [[ -n "$net" ]] || continue
  # Never widen access to the whole internet: a 0-length prefix is not a LAN.
  [[ "$net" == "0.0.0.0/0" || "$net" == "default" ]] && continue
  NETS+=("$net")
done < <(ip -4 route show scope link 2>/dev/null | awk '$1 ~ /\/[0-9]+$/ {print $1}' | sort -u)

# --- 1. ssh ------------------------------------------------------------------
# Why `systemctl list-unit-files | grep -q …` is not a working existence test — this script is the
# evidence. list-unit-files emits several hundred lines, `grep -q` exits the instant it matches, and
# systemctl then dies of SIGPIPE; under `set -o pipefail` the PIPELINE returns 141 even though the
# pattern matched. Measured on the box on 2026-11-01:
#     … | grep -qE '^cockpit[.]socket'          -> rc 141  (the if took the ELSE branch)
#     … | grep -E  '^cockpit[.]socket' >/dev/null -> rc 0
#     systemctl cat cockpit.socket              -> rc 0
# So the owner's access monitor reported "no ssh/sshd unit found" and "no cockpit.socket unit found"
# on a box whose very next line printed `listening: ssh(22)=yes cockpit(9090)=yes`, and none of the
# enable/start calls inside those then-branches ever ran, because the else-branch is where they live
# and it only warns. A monitor that cries wolf is how a real lockout gets ignored, and this is the
# one script whose whole job is that the owner can log in.
# `systemctl cat` resolves a unit by exact name, needs no filtering, and exits 1 only when the unit
# genuinely does not exist — the same primitive deploy/lighten-server.sh had to move to (README §12).
has_unit() { systemctl cat "$1" >/dev/null 2>&1; }

# ssh.service (Debian/Ubuntu) and sshd.service (Fedora/Arch) are one daemon under two names, and
# Ubuntu 24.04+ ships SOCKET ACTIVATION: this box runs ssh.socket enabled with ssh.service
# deliberately disabled, which is the correct modern setup. So the socket is preferred, and only the
# unit that is actually the boot-time enabler is enabled — forcing ssh.service on would move a
# working box from on-demand to always-running sshd for no reason.
SSH_UNIT=""
for u in ssh.socket ssh.service sshd.socket sshd.service; do
  if has_unit "$u"; then SSH_UNIT="$u"; break; fi
done
if [[ -n "$SSH_UNIT" ]]; then
  systemctl enable "$SSH_UNIT" >/dev/null 2>&1 || warn "could not enable $SSH_UNIT"
  if systemctl is-active --quiet "$SSH_UNIT"; then
    :
  elif systemctl start "$SSH_UNIT" >/dev/null 2>&1; then
    say "started $SSH_UNIT"
  else
    warn "FAILED to start $SSH_UNIT — check: journalctl -u $SSH_UNIT -n 40"
    fails=$((fails + 1))
  fi
else
  warn "no ssh/sshd unit found — OpenSSH server may not be installed (apt install openssh-server)"
  fails=$((fails + 1))
fi

# --- 2. cockpit --------------------------------------------------------------
# Re-derive the bind addresses BEFORE starting the socket, otherwise the socket
# comes back up on the same dead address it was refusing on.
if [[ -n "$REPO" && -f "$REPO/deploy/cockpit-lan-socket.sh" ]]; then
  bash "$REPO/deploy/cockpit-lan-socket.sh" 2>&1 | while IFS= read -r line; do say "$line"; done
elif command -v cockpit-ws >/dev/null 2>&1; then
  warn "cockpit-lan-socket.sh not found at $REPO/deploy — the socket may stay on a stale address"
fi

if has_unit cockpit.socket; then
  # enable, not merely start: the owner opens this console in a browser, so a unit that is
  # running-but-disabled dies on the next reboot and he is standing outside with no way in. That is
  # exactly how cockpit went missing on 2026-10-31 — deploy/lighten-server.sh disabled it, and the
  # SIGPIPE test above meant this branch never noticed, let alone re-enabled it.
  if ! systemctl is-enabled --quiet cockpit.socket 2>/dev/null; then
    systemctl enable cockpit.socket >/dev/null 2>&1 \
      && say "enabled cockpit.socket" \
      || warn "could not enable cockpit.socket"
  fi
  if ! systemctl is-active --quiet cockpit.socket; then
    systemctl start cockpit.socket >/dev/null 2>&1 \
      || { warn "FAILED to start cockpit.socket — check: journalctl -u cockpit.socket -n 40"; fails=$((fails + 1)); }
  fi
else
  warn "no cockpit.socket unit found — Cockpit may not be installed"
fi

# --- 3. firewall: let the LAN back in ---------------------------------------
# Only when a firewall is actually enforcing something. ufw is idempotent
# ("Skipping adding existing rule"), so re-running this every cycle is harmless.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  if [[ "${#NETS[@]}" -eq 0 ]]; then
    warn "ufw is active but the box has no LAN prefix — skipping firewall changes"
  else
    for net in "${NETS[@]}"; do
      for port in 22 9090; do
        ufw allow from "$net" to any port "$port" proto tcp >/dev/null 2>&1 \
          || warn "ufw allow from $net to $port failed"
      done
    done
    say "ufw: allow 22,9090/tcp from ${NETS[*]}"
  fi
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  # The cockpit service is what opens 9090 on Fedora-family boxes.
  firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-service=cockpit >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || warn "firewall-cmd --reload failed"
  say "firewalld: ssh + cockpit allowed for the default zone"
fi

# --- 4. report what is actually listening ------------------------------------
# Listening state, not unit state: that distinction is the entire point of this
# script — cockpit.socket reported `active` while refusing every connection.
listen() { ss -ltn 2>/dev/null | grep -E "[:.]$1[[:space:]]" >/dev/null && echo yes || echo no; }
SSH_UP="$(listen 22)"
COCKPIT_UP="$(listen 9090)"
ADDRS="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"

say "listening: ssh(22)=$SSH_UP cockpit(9090)=$COCKPIT_UP"
say "connect to: ${ADDRS:-<no global IPv4 — check the cable/cable-or-wifi>}"

if [[ "$SSH_UP" != "yes" ]]; then
  warn "sshd is still NOT listening on 22 — a firewall blocking it would show as a timeout, not a refusal"
  fails=$((fails + 1))
fi
if [[ "$COCKPIT_UP" != "yes" ]]; then
  warn "nothing is listening on 9090 — cockpit.socket bound only to 127.0.0.1 makes it console-only"
  fails=$((fails + 1))
fi

# --- 5. the console must ANSWER, not merely listen ----------------------------
# "A listener exists" was never the owner's question. His question is "can I open this in a
# browser", and the two are not the same: on 2026-10-31 cockpit.socket held fds on
# CloudflareWARP's tunnel address among others, and a listener no client can route to is the same
# lockout wearing a different hat. So probe every address the drop-in itself claims and require the
# login page over TLS. `/login` answers 200 UNAUTHENTICATED — that is the page he lands on; the 401
# belongs to /cockpit/login, the package endpoint, and checking that would pass on a console whose
# login page cannot be opened (the same trap scripts/rebuild-from-offsite.sh already documents).
# The drop-in is the source of truth rather than `ip`, because the failure being guarded against is
# precisely a disagreement between the two.
DROPIN="${COCKPIT_DROPIN:-/etc/systemd/system/cockpit.socket.d/40-lan-only.conf}"
if [[ "$COCKPIT_UP" == "yes" && -f "$DROPIN" ]]; then
  while IFS= read -r caddr; do
    [[ -n "$caddr" ]] || continue
    ccode=$(curl -sk -m 6 -o /dev/null -w '%{http_code}' "https://${caddr}:9090/login" 2>/dev/null)
    case "${ccode:-000}" in
      2[0-9][0-9]) say "cockpit answers HTTP ${ccode} on ${caddr}:9090" ;;
      *) warn "cockpit does NOT answer on ${caddr}:9090 (HTTP ${ccode:-000}) — the owner cannot log in there"
         fails=$((fails + 1)) ;;
    esac
  done < <(sed -n 's/^ListenStream=\([0-9][0-9.]*\):9090$/\1/p' "$DROPIN")
fi

[[ "$fails" -eq 0 ]] && say "access restored — sshd up and the cockpit console answers." || warn "$fails check(s) still failing — see above."
exit 0
