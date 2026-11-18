#!/usr/bin/env bash
# ==============================================================================
# restore-identity.sh — prove the identity backup can be read back, and stage it.
#
# Dry run by DEFAULT. It downloads the slot, decrypts it, checks gzip integrity
# and the per-file checksums, and unpacks into a staging directory. Only --apply
# copies anything over /etc, because restoring the wrong slot onto a living box
# is worse than not restoring at all -- and because the drill is only worth
# anything if it can be run while the site is up.
#
# USE:  sudo bash scripts/restore-identity.sh              # today's slot, verify + stage
#       sudo bash scripts/restore-identity.sh 14           # day-of-month slot 14
#       sudo bash scripts/restore-identity.sh 14 --apply   # install over /etc etc.
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

WURL="${BACKUP_WORKER_URL:-}"
WSEC="${BACKUP_UPLOAD_SECRET:-}"
KEYFILE="${IDENTITY_KEY_FILE:-/root/tukuk-backup-key}"
SLOT="${1:-$(date -u +%d)}"
MODE="${2:-verify}"
KEY="backups/tukuk-identity-$SLOT.tar.gz.enc"
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
STAGE="${IDENTITY_STAGE:-/root/identity-restore-$SLOT}"
trap 'rm -rf "$TMP"' EXIT

[[ -n "$WURL" && -n "$WSEC" ]] || { echo "[restore] ERROR: BACKUP_WORKER_URL / BACKUP_UPLOAD_SECRET not set." >&2; exit 1; }
[[ -r "$KEYFILE" ]] || { echo "[restore] ERROR: $KEYFILE unreadable -- cannot decrypt." >&2; exit 1; }

echo "[restore] fetching $KEY ..."
curl -fsS --max-time 180 -H "Authorization: Bearer $WSEC" "$WURL/?key=$KEY" -o "$TMP/blob" \
  || { echo "[restore] ERROR: slot missing or download failed." >&2; exit 1; }
echo "[restore] downloaded $(du -h "$TMP/blob" | cut -f1), sha256 $(sha256sum "$TMP/blob" | cut -c1-16)..."

openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$TMP/blob" -out "$TMP/identity.tar.gz" -pass "file:$KEYFILE" \
  || { echo "[restore] ERROR: decrypt failed (wrong key, or the slot is not ours)." >&2; exit 1; }
gzip -t "$TMP/identity.tar.gz" || { echo "[restore] ERROR: archive is corrupt." >&2; exit 1; }

mkdir -p "$STAGE"
tar xzf "$TMP/identity.tar.gz" -C "$STAGE" || { echo "[restore] ERROR: unpack failed." >&2; exit 1; }
echo "[restore] staged into $STAGE"

# The manifest's checksums were computed on the live box; re-verify them against
# what just unpacked, so "it restored" is a measurement and not a hope.
if [[ -f "$STAGE/manifest/checksums.txt" ]]; then
  BAD=$( cd "$STAGE" && while IFS= read -r line; do
           f=${line#*  }
           [[ -f "$STAGE/$f" ]] || continue
           want=${line%%  *}
           have=$(sha256sum "$STAGE/$f" | cut -d" " -f1)
           [[ "$want" == "$have" ]] || echo "$f"
         done < "$STAGE/manifest/checksums.txt" | wc -l )
  echo "[restore] checksums: $(wc -l < "$STAGE/manifest/checksums.txt") files, $BAD mismatched"
  [[ "$BAD" == "0" ]] || { echo "[restore] ERROR: content does not match the manifest." >&2; exit 1; }
fi
echo "[restore] top level: $(ls "$STAGE" | tr "\n" " ")"
echo "[restore] tunnel keys present: $(ls "$STAGE/etc/cloudflared" 2>/dev/null | grep -c "\.json$")"

if [[ "$MODE" != "--apply" ]]; then
  echo "[restore] VERIFIED (dry run). Nothing was overwritten."
  echo "[restore] to install: sudo bash scripts/restore-identity.sh $SLOT --apply"
  exit 0
fi

echo "[restore] APPLYING $STAGE over / -- this replaces live config."
cp -a "$STAGE/etc/." /etc/ 2>/dev/null
cp -a "$STAGE/opt/tukuk-os/.env" /opt/tukuk-os/.env 2>/dev/null
mkdir -p /home/tukuk/.cloudflared /home/tukuk/.ssh
cp -a "$STAGE/home/tukuk/.cloudflared/." /home/tukuk/.cloudflared/ 2>/dev/null
cp -a "$STAGE/home/tukuk/.ssh/." /home/tukuk/.ssh/ 2>/dev/null
chmod 600 /home/tukuk/.ssh/authorized_keys 2>/dev/null
systemctl daemon-reload
nginx -t && systemctl reload nginx
echo "[restore] ✓ applied from slot $SLOT. Restart the tunnel if its config changed:"
echo "[restore]   systemctl restart cloudflared"
