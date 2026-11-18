#!/usr/bin/env bash
#
# Second provider.
#
# Everything else we back up lands in Cloudflare R2 (data hourly, box identity
# daily). Both copies are therefore behind one company and one account: a billing
# lockout, a policy action or an outage at Cloudflare takes the archive and the
# mirror at the same time. This job copies the two finished archives to Backblaze
# B2 -- different company, 10 GB free -- so a recovery does not depend on the
# vendor that already has the primary.
#
# It mirrors what backup-data.sh and backup-identity.sh already left in
# /var/backups rather than re-reading the live data dir or re-taring /etc: the
# bytes that went to R2 are the bytes that go to B2, and the two producers stay
# untouched.
#
# Objects are named by day-of-month, so a month of copies overwrite each other and
# the job needs no delete permission at all -- the same trick the R2 slots use.
# B2 free storage is 10 GB; 31 daily data archives (~18 MB) plus 31 daily identity
# archives (~136 KB) is roughly 600 MB, an order of magnitude inside it.
set -uo pipefail

ENVF="${TUKUK_ENV_FILE:-/opt/tukuk-os/.env}"
_env_get() {
  grep -E "^[[:space:]]*$1=" "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- \
    | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" -e 's/^"//' -e 's/"$//'
}

B2ID="${B2_ACCOUNT_ID:-$(_env_get B2_ACCOUNT_ID)}"
B2KEY="${B2_APPLICATION_KEY:-$(_env_get B2_APPLICATION_KEY)}"
BUCKET="${B2_BUCKET:-$(_env_get B2_BUCKET)}"

# Hard errors, not skips: a job that quietly does nothing is how you find out in
# the week the box is gone.
if [[ -z "$B2ID" || -z "$B2KEY" || -z "$BUCKET" ]]; then
  echo "[b2] ERROR: B2_ACCOUNT_ID / B2_APPLICATION_KEY / B2_BUCKET are not set in $ENVF." >&2
  echo "[b2]        Create a private bucket plus an application key limited to it, then" >&2
  echo "[b2]        append those three lines to $ENVF and run this again." >&2
  exit 1
fi
command -v rclone >/dev/null 2>&1 || { echo "[b2] ERROR: rclone is not installed." >&2; exit 1; }

# Credentials in the process environment only: rclone reads RCLONE_CONFIG_<name>_*
# without a config file, so the key never lands on disk where a snapshot of the
# box would carry it.
export RCLONE_CONFIG_B2_TYPE=b2
export RCLONE_CONFIG_B2_ACCOUNT="$B2ID"
export RCLONE_CONFIG_B2_KEY="$B2KEY"
REMOTE="b2:$BUCKET"

DAY="$(date -u +%d)"
MAXAGE="${B2_MAX_AGE_SECONDS:-90000}"   # 25 h: one missed producer run is still OK
rc=0

mirror() {
  local src="$1"
  if [[ ! -r "$src" ]]; then
    echo "[b2] ERROR: $src is not readable -- the job that produces it has not run." >&2
    rc=1; return
  fi
  local age now mtime
  now=$(date +%s); mtime=$(stat -c %Y "$src"); age=$(( now - mtime ))
  if (( age > MAXAGE )); then
    # Mirroring a stale file would claim "you have a second copy" about bytes that
    # are days old. Refuse and say so instead.
    echo "[b2] ERROR: $src is $(( age / 3600 ))h old; refusing to call that a backup." >&2
    rc=1; return
  fi

  local key="backups/$(basename "${src/-latest/-$DAY}")"
  local size; size=$(du -h "$src" | cut -f1)
  echo "[b2] mirroring $src ($size) -> $REMOTE/$key"

  local try=0
  until rclone copyto "$src" "$REMOTE/$key" --checksum --contimeout 60s --timeout 300s \
        --retries 3 --low-level-retries 10 >/tmp/b2-up.log 2>&1; do
    try=$(( try + 1 ))
    if (( try >= 3 )); then
      echo "[b2] ERROR: upload of $key failed after $try attempts:" >&2
      tail -3 /tmp/b2-up.log >&2; rc=1; return
    fi
    sleep $(( 20 * try ))
  done

  # The mirror is only real if the bytes at the far end match. Compare the MD5
  # rclone stored with B2 (it reports one for small objects) against local.
  local want got
  want=$(md5sum "$src" | cut -d' ' -f1)
  got=$(rclone md5sum "$REMOTE/$key" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ -z "$got" ]]; then
    echo "[b2] ERROR: uploaded $key but could not read it back to verify." >&2; rc=1; return
  fi
  if [[ "$want" != "$got" ]]; then
    echo "[b2] ERROR: $key md5 differs at the remote ($want vs $got)." >&2; rc=1; return
  fi
  echo "[b2] ✓ $key ($size) md5 $want verified at B2"
}

mirror /var/backups/tukuk-data-latest.tar.gz
mirror /var/backups/tukuk-identity-latest.tar.gz.enc

if (( rc == 0 )); then echo "[b2] done"; fi
exit $rc
