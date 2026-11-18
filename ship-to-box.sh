#!/usr/bin/env bash
# ==============================================================================
# ship-to-box.sh — push work from this dev box to the VPS and deploy it.
#
# Two transports, one command. The normal one is GitHub: /opt/tukuk-os fetches
# origin over a read-only deploy key (/root/.ssh/tukuk_deploy, registered on the
# repo), so `git push` here plus tukuk-update.timer is the whole deploy, and this
# script only has to push, start the unit, and read the proof. The other one is a
# git BUNDLE copied to the box's own disk, used when the box cannot reach GitHub —
# which is not hypothetical: the key vanished from /root/.ssh sometime before
# 29 Oct 2026, origin was repointed at a bundle, and for days the nightly timer
# answered "Already up to date" while four commits waited on GitHub. The mistakes
# here are the quiet kind: a stale bundle is a remote that always succeeds, and a
# truncated transfer is still a file scp calls success. So both paths are checked
# at the far end, and the degraded one puts itself back when it is done.
#
# Both have actually run. 4c86a37 went over GitHub; dcad3d6 was shipped with root's
# ssh config deliberately moved aside, so the probe refused, the bundle path executed
# end to end (39,933,411 bytes, byte-matched at the far end, verified inside the repo,
# the unit logging `From /home/tukuk/handover/code/...`, record and public edge both
# agreeing) and the EXIT trap put origin back. The fallback costs more than the direct
# path: 495.9 MB peak RSS and 10.7 s CPU on the box, against 32.7 MB and 2.2 s for
# GitHub's incremental of the same two commits — a bundle carries full history and has
# to be repacked. Wall time was 7 s either way, so the bundle is not slower for whoever
# is waiting on it; it is slower for a small box doing that work while serving traffic,
# which is the reason GitHub stays the default rather than merely the nicer option.
#
#   bash scripts/ship-to-box.sh                 # ship the current branch (main)
#   TUKUK_HOST=192.168.8.100 bash scripts/ship-to-box.sh
#   bash scripts/ship-to-box.sh --branch main --no-deploy   # deliver, do not restart
#
# What it guarantees:
#   * the pushed commit is on GitHub first, and this branch is never behind
#     origin — the Actions bot commits straight to GitHub, and commits left out of
#     a bundle never reach production;
#   * untracked files on the box that this ship adds as tracked paths are refused
#     before the merge, because that is what makes `merge --ff-only` give up;
#   * the bundle is verified INSIDE the repo it will be merged into, arrives with
#     the byte count it left with, and the previous copy is kept as .pre-<sha>;
#   * the box's own HEAD is the baseline, so a re-run after a successful deploy is
#     a no-op instead of a failed journal assertion (nothing merged, nothing logged);
#   * the sudo password is read from the box's own 0600 file (/home/tukuk/.ssh/
#     initial-password.txt) on the box — never argv, never this machine, never printed;
#   * the deploy is not believed until the shipped sha is in /opt/tukuk-os AND the
#     box's own update record on /health names it;
#   * if origin had to be repointed at a bundle, it is put back on exit.
#
# The update itself is the repo's own scripts/auto-update.sh via tukuk-update.service:
# fetch → merge --ff-only → (npm install if dependencies changed) → restart tukuk-os.
# It is fail-safe: --ff-only refuses when a path it must write is modified locally, so a
# hot edit on the box is never stamped over — it just stops the update, which is why this
# script checks the journal instead of assuming a green unit meant a merge happened.
# ==============================================================================
set -euo pipefail

BRANCH="main"
DEPLOY=1
HOST="${TUKUK_HOST:-tukuk-vps}"          # ssh alias in ~/.ssh/config; falls back to any host
REPO_DIR="/opt/tukuk-os"
BUNDLE_ON_BOX="/home/tukuk/handover/code/tukuk-os-v2-${BRANCH}.bundle"
PWFILE="/home/tukuk/.ssh/initial-password.txt"
ZONE="${CLOUDFLARE_ZONE_NAME:-tukuk.org}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="${2:?--branch needs a name}"; BUNDLE_ON_BOX="/home/tukuk/handover/code/tukuk-os-v2-${BRANCH}.bundle"; shift 2 ;;
    --host) HOST="${2:?--host needs a target}"; shift 2 ;;
    --no-deploy) DEPLOY=0; shift ;;
    *) echo "ship-to-box: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

say() { printf '[ship] %s\n' "$*"; }
die() { echo "ship-to-box: $*" >&2; exit 1; }

# SSH here always with </dev/null. ssh consumes its stdin, so a helper that inherits an
# unread pipe swallows whatever the loop or the next command was about to read — the
# classic `while read … do ssh …` loop that runs once. Nothing of ours needs stdin, so
# it is closed explicitly, and the transfer is measured at the far end anyway, because a
# truncated bundle is still a file and scp has no opinion about whether you meant it.
box() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$HOST" "$@" </dev/null; }

# One command as root on the box. The password is read on the box, substituted by the
# REMOTE shell, and piped into `sudo -S` — it is never an argument here or there, never
# printed, and never leaves the machine. Deliberately no local variable holding it: the
# suite scans every set -u script under scripts/ for reads with no assignment, and a
# variable that only exists inside a quoted ssh command string is exactly such a read.
# The command runs inside `bash -c` on the far side, not as bare sudo arguments: with
# `sudo -S -p '' cd /opt/tukuk-os && git fetch` the && binds outside sudo and the fetch
# would run unprivileged against a root-owned .git. Call sites therefore use single
# quotes inside and no double quotes.
rootcmd() { box "printf '%s\n' \"\$(cat '$PWFILE')\" | sudo -S -p '' bash -c \"$1\""; }

command -v git >/dev/null || die "git is not installed"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
cd "$(git rev-parse --show-toplevel)"

SHA="$(git rev-parse "$BRANCH")" || die "branch $BRANCH does not exist"
SHORT="$(git rev-parse --short "$BRANCH")"
say "shipping $BRANCH @ $SHORT ($(git log -1 --format=%s "$BRANCH"))"

# ── 1. GitHub first ────────────────────────────────────────────────────────────────
# Even on the bundle path. If this box is the only place the commit exists, a lost
# laptop takes the deploy with it.
BEHIND="$(git rev-list --count "origin/$BRANCH..$BRANCH" 2>/dev/null || echo '?')"
# …and the other direction, because it is the one that loses work silently: a branch
# that never pulled the bot's commits ships a production that is missing them.
AHEAD="$(git rev-list --count "$BRANCH..origin/$BRANCH" 2>/dev/null || echo 0)"
[[ "$BEHIND" == "?" || "$AHEAD" == "0" ]] \
  || die "origin/$BRANCH has $AHEAD commit(s) $BRANCH does not — git pull --rebase origin $BRANCH first, or those commits never reach the box"
if [[ "$BEHIND" == "?" ]]; then
  say "origin/$BRANCH is unknown — fetching to find out"
  git fetch -q origin "$BRANCH" || die "cannot reach origin (offline?); refusing to ship"
  BEHIND="$(git rev-list --count "origin/$BRANCH..$BRANCH")"
fi
if [[ "$BEHIND" != "0" ]]; then
  say "$BEHIND commit(s) ahead of origin — pushing"
  git push -q origin "$BRANCH" || die "push failed; nothing was shipped"
fi
git branch -r --contains "$SHA" | grep -q "origin/$BRANCH" || die "$SHORT is not on origin/$BRANCH"
say "origin/$BRANCH has $SHORT"

# ── 2. where the box actually stands ────────────────────────────────────────────────
# Everything downstream is measured against this, not against this repo's reflog: the
# branch moved yesterday is not the same thing as the code that is running.
ONBOX="$(box "cd '$REPO_DIR' && git -c safe.directory='$REPO_DIR' rev-parse HEAD")" \
  || die "cannot read $REPO_DIR/HEAD on $HOST"
say "the box is at ${ONBOX:0:7}"
# auto-update.sh merges with --ff-only, which is a polite way of saying it gives up when
# the box has a commit that main does not. Find that out here rather than in a journal.
if git cat-file -e "$ONBOX" 2>/dev/null && ! git merge-base --is-ancestor "$ONBOX" "$SHA" 2>/dev/null; then
  die "the box has commits that $BRANCH does not — --ff-only would refuse; reconcile $REPO_DIR first"
fi

# A new tracked path that already exists on the box UNTRACKED makes `merge --ff-only`
# refuse the whole update (and the nightly timer dies silently with it). Diffed against
# $ONBOX — the code the box runs — so it catches exactly what this ship is adding.
# --untracked-files=all matters: the default collapses a directory to "?? build/" and a
# directory name never matches the file paths being added, so the check would find nothing.
# What it cannot see is a path the box's own .gitignore hides: measured in a scratch repo
# (two clones, one seed), a merge that adds a path which exists on the receiver IGNORED goes
# straight through — rc=0, Fast-forward, the box's copy replaced by the incoming one, status
# listing nothing beforehand. Ignoring therefore trades a loud refusal for a silent
# overwrite, which is why the rules in .gitignore are paired with
# test/repo-ignore-hygiene.test.js asserting those paths stay untracked HERE: the only
# defence left is never force-adding them in the first place.
NEW_PATHS="$(git diff --name-only --diff-filter=A "$ONBOX" "$BRANCH" 2>/dev/null || true)"
if [[ -n "$NEW_PATHS" ]]; then
  # Read-only probe as the unprivileged ssh user; if it cannot read the tree the ship
  # still goes ahead, because the journal assertion downstream catches a refused merge.
  UNTRACKED="$(box "cd '$REPO_DIR' && git -c safe.directory='$REPO_DIR' status --porcelain --untracked-files=all" \
    | sed -n 's/^?? //p' || true)"
  COLLIDING="$(printf '%s\n' "$NEW_PATHS" | grep -Fxf <(printf '%s\n' "$UNTRACKED") || true)"
  [[ -z "$COLLIDING" ]] || die "these paths are untracked on the box and would be overwritten: $(printf '%s' "$COLLIDING" | tr '\n' ' ')"
fi

# Shipping a sha that is already live is a no-op, and saying so beats starting a unit
# that answers "Already up to date" — a line containing no sha, which the journal
# assertion downstream would read as a failed deploy. Checked before any transport work,
# because when the box already runs this commit there is nothing to stage either.
if [[ "$ONBOX" == "$SHA" ]]; then
  say "the box is already at $SHORT — nothing to deploy"
  exit 0
fi

# ── 3. which transport can this box use? ───────────────────────────────────────────
# Asked of the box, not of the README. A read-only key that is present answers
# `ls-remote` in about a second; a missing one, or a box with no route, does not.
ORIGIN_WAS="$(box "cd '$REPO_DIR' && git -c safe.directory='$REPO_DIR' remote get-url origin" || true)"
GITHUB_OK=0
if [[ "$ORIGIN_WAS" == *github.com* ]]; then
  if rootcmd "cd '$REPO_DIR' && timeout 25 git ls-remote origin HEAD | head -1" | grep -qE '[0-9a-f]{40}'; then
    GITHUB_OK=1
  fi
fi
if [[ "$GITHUB_OK" == "1" ]]; then
  say "the box can reach GitHub — it will fetch $SHORT itself"
else
  say "WARNING: the box cannot fetch from GitHub (origin=${ORIGIN_WAS:-unset}); deploying through the handover bundle"
fi

# ── 4. the bundle, only when the box cannot fetch for itself ────────────────────────
# Not built when GitHub works: ~40 MB for nothing, and a bundle nobody refreshes is a
# remote that lies. The fallback always rebuilds from $BRANCH here, so whatever is
# sitting in the handover directory from some past ship is never trusted.

# Put origin back no matter how we leave a repointed box. A box left fetching a bundle
# is precisely how the timer spent days answering "Already up to date" about the code it
# already had while newer commits sat unreferenced on GitHub. Best effort: if the ssh
# session is gone there is nothing to do but say so, and say where to fix it.
restore_origin() {
  if rootcmd "cd '$REPO_DIR' && git remote set-url origin '$ORIGIN_WAS'"; then
    say "origin put back at ${ORIGIN_WAS}"
  else
    echo "ship-to-box: COULD NOT RESTORE origin on the box — it is still pointed at the bundle." >&2
    echo "ship-to-box:   ssh in and run: git -C $REPO_DIR remote set-url origin '$ORIGIN_WAS'" >&2
  fi
}

if [[ "$GITHUB_OK" == "0" ]]; then
  TMP="$(mktemp "${TMPDIR:-/tmp}/tukuk-ship.XXXXXX")"; trap 'rm -f "$TMP"' EXIT
  git bundle create "$TMP" "$BRANCH" >/dev/null 2>&1 || die "git bundle failed"
  git bundle verify "$TMP" >/dev/null 2>&1 || die "the bundle does not verify against this repo"
  LOCAL_BYTES=$(stat -c %s "$TMP")
  say "bundle ready: $LOCAL_BYTES bytes, complete history, tip $SHORT"

  box "mkdir -p \"\$(dirname '$BUNDLE_ON_BOX')\"" || die "cannot prepare the handover directory on $HOST"
  scp -q -o StrictHostKeyChecking=no "$TMP" "$HOST:$BUNDLE_ON_BOX.new" || die "scp failed"
  REMOTE_BYTES="$(box "stat -c %s '$BUNDLE_ON_BOX.new' 2>/dev/null || echo 0")"
  [[ "$REMOTE_BYTES" == "$LOCAL_BYTES" ]] || die "the bundle arrived as $REMOTE_BYTES bytes, expected $LOCAL_BYTES"
  say "transferred: $REMOTE_BYTES bytes verified at the far end"

  # Verify inside the real repo: a bundle can be well-formed and still un-mergeable here.
  box "cd '$REPO_DIR' && git -c safe.directory='$REPO_DIR' bundle verify '$BUNDLE_ON_BOX.new'" >/dev/null \
    || die "the box cannot verify this bundle inside $REPO_DIR"

  box "mv '$BUNDLE_ON_BOX' '$BUNDLE_ON_BOX.pre-$SHORT' 2>/dev/null || true
       chmod 600 '$BUNDLE_ON_BOX.new' && mv '$BUNDLE_ON_BOX.new' '$BUNDLE_ON_BOX'
       ls -l '$BUNDLE_ON_BOX'" >/dev/null || die "could not install the bundle on the box"
  say "bundle installed (previous copy kept as .pre-$SHORT)"

  # Point origin at it for the duration; `restore_origin` on the EXIT trap puts it back.
  rootcmd "cd '$REPO_DIR' && git remote set-url origin '$BUNDLE_ON_BOX'" \
    || die "could not repoint origin at the bundle"
  # Both cleanups in one trap: a second `trap … EXIT` replaces the first, so the temp
  # bundle would otherwise be left in /tmp whenever the ship got this far.
  trap 'rm -f "${TMP:-}"; restore_origin' EXIT
fi

# `--no-deploy` means different things on the two paths, and the degraded one has a
# consequence worth saying out loud: the bundle is installed, but the EXIT trap puts
# origin back straight away, so nothing later fetches it by itself. Handing over a
# half-staged deploy is how a rescue turns into a mystery, so print the two commands
# that finish it instead of implying they are already arranged.
if [[ "$DEPLOY" != "1" ]]; then
  if [[ "$GITHUB_OK" == "1" ]]; then
    say "--no-deploy: $SHORT is on GitHub and the box was not disturbed"
    say "           tukuk-update.timer picks it up (~04:30), or now: sudo systemctl start tukuk-update.service"
  else
    say "--no-deploy: the bundle is installed at $BUNDLE_ON_BOX"
    say "           origin goes back to ${ORIGIN_WAS} as this script exits, so to deploy by hand:"
    say "             sudo git -C $REPO_DIR remote set-url origin '$BUNDLE_ON_BOX'"
    say "             sudo systemctl start tukuk-update.service"
    say "           then put the URL back, or the box stops seeing GitHub again."
  fi
  exit 0
fi

# ── 5. deploy through the repo's own update unit ────────────────────────────────────
say "starting tukuk-update.service as root (password read from $PWFILE on the box)"
rootcmd "systemctl start tukuk-update.service" || die "could not start the update unit"

# The unit is Type=oneshot and auto-update.sh does a fetch + merge + restart, so the
# journal is the proof — but it lands a few seconds late. Measured ships on this box:
# five commits in nine seconds, two commits in seven, both ~40 MB of bundle; a fetch
# that finds nothing costs about six. This polls for up to forty and stops the moment
# the shipped sha shows up, so a slow merge is not called a failure.
JOURNAL=""
for _ in $(seq 1 20); do
  sleep 2
  JOURNAL="$(rootcmd "journalctl -u tukuk-update.service --since '-2 min' --no-pager | tail -25" || true)"
  printf '%s\n' "$JOURNAL" | grep -qF "$SHORT" && break
done
printf '%s\n' "$JOURNAL" | sed 's/^/[tukuk-update] /'
[[ -n "$JOURNAL" ]] || die "tukuk-update.service logged nothing — is the unit installed? (systemctl cat tukuk-update.service)"
printf '%s\n' "$JOURNAL" | grep -qE "merge-failed|working tree changed" && die "the merge was refused: the box's tree has diverged"
printf '%s\n' "$JOURNAL" | grep -qF "$SHA" || printf '%s\n' "$JOURNAL" | grep -qF "$SHORT" \
  || die "the update did not report $SHORT — check: systemctl status tukuk-update.service"

# ── 6. confirm the running process is the shipped code ──────────────────────────────
LIVE="$(box "cd '$REPO_DIR' && git -c safe.directory='$REPO_DIR' rev-parse HEAD")"
[[ "$LIVE" == "$SHA" ]] || die "$REPO_DIR is at $LIVE, not $SHA"
say "repo on the box: $LIVE"
# Poll, do not sample. auto-update.sh logs "done" the instant `systemctl restart`
# returns, and the app takes several seconds to bind 3000 — the first read after a real
# ship came back empty three seconds in, on a deploy that then reported ok on /health.
# Calling a booting server unhealthy would train whoever reads this to ignore it.
HEALTH=""
for _ in $(seq 1 15); do
  sleep 2
  HEALTH="$(box "curl -s --max-time 10 http://127.0.0.1:3000/health" || true)"
  printf '%s\n' "$HEALTH" | grep -q '"status":"ok"' && break
done
printf '%s\n' "$HEALTH" | grep -q '"status":"ok"' \
  || say "WARNING: /health never answered ok in 30 s — check: systemctl status tukuk-os"
# The box keeps its own record of every update — stage, result, the two commits — and
# publishes it on /health (src/update-status.js, written by scripts/auto-update.sh). It
# exists because "nothing happened" and "the timer died in March" look identical from
# outside, so a deploy that only checks git HEAD is checking the wrong thing: the record
# proves the service actually restarted onto this commit. A WARNING, not a death, because
# the nightly timer can legitimately overtake this record minutes after a ship.
if printf '%s\n' "$HEALTH" | grep -qF "\"to\":\"$SHA\""; then
  # `[^}]*` and not `.*`: the record has no nested object, and a greedy match on a
  # single-line JSON response would happily print the rest of /health too.
  say "update record agrees: $(printf '%s\n' "$HEALTH" | grep -o '"update":{[^}]*}' | head -1)"
else
  say "WARNING: /health does not report an update to $SHORT — the tree is right, but read"
  say "         https://$ZONE/health's update block before calling this shipped."
fi
say "public site: https://$ZONE/ — CSS/JS go out with s-maxage=300, so /theme.css and the rest
        refresh themselves at the edge within about five minutes. Images, icons and fonts carry
        s-maxage=604800 — a changed one can sit a week, and that is what deploy/purge-edge-cache.sh
        is for; it needs a token with Zone:Read + Zone:Cache Purge (see its header). Rendered HTML
        measured DYNAMIC at the edge, so the read below is a live one."

# ── 7. and through the edge, not just the loopback ──────────────────────────────
# Everything above is read on 127.0.0.1 over ssh. tukuk.org is the app reached through
# the Cloudflare tunnel, so this is the only check that covers the tunnel: the service
# can restart onto the right commit and the public site still be down, and no loopback
# curl can see that. GET /health measured cf-cache-status: DYNAMIC twice on 29 Oct 2026
# (as did the homepage, so HTML is not edge-cached on this zone), which means this poll is
# reading the app and not a stored copy. A WARNING, not a death: the deploy on the box is a
# fact by this point, and this read is about the road to it.
EDGE=""
for _ in $(seq 1 15); do
  sleep 2
  EDGE="$(curl -s --max-time 15 "https://$ZONE/health" || true)"
  printf '%s\n' "$EDGE" | grep -q '"status":"ok"' && break
done
if printf '%s\n' "$EDGE" | grep -q '"status":"ok"'; then
  if printf '%s\n' "$EDGE" | grep -qF "\"to\":\"$SHA\""; then
    say "https://$ZONE/health serves the update record for $SHORT — tunnel and edge included"
  else
    say "https://$ZONE/ is up, but its update record is not this ship yet — read it yourself"
  fi
else
  say "WARNING: https://$ZONE/health never answered ok from this machine in 30 s while the box"
  say "         itself is healthy: the app is deployed, the route to it is not. Check on the box:"
  say "         systemctl status cloudflared   (a token-managed tunnel has no cert, so"
  say "         'cloudflared tunnel list' cannot work here — it is not evidence of anything)"
fi
say "shipped and deployed: $SHORT"
