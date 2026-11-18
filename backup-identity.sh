#!/usr/bin/env bash
# ==============================================================================
# backup-identity.sh — the off-box copy of everything that cannot be rebuilt.
#
# The other tracks already cover the recoverable things: data/ hourly, the
# search index and chat every 6h, a static mirror of the site every 6h, and the
# source on GitHub. None of them cover this box's IDENTITY: the cloudflared tunnel
# credential, the cert.pem that authorises `tunnel route dns`, .env, the
# nginx and systemd units, the SSH host keys and authorized_keys.
#
# Those are the files that turn "the disk died" from an outage into a permanent
# loss. A tunnel credential exists only in /etc/cloudflared and in the
# Cloudflare dashboard -- with it gone, a brand-new server with every byte of
# content restored still cannot be pointed at tukuk.org.
#
# NOTHING LEAVES UNENCRYPTED. The tarball is AES-256/PBKDF2 with the passphrase
# in /root/tukuk-backup-key (0400). That passphrase is the only thing between
# whoever reads the bucket and your API tokens, so it must live somewhere other
# than this server; the laptop keeps a copy at ~/.config/tukuk/backup-key.
#
# ROTATION: day-of-month slot, 31 slots, the same no-delete-API trick as
# backup-data.sh -- a month of history without needing bucket delete scope.
#
# USE:     sudo bash scripts/backup-identity.sh        (daily 04:40 timer)
# RESTORE: sudo bash scripts/restore-identity.sh [DD]  (verify + stage; --apply to install)
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../deploy/paths.sh
. ./deploy/paths.sh

WURL="${BACKUP_WORKER_URL:-}"
WSEC="${BACKUP_UPLOAD_SECRET:-}"
KEYFILE="${IDENTITY_KEY_FILE:-/root/tukuk-backup-key}"
BUCKET="${R2_BUCKET:-tukuk-fallback}"
DAY="$(date -u +%d)"
KEY="backups/tukuk-identity-$DAY.tar.gz.enc"
# A human running this at 3am will not have the timer's EnvironmentFile loaded,
# so read it ourselves instead of failing on unset variables.
if [[ -z "$WURL" || -n "${BACKUP_UPLOAD_SECRET:-}" && -z "$WSEC" ]] || [[ -z "$WURL" || -z "$WSEC" ]]; then
  ENVF="${TUKUK_ENV_FILE:-/opt/tukuk-os/.env}"
  if [[ -r "$ENVF" ]]; then
    # Read the two keys we need rather than sourcing the file. Sourcing runs it
    # as shell, and this .env has values with spaces (`WEBAUTHN_RP_NAME=Tukuk
    # Passkey`), which bash parses as "assign, then execute `Passkey` as a
    # command". The error is only hidden by 2>/dev/null, and whether the rest of
    # the file survives to define BACKUP_WORKER_URL depends on the shell options
    # in force -- which is not something an emergency restore should gamble on.
    # Values are taken whole after the first `=`, exactly as systemd does.
    _env_get() { grep -E "^[[:space:]]*$1=" "$ENVF" | tail -1 | cut -d= -f2- | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" -e 's/^"//' -e 's/"$//'; }
    WURL="${WURL:-$(_env_get BACKUP_WORKER_URL)}"
    WSEC="${WSEC:-$(_env_get BACKUP_UPLOAD_SECRET)}"
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A missing destination or key is an ERROR here, not a silent skip like the data
# track: this is the backup nobody thinks to look for until the machine is gone.
# Two destinations count: the upload Worker (WURL+WSEC) or R2 direct (a token with
# Account · R2 Storage · Read & Edit). Since 31 Oct 2026 the live account has no
# `tukuk-backup` worker at all, so on the rebuilt box the R2 branch is the PRIMARY
# path, not a fallback -- blanking the dead URL must not cost the identity copy.
if [[ -z "$WURL" || -z "$WSEC" ]] && [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "[identity] ERROR: no destination — set BACKUP_WORKER_URL + BACKUP_UPLOAD_SECRET, or CLOUDFLARE_API_TOKEN with R2:Edit." >&2; exit 1
fi
[[ -r "$KEYFILE" ]] || { echo "[identity] ERROR: $KEYFILE unreadable -- refusing to put your secrets in a bucket unencrypted." >&2; exit 1; }

# Relative to / so the archive unpacks onto the same absolute layout.
PATHS=(
  etc/cloudflared
  etc/nginx
  etc/systemd/system
  etc/ssh
  etc/netplan
  etc/hosts
  etc/resolv.conf
  etc/timezone
  etc/crontab
  home/tukuk/.cloudflared
  home/tukuk/.ssh
  home/tukuk/gt
  opt/tukuk-os/.env
  # The signing keystore. .gitignore holds `apk/*.jks` and `apk/keystore.env`, and no
  # other track archives them — backup-data.sh only tars data/ — so this is the ONLY
  # off-box copy of the key that signs every published Tukuk app. Lose it and existing
  # installs can never receive an update: the store rejects a signature mismatch, and
  # users would have to uninstall and reinstall. Absent on a box that never built an
  # APK, which the WARN loop below reports and skips.
  opt/tukuk-os/apk/tukuk-chat-release.jks
  opt/tukuk-os/apk/keystore.env
)
PRESENT=()
for p in "${PATHS[@]}"; do
  if [[ -e "/$p" ]]; then PRESENT+=("$p"); else echo "[identity] WARN: /$p absent -- skipped" >&2; fi
done
[[ ${#PRESENT[@]} -gt 0 ]] || { echo "[identity] ERROR: none of the expected paths exist." >&2; exit 1; }

# --------------------------------------------------------------------------------
# Manifest: enough that a rebuild can be done from the archive alone, and a
# checksum per file so a restore can prove what it actually unpacked.
# --------------------------------------------------------------------------------
M="$TMP/manifest"
mkdir -p "$M"
{
  date -u +"created=%FT%TZ"; echo "hostname=$(hostname)"; uname -a
  echo "node=$(node -v 2>/dev/null)"
  echo "cloudflared=$(cloudflared --version 2>/dev/null | head -1)"
  echo "openssl=$(openssl version)"
  echo "tukuk-os HEAD=$(git -C /opt/tukuk-os rev-parse HEAD 2>/dev/null)"
  echo "station-break HEAD=$(git -C "$TUKUK_GAME_DIR" rev-parse HEAD 2>/dev/null)"
  echo; echo "--- timers as installed:"; systemctl list-timers --all --no-pager 2>/dev/null | head -30
  echo; echo "--- listening sockets:"; ss -ltnp 2>/dev/null | head -25
  echo; echo "--- interfaces:"; ip -br a 2>/dev/null
  echo; echo "--- published game files:"; ls -l "$TUKUK_PLAY_DIR" 2>/dev/null
} > "$M/system.txt" 2>&1
dpkg -l > "$M/packages.txt" 2>/dev/null
crontab -l -u root  > "$M/crontab-root.txt"  2>/dev/null
crontab -l -u tukuk > "$M/crontab-tukuk.txt" 2>/dev/null
ls -R /var/www      > "$M/var-www-listing.txt" 2>/dev/null
( for p in "${PRESENT[@]}"; do find "/$p" -type f -readable -print0 2>/dev/null; done \
  | xargs -0 -r sha256sum ) > "$M/checksums.txt" 2>/dev/null
echo "[identity] manifest lists $(wc -l < "$M/checksums.txt") files, $(du -h "$M/checksums.txt" | cut -f1) of checksums"

echo "[identity] packing ${#PRESENT[@]} trees ..."
tar cf "$TMP/identity.tar" -C / "${PRESENT[@]}" 2>/dev/null || { echo "[identity] ERROR: tar failed" >&2; exit 1; }
tar rf "$TMP/identity.tar" -C "$TMP" manifest
gzip -n "$TMP/identity.tar"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$TMP/identity.tar.gz" -out "$TMP/identity.enc" -pass "file:$KEYFILE" \
  || { echo "[identity] ERROR: encryption failed" >&2; exit 1; }
SIZE="$(du -h "$TMP/identity.enc" | cut -f1)"
echo "[identity] encrypted to $SIZE, sha256 $(sha256sum "$TMP/identity.enc" | cut -c1-16)..."

echo "[identity] sending $KEY ($SIZE) to R2 ..."
ATTEMPTS=0
# Same reasoning as backup-data.sh: leave the finished object on disk so the
# second-provider job mirrors a stable file rather than re-taring /etc while
# services are running.
KEEP=/var/backups/tukuk-identity-latest.tar.gz.enc
cp "$TMP/identity.enc" "$KEEP.part" && mv -f "$KEEP.part" "$KEEP" \
  && chmod 600 "$KEEP" \
  || echo "[identity] WARN: could not retain $KEEP" >&2

if [[ -z "$WURL" || -z "$WSEC" ]]; then
  # No worker path at all -> straight to R2 with the token. Zero Worker requests, which
  # is the point: the account's free Worker cap is what made this track fail before.
  if npx --yes wrangler r2 object put "$BUCKET/$KEY" --file "$TMP/identity.enc" --remote >/dev/null 2>&1; then
    echo "[identity] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [wrangler]"
    exit 0
  fi
  echo "[identity] ERROR: R2 direct put failed for $KEY — the archive stays on this box at $KEEP" >&2
  exit 1
fi
RBODY="$(mktemp)"
# Status via -w, page via -o, no -f: `curl -f` discards the error body, and the body is
# the only thing that distinguishes the account's daily free Worker request cap
# ('error code: 1027', reset at 00:00 UTC, immune to retries) from plain congestion
# (clears in seconds, worth backing off for). See backup-data.sh for the same reasoning.
while :; do
  RCODE="$(curl -sS --max-time 180 -o "$RBODY" -w '%{http_code}' -X POST \
     -H "Authorization: Bearer $WSEC" -H "x-content-type: application/octet-stream" \
     --data-binary "@$TMP/identity.enc" "$WURL/?key=$KEY" 2>/dev/null || echo 000)"
  [[ "$RCODE" =~ ^2 ]] && break
  if grep -q "error code: 1027" "$RBODY" 2>/dev/null; then
    ATTEMPTS=3   # next increment trips the give-up branch immediately, with the right advice
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  if [[ $ATTEMPTS -ge 4 ]]; then
    rm -f "$RBODY"
    # Same self-heal as backup-data.sh: a dead/refused worker must not kill the only
    # off-box copy of /etc + .env + the APK signing key. Try R2 direct first, and only
    # report the cap advice if that failed too.
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && npx --yes wrangler r2 object put "$BUCKET/$KEY" --file "$TMP/identity.enc" --remote >/dev/null 2>&1; then
      echo "[identity] worker path failed (HTTP $RCODE) — sent via R2 direct instead"
      echo "[identity] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [wrangler]"
      exit 0
    fi
    echo "[identity] ERROR: worker path failed after $ATTEMPTS tries (HTTP $RCODE)." >&2
    echo "[identity] If 'curl -s $WURL | head -1' says 'error code: 1027', that is the"
    echo "           account's daily free Worker request cap (100,000/day, resets 00:00 UTC) —"
    echo "           a plan limit, NOT a missing route and NOT a throttle. Retrying is futile."
    echo "           Until it resets, the laptop track copies the same paths with the same"
    echo "           scheme: bash scripts/backup-laptop.sh"
    echo "           The archive also stays on this box at $KEEP — copy it off before you wipe."
    exit 1
  fi
  case $ATTEMPTS in 1) SLEEP=8 ;; 2) SLEEP=20 ;; *) SLEEP=45 ;; esac
  echo "[identity] POST failed (HTTP $RCODE) -- retry $ATTEMPTS/3 in ${SLEEP}s" >&2
  sleep "$SLEEP"
done
rm -f "$RBODY"
echo "[identity] ✓ $KEY ($SIZE) — $(date -u +%FT%TZ) [worker]"
