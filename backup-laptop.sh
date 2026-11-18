#!/usr/bin/env bash
# ==============================================================================
# backup-laptop.sh — nightly copy of the VPS runtime data/ onto THIS laptop.
#
# Why: the R2 offsite track (tukuk-data-backup.timer) uploads through a
# *.workers.dev endpoint. When that endpoint answers 429 with "error code: 1027" it is
# the ACCOUNT's daily free Worker request cap (Workers Free: 100,000 requests/day, reset
# at 00:00 UTC) — NOT an unbound route and NOT congestion. Proven on 30 Oct 2026 by
# crossing the reset: 429/1027 at 23:59 UTC, the worker's own "403 forbidden" at 00:02
# UTC, and the box's own upload then landed within the minute. So the box track works on
# most days — but a cap day kills all four tracks at once, because they share one
# endpoint. This script is the copy that does not depend on Workers at all: it writes
# with the laptop's wrangler OAuth token straight into R2, which costs zero Worker
# requests. The laptop is also the device that survives a server disk death: one sudo
# tar pipe over SSH, 14 daily files kept.
#
# Making the box independent of the cap needs ONE dashboard change: give the box's
# CLOUDFLARE_API_TOKEN Account · R2 Storage · Read & Edit (README §9). The upload scripts
# already fall through to `wrangler r2 object put` on that path.
#
# The 30 Oct 2026 rebuild ran off scripts/backup-identity.sh's Oct 27 archive, and
# THIS script had failed silently since .101: the LAN address moved to .104 while
# the probe list still held .101/.100, so every nightly run exited 1 on "server
# unreachable" and nobody looked. The address drifts, so every known address is
# probed rather than trusted, and the identity copy below is what stops the box's
# own archive from being the only line of defence a second time.
#
# Runs from the systemd USER timer (tukuk-laptop-backup.timer, Persistent=true)
# so a laptop that was off at 03:45 catches up on next power-on.
# USE:  bash scripts/backup-laptop.sh          (interactive sshpass or key)
# RESTORE: tar xzf ~/tukuk-backups/data-<date>.tar.gz -C /opt/tukuk-os
#          ...or from the cloud copy: wrangler r2 object get tukuk-fallback/laptop-backup/data-<date>.tar.gz
#
# Phase 2 (added Oct 27): after a good local archive, push the same file to R2
# under laptop-backup/ using the laptop's wrangler OAuth token — that token has
# full R2 put/get/delete on tukuk-fallback (verified round-trip), so offsite
# revival no longer waits on the VPS-token dashboard change.
#
# Phase 3 (added Oct 30): copy the box IDENTITY too, not just data/. The rebuild
# proved which files are irreplaceable — /etc/cloudflared (the one tunnel's config), .env
# with every LLM key, the nginx/systemd units — and all of them came back from ONE
# encrypted tukuk-identity archive. backup-data.sh never touched them, and on a cap day
# the box cannot push its own identity off itself either (that is the 1027 path), so the
# laptop does it: same PATHS, same AES-256/PBKDF2 scheme, same key name, so
# scripts/restore-identity.sh <DD> reads either producer. The passphrase itself is
# NEVER included — it lives here on the laptop, not in the bucket.
# ==============================================================================
set -uo pipefail

DEST_DIR="${HOME}/tukuk-backups"
SSH_PASS="${TUKUK_SSH_PASS:-1}"                      # same LAN cred as every deploy flow
KEEP_DAYS=14
IPS="${TUKUK_LAN_IPS:-192.168.8.104 192.168.8.101 192.168.8.100}"
mkdir -p "$DEST_DIR"

# --- find the box: LAN address drifts (verified pattern), try every known IP ---
HOST=""
for ip in $IPS; do
  if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
       -o PubkeyAuthentication=no -o ConnectTimeout=4 "tukuk@$ip" true 2>/dev/null; then
    HOST="$ip"; break
  fi
done
if [[ -z "$HOST" ]]; then
  echo "[laptop-backup] ERROR: server unreachable on LAN ($IPS) — nothing done." >&2
  exit 1
fi

KEY="$DEST_DIR/data-$(date +%Y%m%d).tar.gz"
echo "[laptop-backup] pulling /opt/tukuk-os/data from $HOST ..."
# sudo -S feeds the password on stdin; tar streams the tree so live files are
# snapshotted in one pass (rc 1 = "file changed as we read it" → still valid).
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no "tukuk@$HOST" \
    "echo $SSH_PASS | sudo -S -p '' tar czf - -C /opt/tukuk-os data" > "$KEY"
RC=$?
SIZE=$(du -h "$KEY" 2>/dev/null | cut -f1)
# rc 1 from tar = "file changed as we read it" (data/ is live-written) — archive
# is still valid; only >=2 is a real failure (the classic hourly-tar race pitfall).
if [[ $RC -ge 2 || -z "$SIZE" ]]; then
  echo "[laptop-backup] ERROR: pipe failed (rc=$RC)" >&2
  rm -f "$KEY"; exit 1
fi
[[ $RC -eq 1 ]] && echo "[laptop-backup] WARN: a file changed mid-read — continuing with usable archive" >&2
echo "[laptop-backup] ✓ $KEY ($SIZE) [host=$HOST]"

# --- retention: drop local dailies older than KEEP_DAYS ---
find "$DEST_DIR" -name 'data-*.tar.gz' -mtime +"$KEEP_DAYS" -delete 2>/dev/null

# --- phase 2: offsite copy to R2 via the laptop's wrangler OAuth token ---
R2_BUCKET="${R2_BUCKET:-tukuk-fallback}"
R2_KEY="laptop-backup/$(basename "$KEY")"
if npx --yes wrangler r2 object put "$R2_BUCKET/$R2_KEY" --file "$KEY" \
     --content-type application/gzip --remote >/dev/null 2>&1; then
  echo "[laptop-backup] ✓ r2://$R2_BUCKET/$R2_KEY ($SIZE) [oauth]"
  # prune cloud dailies older than KEEP_DAYS (a 404 on already-gone keys is fine)
  for d in $(seq "$((KEEP_DAYS + 1))" "$((KEEP_DAYS + 21))"); do
    npx --yes wrangler r2 object delete "$R2_BUCKET/laptop-backup/data-$(date -d "-${d} days" +%Y%m%d).tar.gz" \
      --remote >/dev/null 2>&1 || true
  done
else
  echo "[laptop-backup] WARN: R2 upload failed — is 'wrangler login' still valid?" >&2
fi

echo "[laptop-backup] kept: $(ls -1 "$DEST_DIR"/data-*.tar.gz 2>/dev/null | wc -l) local file(s), newest $(date -r "$(ls -1t "$DEST_DIR"/data-*.tar.gz 2>/dev/null | head -1)" +%F 2>/dev/null)"

# --------------------------------------------------------------------------------
# Phase 3 — the box IDENTITY. Everything here is deliberately the same shape as
# scripts/backup-identity.sh (same PATHS, same openssl scheme, same key name) so
# scripts/restore-identity.sh <DD> can read an archive from either producer.
#
# The passphrase is NOT in the list: /root/tukuk-backup-key encrypts this archive,
# so shipping it to the same bucket would make the archive self-opening. It lives on
# this laptop (~/.config/tukuk/backup-key) and on the box, on two devices.
# --------------------------------------------------------------------------------
# An ARRAY, not a quoted string: a backslash-newline inside "..." is kept literally by
# bash (verified), which would ship a stray `\` into the remote `ls -d` command line.
ID_PATHS=(etc/cloudflared etc/nginx etc/systemd/system etc/ssh etc/netplan etc/hosts etc/resolv.conf
  etc/timezone home/tukuk/.cloudflared home/tukuk/.ssh opt/tukuk-os/.env
  opt/tukuk-os/apk/tukuk-chat-release.jks opt/tukuk-os/apk/keystore.env)
ID_KEYFILE="${IDENTITY_KEY_FILE:-$HOME/.config/tukuk/backup-key}"
ID_RAW="$DEST_DIR/identity-latest.tar"
ID_ENC="$DEST_DIR/identity-$(date +%Y%m%d).tar.gz.enc"
ID_R2="backups/tukuk-identity-$(date -u +%d).tar.gz.enc"

if [[ ! -r "$ID_KEYFILE" ]]; then
  echo "[laptop-backup] ERROR: $ID_KEYFILE unreadable — refusing to put the box's secrets in a bucket unencrypted. No identity copy taken." >&2
elif { echo "$SSH_PASS"; printf 'cd / && ls -d %s 2>/dev/null | tar cf - -T -\n' "${ID_PATHS[*]}"; } \
     | sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
         -o PubkeyAuthentication=no "tukuk@$HOST" "sudo -S -p '' bash -s" > "$ID_RAW"; then
  NFILES=$(tar tf "$ID_RAW" 2>/dev/null | grep -vc '/$')
  gzip -nf "$ID_RAW" && openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -in "${ID_RAW}.gz" -out "$ID_ENC" -pass "file:$ID_KEYFILE" \
    && rm -f "${ID_RAW}.gz" || echo "[laptop-backup] WARN: identity encrypt failed" >&2
  if [[ -s "$ID_ENC" ]]; then
    echo "[laptop-backup] ✓ $ID_ENC ($(du -h "$ID_ENC" | cut -f1), $NFILES files) [host=$HOST]"
    find "$DEST_DIR" -name 'identity-*.tar.gz.enc' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
    if npx --yes wrangler r2 object put "$R2_BUCKET/$ID_R2" --file "$ID_ENC" \
         --content-type application/octet-stream --remote >/dev/null 2>&1; then
      echo "[laptop-backup] ✓ r2://$R2_BUCKET/$ID_R2 [oauth] — restore with: sudo bash scripts/restore-identity.sh $(date -u +%d)"
    else
      echo "[laptop-backup] WARN: identity is local-only this run (wrangler OAuth expired? R2 upload failed)" >&2
    fi
  fi
else
  rm -f "$ID_RAW"
  echo "[laptop-backup] WARN: identity pull failed — data copy above still succeeded, but the tunnel keys/.env did not come across" >&2
fi
