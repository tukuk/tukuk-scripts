#!/usr/bin/env bash
# make-env.sh — assemble .env from the two halves of the configuration.
#
#   deploy/env.defaults   tracked, publishable: what the server DOES
#   deploy/env.secrets    not tracked, 0600: what the server is ALLOWED to do
#
# Both are plain KEY=value files, and .env is simply one after the other, so an
# existing .env keeps working unchanged: nothing in src/ reads these two files, it
# reads .env (src/config.js) or the process environment. That is the whole point of
# doing the merge here instead of in the app — the server code does not learn about it.
#
#   sudo bash scripts/make-env.sh            # write .env if missing
#   sudo bash scripts/make-env.sh --force    # rebuild it from the two halves
#   TUKUK_SECRETS=/media/usb/env.secrets sudo bash scripts/make-env.sh --force
#
# Exit codes: 0 = .env is complete; 3 = .env written but the secrets half was not
# found (the tunnel will NOT come up, the admin bootstrap will not exist); anything
# else is a hard failure. Callers that must not abort an install (setup-all.sh, run
# from npm postinstall) treat 3 as a warning.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS="$REPO_DIR/deploy/env.defaults"
SECRETS="${TUKUK_SECRETS:-$REPO_DIR/deploy/env.secrets}"
TARGET="$REPO_DIR/.env"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

red() { printf '\033[31m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m\n' "$1"; }
ylw() { printf '\033[33m%s\033[0m\n' "$1"; }

[[ -f "$DEFAULTS" ]] || { red "✗ missing $DEFAULTS — nothing to build from."; exit 1; }
if [[ -f "$TARGET" && "$FORCE" -eq 0 ]]; then
  grn "✓ .env already exists — left untouched (use --force to rebuild it from the two halves)."
  exit 0
fi

# The keys a box needs from the private half, in words rather than values: this is how
# a missing secrets file turns into a specific complaint instead of a silent 502 later.
REQUIRED_KEYS=(CF_TUNNEL_TOKEN CLOUDFLARE_API_TOKEN ADMIN_EMAIL ADMIN_PASSWORD AGENT_TOKEN BACKUP_UPLOAD_SECRET)

missing=()
if [[ -f "$SECRETS" ]]; then
  chmod 600 "$SECRETS"
  for k in "${REQUIRED_KEYS[@]}"; do
    grep -qE "^$k=" "$SECRETS" || missing+=("$k")
  done
else
  missing=("${REQUIRED_KEYS[@]}")
fi

# Secrets last so they win, and so a stray placeholder in the public half can never
# shadow a real value. Comments and blank lines are dropped: .env is read by
# src/config.js's own parser, which handles '#' but is simpler served clean.
# Built next to the target, not in /tmp: mktemp's file is 0600 and a rename inside one
# directory is atomic, so there is never a half-written .env and never a copy of the
# secret material living on another filesystem. The trap is for the failure path — a
# leftover .env.XXXXXX would hold real values.
TMP=$(mktemp "${TARGET}.XXXXXX") || { red "cannot create a temp file next to $TARGET"; exit 1; }
trap 'rm -f "$TMP"' EXIT
{ grep -hE '^[A-Za-z_][A-Za-z0-9_]*=' "$DEFAULTS"; \
  [[ -f "$SECRETS" ]] && grep -hE '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS"; } > "$TMP"

# Some keys exist ONLY in .env, because setup-all.sh generated them on this box: API_KEY
# (the mutation-route guard) and MEILI_MASTER_KEY. Rebuilding from the two halves alone
# would silently drop them, and that is not a cosmetic loss — meilisearch.service reads
# EnvironmentFile=$INSTALL_DIR/.env and passes ${MEILI_MASTER_KEY} on its command line, so
# a regenerated key means the service comes up asking for a key the data dir was written
# with: every search 403, /health still claiming "meilisearch":"available". That exact
# stale-key shape is documented in setup-all.sh. So any name that is only in the old .env
# is carried across, and the carry is printed by name (never by value).
carried=()
if [[ -f "$TARGET" ]]; then
  while IFS= read -r line; do
    key=${line%%=*}
    grep -qE "^${key}=" "$TMP" && continue
    printf '%s\n' "$line" >> "$TMP"
    carried+=("$key")
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$TARGET")
fi

mv "$TMP" "$TARGET"
trap - EXIT
chmod 600 "$TARGET"
if [[ ${#carried[@]} -gt 0 ]]; then
  ylw "  carried over from the old .env (generated on this box, in neither half): ${carried[*]}"
fi

count=$(grep -cE '.' "$TARGET")
grn "✓ .env written: $count keys from $(basename "$DEFAULTS")$( [[ -f "$SECRETS" ]] && echo " + $(basename "$SECRETS")" )."

if [[ ${#missing[@]} -gt 0 ]]; then
  ylw "⚠ no secrets half at $SECRETS — these are unset in .env:"
  for k in "${missing[@]}"; do ylw "    $k"; done
  ylw "  Consequences: the Cloudflare tunnel cannot register (tukuk.org stays down),"
  ylw "  the admin bootstrap password does not exist (passkey registration impossible),"
  ylw "  wrangler cannot deploy the www worker."
  ylw "  Fix: copy deploy/env.secrets from the USB stick / identity archive, or point"
  ylw "  TUKUK_SECRETS at it, then re-run: sudo bash scripts/make-env.sh --force"
  exit 3
fi
exit 0
