#!/usr/bin/env bash
# ==============================================================================
# rebuild-from-offsite.sh — bring a brand-new box up to the live box's state.
#
#   sudo bash scripts/rebuild-from-offsite.sh
#
# One command after the code is on disk. It runs the normal setup, then pulls the
# two off-site archives (identity + data) out of R2, restores the parts of the old
# box that git cannot carry, turns on every service, and finishes with a PASS/FAIL
# table. Exit code is non-zero if anything a visitor can see is broken — because a
# rebuild that "finished" while the site was down is the exact failure this script
# exists to prevent.
#
# Two deliberate design rules, both learned the hard way:
#
# 1. NEVER source .env. It holds `WEBAUTHN_RP_NAME=Tukuk Passkey`, which bash
#    parses as "assign, then run `Passkey` as a command". Read keys with _env_get.
#
# 2. Restore selectively. `restore-identity.sh --apply` copies the whole /etc,
#    which on a fresh box dumps a hundred foreign OS units (snapd, cloud-init,
#    grub) over systemd and replaces /etc/netplan with interface names from
#    different hardware — the classic way to rebuild a server and then lose its
#    network. Only the paths this app owns get copied, and netplan waits for a
#    human with FORCE_NET=1.
# ==============================================================================
set -uo pipefail

APP="${TUKUK_INSTALL_DIR:-/opt/tukuk-os}"
# ONE FOLDER (deploy/paths.sh): the game lives inside the app folder, not at /var/www.
export TUKUK_ROOT="$APP"
# shellcheck source=../deploy/paths.sh
. "$APP/deploy/paths.sh"
PLAY_DIR="$TUKUK_PLAY_DIR"
ENV="$APP/.env"
KEYFILE="${IDENTITY_KEY_FILE:-/root/tukuk-backup-key}"
FAILS=0
RESTORED_DATA=0
log() { printf '\033[1;34m➜\033[0m %s\n' "$*"; }
good() { printf '  \033[0;32mPASS\033[0m %-30s %s\n' "$1" "${2:-}"; }
bad()  { printf '  \033[0;31mFAIL\033[0m %-30s %s\n' "$1" "${2:-}"; FAILS=$((FAILS+1)); }
note() { printf '  \033[1;33mNEXT\033[0m %-28s %s\n' "$1" "${2:-}"; }

# What the runtime store actually holds, for the data guard in step 3 and the verify table in step 5.
# Read as JSON rather than by grepping the file for a token: the credential objects use `id` and
# `publicKey` (src/auth.js), so an earlier version of this line searched for "credentialId", found
# nothing, and reported "0 credential(s) — users would have to re-register" as a FAIL on a store
# that was fine. The shape is measured: settings.passkeys is the array, users is an object.
# Defined here, at the top, because step 3 runs it — a function called before bash has executed its
# definition is "command not found", and inside `VAR=$(...)` that non-zero exit kills a `set -e` script.
store_shape() { # <file> → "<n> passkey(s), <m> user record(s)" | unreadable
  node -e 'try{const d=require(require("path").resolve(process.argv[1]));const p=(d.settings&&Array.isArray(d.settings.passkeys))?d.settings.passkeys:[];const u=d.users?(Array.isArray(d.users)?d.users.length:Object.keys(d.users).length):0;console.log(p.length+" passkey(s), "+u+" user record(s)")}catch(e){console.log("unreadable")}' "$1" 2>/dev/null || echo unreadable; }

_env_get() { [[ -r "$ENV" ]] && grep -E "^[[:space:]]*$1=" "$ENV" | tail -1 | cut -d= -f2- \
             | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' || true; }

# ── 0. preflight: refuse loudly rather than half-install ──────────────────────
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)." >&2; exit 1; }
[[ -f "$APP/package.json" ]] || { echo "code is not at $APP yet — clone or USB first (tukuk/tukuk-os is private until you publish it)." >&2; exit 1; }
[[ -r "$KEYFILE" ]] || { echo "cannot read $KEYFILE — the archive is useless without the key. It rides on the handover stick as key/tukuk-backup-key (install -m 600 it to /root/tukuk-backup-key), or copy it from the laptop's ~/.config/tukuk/backup-key." >&2; exit 1; }
for t in curl git openssl tar node; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

# Bootstrap .env exactly the way setup-all.sh does, through the same script so the two
# cannot drift. The gate below READS .env, and a fresh clone has none (it is gitignored),
# so on a truly empty box -- the only box this script is written for -- the one-command
# rebuild died at its own first check. Order matters more than cleverness here.
# Exit 3 from make-env.sh means the private half was not found; that is fatal for THIS
# script a few lines later, because BACKUP_UPLOAD_SECRET lives in that half.
if [[ ! -f "$ENV" ]]; then
  bash "$APP/scripts/make-env.sh" || echo "  make-env.sh reported an incomplete .env — see above."
fi

WURL="$(_env_get BACKUP_WORKER_URL)"; WSEC="$(_env_get BACKUP_UPLOAD_SECRET)"
[[ -n "$WURL" && -n "$WSEC" ]] || { echo "BACKUP_WORKER_URL / BACKUP_UPLOAD_SECRET empty in $ENV." >&2; echo "  The upload secret is in deploy/env.secrets, which is deliberately NOT in git — a" >&2; echo "  fresh clone cannot carry it. Copy that file in (handover stick), or run this with" >&2; echo "  TUKUK_SECRETS=/path/to/env.secrets so make-env.sh can find it somewhere else." >&2; exit 1; }

# ── 1. the ordinary bring-up (tuning, Node, Meilisearch, units, tunnel) ───────
log "[1/5] scripts/setup-all.sh (idempotent core install)"
bash "$APP/scripts/setup-all.sh" --from-server || echo "  setup-all exited non-zero; continuing to the verify table so nothing is hidden."

# ── 2. newest off-site archives, named by the bucket rather than guessed ─────
# The worker's GET with ?prefix= is a real listing, so the newest slot is a fact.
# (Probing guessed key names through a CLI proved unreliable: a key can exist and
# still report "does not exist", which reads like a lost backup.)
newest() { # newest() <prefix> -> key
  curl -fsS --max-time 60 -H "Authorization: Bearer $WSEC" "$WURL/?prefix=$1" 2>/dev/null \
  | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{ const o=JSON.parse(s).objects.map(x=>({k:x.key,t:Date.parse(x.uploaded||0),b:x.bytes}));
           o.sort((a,c)=>c.t-a.t); if(o[0]) console.log(o[0].k); }catch(e){}});'
}
log "[2/5] locating the newest off-site archives"
IDKEY="$(newest backups/tukuk-identity)"; DATAKEY="$(newest backups/tukuk-data)"
[[ -n "$IDKEY" ]] || { echo "no identity archive listed under backups/tukuk-identity — the R2 gateway may be down or the bucket renamed." >&2; exit 1; }
echo "  identity: $IDKEY   data: ${DATAKEY:-<none found>}"

TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
fetch() { curl -fsS --retry 3 --max-time 600 -H "Authorization: Bearer $WSEC" "$WURL/?key=$1" -o "$2" \
          || { echo "download failed for $1" >&2; return 1; }; }
fetch "$IDKEY" "$TMP/id.enc" || exit 1
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$TMP/id.enc" -out "$TMP/id.tar.gz" -pass "file:$KEYFILE" \
  || { echo "decrypt failed — wrong key?" >&2; exit 1; }
gzip -t "$TMP/id.tar.gz" || { echo "identity archive is corrupt" >&2; exit 1; }
tar xzf "$TMP/id.tar.gz" -C "$TMP" || { echo "unpack failed" >&2; exit 1; }
echo "  identity unpacked: $(find "$TMP/etc" "$TMP/opt" "$TMP/home" -type f 2>/dev/null | wc -l) files"

# ── 3. selective restore: only what this project owns ────────────────────────
log "[3/5] restoring the paths git does not carry"
stage() { [[ -d "$TMP/$1" ]] && { mkdir -p "/$1"; cp -a "$TMP/$1/." "/$1/"; echo "  ✓ $1"; }; }
mkdir -p /etc/systemd/system
# unit files, ours only — never the OS ones that happened to sit in the same dir.
for u in "$TMP"/etc/systemd/system/tukuk-* "$TMP"/etc/systemd/system/cloudflared* \
         "$TMP"/etc/systemd/system/meili* "$TMP"/etc/systemd/system/chat-backup* \
         "$TMP"/etc/systemd/system/indexnow-* "$TMP"/etc/systemd/system/load-governor* \
         "$TMP"/etc/systemd/system/weight-report* "$TMP"/etc/systemd/system/builder-idle* \
         "$TMP"/etc/systemd/system/litert-lm.service; do
  [[ -f "$u" ]] && cp -a "$u" /etc/systemd/system/ && echo "  ✓ unit $(basename "$u")"
done
for d in "$TMP"/etc/systemd/system/*.d; do
  [[ -d "$d" ]] && { mkdir -p "/etc/systemd/system/$(basename "$d")"; cp -a "$d/." "/etc/systemd/system/$(basename "$d")/"; echo "  ✓ drop-in $(basename "$d")"; }
done
stage etc/nginx/conf.d
stage etc/cloudflared
stage etc/ssh                      # host keys: same identity, no client warnings
stage etc/hosts
stage home/tukuk/.cloudflared && chmod 600 /home/tukuk/.cloudflared/* 2>/dev/null
stage home/tukuk/.ssh && chmod 600 /home/tukuk/.ssh/authorized_keys 2>/dev/null
if [[ -f "$TMP/opt/tukuk-os/.env" ]]; then
  cp -a "$TMP/opt/tukuk-os/.env" "$ENV" && chmod 600 "$ENV" && echo "  ✓ .env (real keys, not the bundled defaults)"
  # Self-heal for the future: the working tunnel token lives in config.yml on the
  # restored box; mirror it into .env so a later box needs no archive at all.
  CFGTOK=$(grep -oE '^token: eyJ[^ ]*' /etc/cloudflared/config.yml 2>/dev/null | head -1 | cut -d' ' -f2)
  CFGID=$(grep -oE '^tunnel: [0-9a-f-]{36}' /etc/cloudflared/config.yml 2>/dev/null | head -1 | cut -d' ' -f2)
  if [[ -n "$CFGTOK" && -z "$(_env_get CF_TUNNEL_TOKEN)" ]]; then
    # The name here is CFGID (three letters, assigned two lines above). It has been mistyped twice,
    # and under `set -u` an unbound reference is FATAL -- it killed the rebuild immediately after
    # the identity archive's .env landed, so the netplan reference, the data restore, the front-proxy
    # step and the whole verify table never ran. test/deploy-scripts-variables.test.js now greps
    # every install script for exactly this, because `bash -n` cannot see it.
    grep -q '^CF_TUNNEL_ID=' "$ENV" && sed -i "s|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=$CFGID|" "$ENV" || echo "CF_TUNNEL_ID=$CFGID" >> "$ENV"
    echo "CF_TUNNEL_TOKEN=$CFGTOK" >> "$ENV"; chmod 600 "$ENV"
    echo "  ✓ CF_TUNNEL_TOKEN/ID captured from /etc/cloudflared/config.yml (stays out of git: .env is ignored)"
  fi
  # The restored .env is now the authority, but setup-all ran BEFORE it and wrote this server's
  # Meilisearch unit with the key it had at that moment — on an empty box that is a freshly
  # generated one. A unit key that disagrees with .env means Meilisearch answers 401 to every
  # search, which reads like a broken app rather than a key that arrived one step too late.
  MK="$(_env_get MEILI_MASTER_KEY)"
  MSVC=/etc/systemd/system/meilisearch.service
  if [[ -f "$MSVC" && -n "$MK" ]]; then
    UK=$(sed -n 's/.*--master-key \([^ ]*\).*/\1/p' "$MSVC" | head -1)
    if [[ "$UK" != "$MK" ]]; then
      if [[ "$MK" =~ ^[A-Za-z0-9_-]+$ ]]; then
        sed -i "s#--master-key [^ ]*#--master-key $MK#" "$MSVC"
        systemctl daemon-reload && systemctl restart meilisearch >/dev/null 2>&1
        echo "  ✓ meilisearch unit re-keyed to match the restored .env"
      else
        note "meilisearch key" "restored MEILI_MASTER_KEY has characters sed cannot take blindly — edit $MSVC by hand and restart meilisearch"
      fi
    fi
  fi
fi
if [[ -f "$TMP/etc/netplan/00-installer-config.yaml" ]]; then
  mkdir -p "$APP/etc-netplan-reference"; cp -a "$TMP/etc/netplan/." "$APP/etc-netplan-reference/"
  if [[ "${FORCE_NET:-0}" == "1" ]]; then cp -a "$TMP/etc/netplan/." /etc/netplan/ && echo "  ✓ netplan applied because FORCE_NET=1"
  else echo "  netplan NOT copied (different hardware = different interface names). Reference kept in $APP/etc-netplan-reference/; apply with sudo netplan try, never apply blind."; fi
fi

# data/ holds the runtime stores (passkeys in data/tukuk-os.json, chat, counters).
# Refusing to overwrite a live data dir is the point: a rebuild must not eat today's writes.
if [[ -n "$DATAKEY" ]]; then
  if [[ -f "$APP/data/tukuk-os.json" && "${FORCE_DATA:-0}" != "1" ]]; then
    # Say what is actually at stake, in both directions. The guard exists so a rebuild cannot eat
    # today's writes, but on a box that was installed hours ago data/ holds only the app's own
    # first-boot files and the archive holds every passkey credential ever registered -- so a bare
    # "not overwritten" pushed operators into leaving real user data out on purpose.
    LIVE=$(store_shape "$APP/data/tukuk-os.json")
    echo "  data/ already present ($LIVE on this box) — not overwritten. $DATAKEY left off-site."
    echo "  FORCE_DATA=1 takes the archive: passkeys/chat/counters as of that backup come back,"
    echo "  and anything written on THIS box since the install is lost. An empty store here means"
    echo "  every registered user would have to re-register if you do not restore."
  else
    # Stop the writers first. The app holds its stores in memory and flushes them on the next
    # change, so a data/ restored under a running tukuk-os.service can be overwritten seconds
    # later by what that process still believes it knows -- the restore would report ✓ and the
    # passkey store would go back to empty, which is precisely the failure this whole script is
    # supposed to prevent. The watchdog timer is stopped with it because it restarts anything it
    # watches; step 4 brings both back up and re-enables the timers afterwards.
    systemctl stop tukuk-os.service tukuk-os-watchdog.service tukuk-os-watchdog.timer >/dev/null 2>&1 || true
    if fetch "$DATAKEY" "$TMP/data.tar.gz" && gzip -t "$TMP/data.tar.gz" && tar xzf "$TMP/data.tar.gz" -C "$APP"; then
      RESTORED_DATA=1
      echo "  ✓ data/ restored from $DATAKEY ($(tar tzf "$TMP/data.tar.gz" | wc -l) entries)"
    else
      bad "data restore" "download or unpack of $DATAKEY failed — the archive never landed"
    fi
  fi
fi

# ── 4. the front proxy: nginx on 3000, Node on 3001 (drop-in), tunnel to nginx ─
log "[4/5] nginx front + services"
command -v nginx >/dev/null || { apt-get install -y -qq nginx >/dev/null && echo "  ✓ nginx installed"; }
# The archive has already restored both halves of the front: /etc/nginx/conf.d (listen
# 127.0.0.1:3000) and tukuk-os.service.d/60-front-port.conf (Node → 3001). So this line
# measures the result instead of calling `cut` again — the installer refuses to cut a
# second time, and that refusal would read like a failure of the rebuild.
if ss -ltn 2>/dev/null | grep -q ':3000 ' && ss -ltn 2>/dev/null | grep -q ':3001 '; then
  echo "  ✓ front proxy in place: nginx :3000, Node :3001"
else
  echo "  front proxy NOT in place. Redo the staged way:"
  echo "    sudo bash deploy/nginx/install-tukuk-front.sh verify"
  echo "    sudo node scripts/nginx-front-check.js 8080 && sudo bash deploy/nginx/install-tukuk-front.sh cut"
fi
systemctl daemon-reload
for s in meilisearch tukuk-os cloudflared nginx cockpit.socket cockpit-lan-socket.service; do systemctl enable --now "$s" >/dev/null 2>&1 || true; done
systemctl restart cloudflared >/dev/null 2>&1 || true
for t in tukuk-data-backup tukuk-identity-backup tukuk-content-backup meili-backup chat-backup tukuk-snapshot tukuk-os-watchdog tukuk-update indexnow-submit load-governor weight-report builder-idle-stop; do
  systemctl enable --now "$t.timer" >/dev/null 2>&1 || true
done

# ── 5. verify what a visitor can see, not what the script intended ───────────
log "[5/5] verification"
chk() { # chk <name> <expected> <actual>
  [[ "$3" == "$2" ]] && good "$1" "$3" || bad "$1" "expected $2, got $3"; }
code() { curl -4 -k -sS -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null || echo 000; }
# -k on the cockpit line below: Cockpit serves a self-signed cert, and a rejected
# handshake would read as "Cockpit is down" when it is actually up.
chk "app healthy (3000 front)" 200 "$(code http://127.0.0.1:3000/health)"
chk "meilisearch up"           200 "$(code http://127.0.0.1:7700/health)"
chk "tukuk.org through edge"    200 "$(code https://tukuk.org/)"
chk "search answers"            200 "$(code 'https://tukuk.org/cari?q=weather')"
chk "play.tukuk.org"            200 "$(code https://play.tukuk.org/)"
# ONE connector (cloudflared) carries every hostname now, play included. So the old
# second tunnel is what this checks FOR: a running cloudflared-build means the migration
# never finished, and two connectors are then answering the same DNS records.
[[ "$(systemctl is-active cloudflared-build 2>/dev/null)" == active ]] \
  && bad "one connector" "cloudflared-build still running — sudo bash scripts/setup-all.sh retires it" \
  || good "one connector (cloudflared only)" "cloudflared-build inactive"
# 200, measured: an unauthenticated GET /login is the real login page (it carries
# #login-user-input / #login-password-input). The 401 belongs to /cockpit/login, the package
# endpoint — checking THAT would pass for a console nobody can reach a login page on. A 000
# here means nothing is bound (the stale-drop-in failure), not that Cockpit refused us.
chk "cockpit on 9090"           200 "$(code https://127.0.0.1:9090/login)"
for s in meilisearch tukuk-os cloudflared nginx; do
  [[ "$(systemctl is-active "$s" 2>/dev/null)" == active ]] && good "service $s" active || bad "service $s" "$(systemctl is-active "$s" 2>/dev/null)"
done
# Both ports must be up for the front to be real: nginx on 3000, Node on 3001. Count the loopback
# families rather than assuming one line each (Node may bind 127.0.0.1 and ::1), and on a failure
# show what IS listening instead of an awk syntax error -- the previous version of this line had
# two adjacent regexes, `/:3001/:3000/`, which bash -n accepted and awk rejected, so the FAIL row
# printed an empty detail and looked like a mystery instead of a cutover that never happened.
N3001=$(ss -ltn 2>/dev/null | grep -cE ':3001\b')
N3000=$(ss -ltn 2>/dev/null | grep -cE ':3000\b')
if (( N3001 >= 1 && N3000 >= 1 )); then good "Node behind front (3001 ← nginx 3000)" "3001:${N3001} 3000:${N3000}"
else bad "Node behind front (3001)" "listening on 3000/3001: $(ss -ltn 2>/dev/null | awk '/:(3000|3001)\b/{print $4}' | tr '\n' ' ')"; fi
if [[ -f "$APP/data/tukuk-os.json" ]]; then
  PK=$(store_shape "$APP/data/tukuk-os.json")
  if [[ "$PK" == unreadable ]]; then
    bad "runtime store" "$APP/data/tukuk-os.json is not readable JSON"
  elif [[ "$PK" == "0 passkey(s), 0 user record(s)" && "${RESTORED_DATA:-0}" != 1 ]]; then
    # Nothing was restored and the live store is the app's own first boot. This is the row that
    # decides whether the off-site data archive is a cold-weather file or the site's memory.
    bad "runtime store" "$PK and data/ was not restored — rerun with FORCE_DATA=1"
  else
    # Zero passkeys here is a fact about the backup, not a fault: the archived store measured
    # 2026-10-28 held settings.passkeys = [] as well. Saying so keeps a real gap (lost chat, posts,
    # counters) apart from something that was never in the file to begin with.
    DET="$PK"
    [[ "$PK" == "0 passkey(s),"* ]] && DET="$PK — none was ever registered; the off-site archive held none either (measured 2026-10-28)"
    good "runtime store" "$DET"
  fi
else
  bad "runtime store" "no data/tukuk-os.json"
fi
TIMERS=$(systemctl list-timers --all --no-pager 2>/dev/null | grep -c 'tukuk-\|meili-\|chat-\|indexnow\|load-governor\|weight-report\|builder-idle')
[[ "$TIMERS" -ge 8 ]] && good "backup/maintenance timers" "$TIMERS scheduled" || bad "backup/maintenance timers" "$TIMERS scheduled"
# A bundle clone records origin as the path of the stick it came from, and a USB install has no
# .git at all (install-from-usb.sh excludes it). Either way the daily tukuk-update timer then
# fetches a device that is no longer in the machine: the box looks healthy and never receives
# another commit. Reported as NEXT, not FAIL — repointing a remote needs a GitHub key, which is a
# human decision, and the site is correct and serving either way.
ORIGIN=$(git -C "$APP" remote get-url origin 2>/dev/null || echo none)
case "$ORIGIN" in
  *.bundle|/media/*|/run/media/*|file:*)
    note "git remote" "origin is the handover bundle — once this box has a key: sudo git -C $APP remote set-url origin git@github.com:tukuk/tukuk-os.git" ;;
  none)
    note "git remote" "no origin at all (USB install excludes .git) — re-clone from a bundle to get the daily auto-update back" ;;
  *) good "git remote" "$ORIGIN" ;;
esac
MP=$(grep -o 'index.pck.zip?v=pck[0-9a-f]*' "$PLAY_DIR/index.html" 2>/dev/null | head -1)
[[ -n "$MP" ]] && good "pack is edge-cacheable" "$MP" || note "Godot HD build" "no mainPack alias in $PLAY_DIR — rebuild: sudo INSTALL_GAME=1 TUKUK_GAME_BUNDLE=<usb>/code/station-break-game.bundle bash scripts/setup-all.sh (builder + boot overlay now live in deploy/godot/)"
[[ -f "$APP/apk/tukuk-chat-release.jks" ]] && good "APK signing key" present || note "APK signing key" "apk/*.jks is gitignored — copy it from the laptop, then verify md5 matches the released APKs"
# A missing provider key is not a failure — the app degrades to extractive answers —
# but it must be visible, because "chat stopped working after the rebuild" is
# otherwise indistinguishable from a code bug.
LLMS=""; for k in GROQ_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY CLOUDFLARE_AI_API_KEY HUGGINGFACE_API_KEY; do
  [[ -n "$(_env_get $k)" ]] && LLMS="$LLMS ${k%_API_KEY}"
done
[[ -n "$LLMS" ]] && good "AI providers" "$LLMS" || note "AI providers" "no LLM key in .env — chat/rerank run extractive-only until one is added"

echo
if (( FAILS )); then
  echo -e "\033[0;31m  $FAILS check(s) failed — the box is NOT done. Fix above, rerun this script (it is idempotent).\033[0m"
  exit 1
fi
echo -e "\033[0;32m  All checks passed. Box rebuilt from off-site archives; nothing left to type.\033[0m"
