#!/usr/bin/env bash
# ==============================================================================
# setup-autosync.sh — turn /opt/tukuk-os into a real git clone so that
# tukuk-update.timer (root, 04:30) auto-pulls new words + code.
#
#   • Auth: read-only SSH deploy key (/root/.ssh/tukuk_deploy) — no token baked
#     into the URL, no interactive login.
#   • Align the working tree to origin/main using `git reset --hard` — files NOT
#     tracked by git (data/, .env, node_modules) stay safe.
#   • Idempotent: can be re-run safely.
# ==============================================================================
set -uo pipefail

REPO="/opt/tukuk-os"
REMOTE="git@github.com:tukuk/tukuk-os.git"
BRANCH="main"

[[ "${EUID}" -eq 0 ]] || { echo "[autosync] run as root: sudo bash $0"; exit 1; }
cd "$REPO" || { echo "[autosync] $REPO missing"; exit 1; }

# 0) The deploy key itself --------------------------------------------------------
# A freshly installed box has NO identity for github.com. Nothing here used to create
# one: the fetch in step 4 then fails, `tukuk-update.timer` quietly stops deploying,
# and every future fix has to be carried to the machine by hand — which is exactly how
# 29 Oct 2026 ended up needing a visit. Generate only when absent, so a rerun never
# rotates a key that GitHub already trusts.
CREATED_KEY=0
# /root/.ssh does not exist on a freshly installed box, and ssh-keygen will not make it.
mkdir -p /root/.ssh; chmod 700 /root/.ssh
if [[ ! -f /root/.ssh/tukuk_deploy ]]; then
  if ssh-keygen -q -t ed25519 -N '' -C "tukuk-os-box-$(hostname)" -f /root/.ssh/tukuk_deploy; then
    CREATED_KEY=1
    echo "[autosync] created /root/.ssh/tukuk_deploy"
  else
    echo "[autosync] FAILED to create the deploy key — auto-update cannot work without it."
    exit 1
  fi
fi
chmod 600 /root/.ssh/tukuk_deploy 2>/dev/null || true

# 1) SSH config for the deploy key (root) ------------------------------------------
mkdir -p /root/.ssh; chmod 700 /root/.ssh
if ! grep -q "^Host github.com" /root/.ssh/config 2>/dev/null; then
  cat >> /root/.ssh/config <<'CFG'
Host github.com
  User git
  IdentityFile /root/.ssh/tukuk_deploy
  IdentitiesOnly yes
CFG
  chmod 600 /root/.ssh/config
fi
ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null || true
sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts 2>/dev/null || true

# 2) Let git access a dir owned by another user (we run as root) -------------
# IMPORTANT: use `--system` (/etc/gitconfig), NOT `--global`. The systemd timer
# runs auto-update with an EMPTY $HOME, so git does NOT read
# ~/.gitconfig — safe.directory only takes effect if it is in the system config.
git config --system --add safe.directory "$REPO" 2>/dev/null || true
git config --global --add safe.directory "$REPO" 2>/dev/null || true

# 2b) Hand the public half to GitHub ---------------------------------------------
# This is the one step that needs an account, so it is impossible to miss: printed on
# the box, with the exact place to paste it. A token with repo-admin scope registers it
# on its own. Read-only ALWAYS — a writable deploy key is a path to production that no
# longer needs anyone's password.
if [[ "$CREATED_KEY" == "1" ]]; then
  TOK="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$TOK" ]] && curl -sf -X POST -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" \
       -H "Content-Type: application/json" \
       -d "{\"title\":\"tukuk-os-box-$(hostname)\",\"key\":\"$(cat /root/.ssh/tukuk_deploy.pub)\",\"read_only\":true}" \
       https://api.github.com/repos/tukuk/tukuk-os/keys >/dev/null; then
    echo "[autosync] deploy key registered on tukuk/tukuk-os (read-only)."
  else
    echo "[autosync] ⚠ REGISTER THIS KEY before auto-update can run — GitHub → tukuk/tukuk-os"
    echo "            → Settings → Deploy keys → Add deploy key, and DO NOT tick 'Allow write access':"
    sed 's/^/            /' /root/.ssh/tukuk_deploy.pub
  fi
fi

# 3) Test SSH auth ------------------------------------------------------------
echo "=== ssh -T git@github.com (expect: successfully authenticated) ==="
ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1 | head -2 || true

# 4) Init + remote + align to origin/main --------------------------------
if [[ ! -d "$REPO/.git" ]]; then
  echo "[autosync] git init (branch $BRANCH) ..."
  git init -q -b "$BRANCH" "$REPO"
else
  echo "[autosync] .git already exists — skip init."
fi

git -C "$REPO" remote remove origin 2>/dev/null || true
git -C "$REPO" remote add origin "$REMOTE"

echo "[autosync] fetch origin/$BRANCH ..."
if ! git -C "$REPO" fetch -q origin "$BRANCH"; then
  echo "[autosync] FAILED: fetch origin/$BRANCH (auth/network?)"
  exit 1
fi

echo "[autosync] reset --hard origin/$BRANCH (keep untracked: data/, .env, node_modules) ..."
git -C "$REPO" reset -q --hard "origin/$BRANCH"

echo "=== result: branch / HEAD / origin ==="
git -C "$REPO" rev-parse --abbrev-ref HEAD
echo "HEAD=$(git -C "$REPO" rev-parse --short HEAD)  origin=$(git -C "$REPO" rev-parse --short origin/$BRANCH)"
echo "=== status (empty = clean, auto-merge will run) ==="
git -C "$REPO" status -sb | head -5
echo "[autosync] DONE."
