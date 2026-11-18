#!/usr/bin/env bash
# ==============================================================================
# consolidate-layout.sh — make the server ONE folder: /opt/tukuk-os.
#
# BEFORE (five top-level places, five things to remember in every script, backup
# and rebuild doc):
#     /opt/tukuk-os              the app
#     /opt/tukuk-builder         the Builder (separate git repo)
#     /var/www/tukuk-play        the published game
#     /home/tukuk/models         GGUF / ONNX weights
#     /home/tukuk/bin            the godot binary
#     /home/tukuk/station-break  the game source (separate git repo)
#
# AFTER (one folder; paths.sh derives everything from it):
#     /opt/tukuk-os/apps/builder
#     /opt/tukuk-os/apps/play
#     /opt/tukuk-os/models
#     /opt/tukuk-os/bin
#     /opt/tukuk-os/game
#
# The old absolute paths are LEFT IN PLACE AS SYMLINKS. That is the whole safety
# story: the repo, an installed nginx conf and a running unit all still name
# /opt/tukuk-builder for a while, and every one of them keeps working because the
# symlink resolves. `--prune-links` removes them later, and it refuses while the
# repo still mentions them, so a stale reference cannot be deleted out from under
# itself.
#
# IDEMPOTENT: run it as often as you like. A pair already in its final shape is
# skipped. A pair that is genuinely ambiguous (both sides a real directory) is
# REFUSED rather than merged — merging two live trees is how you lose one of them.
#
# USAGE:
#   sudo bash scripts/consolidate-layout.sh --dry-run     # say what would move
#   sudo bash scripts/consolidate-layout.sh               # do it
#   sudo bash scripts/consolidate-layout.sh --prune-links # drop the compatibility symlinks
#
# CROSS-FILESYSTEM: /home and /opt are usually the same disk, in which case the move
# is a rename (instant, no extra space). If they are NOT, this refuses: `mv` would
# silently double the space used, and a full root filesystem takes the whole box
# down. Set CONSOLIDATE_COPY=1 to allow a verified copy instead.
#
# NOT HANDLED HERE: /var/www/tukuk-mirror. That is the GCP failover VM — a different
# machine. Same for anything under /srv/tukuk-mirror.
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../deploy/paths.sh
. "$HERE/deploy/paths.sh"

DRY=0
PRUNE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY=1 ;;
    --prune-links) PRUNE=1 ;;
    -h|--help)     sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[0;33m➜\033[0m %s\n' "$*"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$*"; }
say()  { printf '%s\n' "$*"; }

# name|legacy|new|mode
#   move   = the bytes move; the legacy path becomes a symlink
#   inward = the bytes STAY; the new path becomes a symlink into the folder
#
# models is `inward` on purpose. litert-lm's registry stored the absolute path
# /home/tukuk/models/<file> at import time, and that registry is outside this repo —
# moving the weights would leave it pointing at nothing, and the failure is a model
# that silently stops loading. A symlink gives the "one folder" property (everything
# you need is under /opt/tukuk-os) without invalidating a path we do not control.
PAIRS=(
  "builder|$TUKUK_LEGACY_BUILDER|$TUKUK_BUILDER_DIR|move"
  "play|$TUKUK_LEGACY_PLAY|$TUKUK_PLAY_DIR|move"
  "game|$TUKUK_LEGACY_GAME|$TUKUK_GAME_DIR|move"
  "bin|$TUKUK_LEGACY_BIN|$TUKUK_BIN_DIR|move"
  "models|$TUKUK_LEGACY_MODELS|$TUKUK_MODEL_DIR|inward"
)

# Root is required for the real thing: it writes to /opt and /var/www. It is deliberately NOT
# required when TUKUK_ROOT points somewhere else, because that is a rehearsal against a
# scratch directory — the only way to exercise a freshly formatted box (or CI) without
# formatting one. The check keys off the DEFAULT root, so a non-root run against the app
# folder is still refused.
if [ "$(id -u)" -ne 0 ] && [ "$TUKUK_ROOT" = "/opt/tukuk-os" ]; then
  bad "run as root: sudo bash $0"; exit 1
fi
[ -d "$TUKUK_ROOT" ] || { bad "no $TUKUK_ROOT — this is not the app folder, so there is nothing to consolidate into."; exit 1; }

# ── --prune-links ──────────────────────────────────────────────────────────────
if [ "$PRUNE" -eq 1 ]; then
  say "Pruning the compatibility symlinks under /opt/tukuk-os"
  # A symlink may only go once no file in the repo still ACTS on the path. Otherwise
  # the prune deletes the thing that was keeping the reference alive, and the next
  # deploy breaks a hostname at 04:30 with nobody watching.
  #
  # Comments do not count. Several files explain where a thing used to live ("it used to
  # be /opt/tukuk-builder/..."), and that history is worth keeping — but a raw text search
  # would refuse to prune forever because of it, so the last step of this migration could
  # never be run. Same rule as test/server-layout.test.js: `#` in shell/nginx/systemd,
  # `//` in JS.
  STALE=0
  for row in "${PAIRS[@]}"; do
    IFS='|' read -r name legacy new mode <<<"$row"
    [ -L "$legacy" ] || continue
    hits="$(grep -rIn --exclude-dir=node_modules --exclude-dir=.git -- "$legacy" \
              "$TUKUK_ROOT/deploy" "$TUKUK_ROOT/scripts" "$TUKUK_ROOT/src" "$TUKUK_ROOT/test" 2>/dev/null \
            | grep -v "$TUKUK_ROOT/deploy/paths.sh:" \
            | grep -v "$TUKUK_ROOT/scripts/consolidate-layout.sh:" \
            | grep -v "$TUKUK_ROOT/test/server-layout.test.js:" \
            | while IFS= read -r hit; do
                body="${hit#*:*:}"                      # strip "file:line:" off the front
                [[ "$body" =~ ^[[:space:]]*(#|//) ]] && continue
                printf '%s\n' "$hit"
              done)"
    if [ -n "$hits" ]; then
      bad "$legacy still used by: $(echo "$hits" | head -5 | sed "s|$TUKUK_ROOT/||" | tr '\n' ' ')"
      STALE=1
    else
      info "removing $legacy → $new"
      [ "$DRY" -eq 1 ] || rm -f "$legacy"
    fi
  done
  [ "$STALE" -eq 0 ] || { say; bad "not everything is repointed — fix the files above and rerun."; exit 1; }
  ok "no compatibility symlinks left"
  exit 0
fi

say "The one folder: $TUKUK_ROOT"
say

MOVES=0; LINKS=0; CREATED=0; SKIP=0; CONFLICT=0

for row in "${PAIRS[@]}"; do
  IFS='|' read -r name legacy new mode <<<"$row"
  say "$name"

  # Already in its final shape? A symlink where the legacy path used to be is the
  # finished state for `move`; for `inward` the finished state is the reverse.
  if [ -L "$legacy" ]; then
    if [ "$(readlink -f "$legacy")" = "$(readlink -f "$new" 2>/dev/null)" ]; then
      ok "already consolidated ($legacy → $new)"; SKIP=$((SKIP+1)); continue
    fi
    bad "$legacy is a symlink to $(readlink "$legacy"), not to $new — resolve this by hand"
    CONFLICT=$((CONFLICT+1)); continue
  fi

  if [ -e "$legacy" ] && mountpoint -q "$legacy" 2>/dev/null; then
    bad "$legacy is a mount point — an empty directory can be replaced by a symlink, a mount cannot"
    CONFLICT=$((CONFLICT+1)); continue
  fi

  if [ ! -e "$legacy" ]; then
    if [ -d "$new" ]; then ok "nothing at $legacy; $new already in place"; SKIP=$((SKIP+1)); continue; fi
    # A freshly formatted box has no legacy path at all — there this is the normal case, not
    # an oddity, and it is what makes the layout EXIST: apps/ is the parent `git clone` needs
    # before it can put the Builder inside it, bin/ is where the Godot binary goes, models/ is
    # what src/config.js reads. An `inward` pair reaching here means a box with no weights yet,
    # so a real directory is correct; on the old box the legacy dir exists and this is skipped.
    info "nothing at $legacy — creating $new"
    if [ "$DRY" -eq 0 ]; then
      # Same owner as the checkout, because the Builder and the model imports write here as
      # tukuk; a root-owned parent is the kind of difference that only shows up later, when
      # something runs as the service user and silently cannot create its own directory.
      if id -u tukuk >/dev/null 2>&1; then
        install -d -o tukuk -g tukuk "$new"
      else
        install -d "$new"
      fi
    fi
    CREATED=$((CREATED+1)); continue
  fi

  if [ -e "$new" ] && [ ! -L "$new" ]; then
    # Both sides hold something. An EMPTY destination is the one case worth resolving
    # automatically: it is almost always a directory that existed before this layout did
    # (src/config.js now defaults to <root>/models, so a stale empty models/ is the likely
    # shape). Refusing there would leave the weights in the old place while the app reads an
    # empty folder — precisely the failure this migration exists to prevent. A destination
    # with anything in it is still refused: merging two live trees loses one of them.
    if [ -d "$new" ] && [ -z "$(ls -A "$new" 2>/dev/null)" ]; then
      info "$new exists but is empty — replacing it"
      if [ "$DRY" -eq 0 ] && ! rmdir "$new"; then
        bad "could not remove the empty $new"
        CONFLICT=$((CONFLICT+1)); continue
      fi
    else
      bad "BOTH $legacy and $new exist as real directories — refusing to merge two live trees."
      bad "  move one aside by hand, or point the repo at the one you want, then rerun."
      CONFLICT=$((CONFLICT+1)); continue
    fi
  fi

  # ── inward: the bytes stay, the new path is the symlink ──────────────────────
  if [ "$mode" = "inward" ]; then
    info "keeping $legacy, linking $new → $legacy"
    if [ "$DRY" -eq 0 ]; then
      mkdir -p "$(dirname "$new")"
      ln -sfn "$legacy" "$new"
    fi
    LINKS=$((LINKS+1)); continue
  fi

  # ── move: bytes move, legacy becomes the symlink ──────────────────────────────
  # Count the tree first: this is what "the move worked" is measured against, and
  # it is the check that would have caught a truncated cross-device copy.
  before="$(find "$legacy" -mindepth 1 2>/dev/null | wc -l)"

  if [ "$(stat -c %d "$legacy")" != "$(stat -c %d "$(dirname "$new")" 2>/dev/null || stat -c %d "$TUKUK_ROOT")" ]; then
    if [ "${CONSOLIDATE_COPY:-0}" != "1" ]; then
      bad "$legacy and $(dirname "$new") are on different filesystems — a plain move would"
      bad "  copy every byte and could fill the disk. Free space first, then either"
      bad "  mount them together, or rerun with: CONSOLIDATE_COPY=1 sudo bash $0"
      CONFLICT=$((CONFLICT+1)); continue
    fi
  fi

  if [ "$DRY" -eq 1 ]; then
    info "would move $legacy → $new ($before entries), then symlink $legacy → $new"
    MOVES=$((MOVES+1)); continue
  fi

  mkdir -p "$(dirname "$new")"
  if ! mv "$legacy" "$new"; then
    bad "mv $legacy → $new failed; nothing was changed for this pair"
    CONFLICT=$((CONFLICT+1)); continue
  fi
  after="$(find "$new" -mindepth 1 2>/dev/null | wc -l)"
  if [ "$before" != "$after" ]; then
    # Put it back rather than leave a half-moved tree where a symlink is expected.
    mv "$new" "$legacy"
    bad "entry count changed ($before → $after) — moved back, this pair untouched"
    CONFLICT=$((CONFLICT+1)); continue
  fi
  ln -sfn "$new" "$legacy"
  ok "moved → $new ($after entries), $legacy now a symlink"
  MOVES=$((MOVES+1))
done

# A running unit holds the moved directory open by inode, which keeps working, but
# its configured WorkingDirectory is what the NEXT start uses. daemon-reload costs
# nothing and stops the two from disagreeing.
if [ "$MOVES" -gt 0 ] && [ "$DRY" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
fi

say
say "Summary: $MOVES moved, $LINKS linked in place, $CREATED created, $SKIP already fine, $CONFLICT needing a decision."
if [ "$DRY" -eq 1 ]; then
  say "Dry run — nothing was changed. Rerun without --dry-run to apply."
fi
if [ "$CONFLICT" -gt 0 ]; then
  exit 1
fi
if [ "$MOVES" -eq 0 ] && [ "$LINKS" -eq 0 ] && [ "$CREATED" -eq 0 ] && [ "$SKIP" -eq 0 ]; then
  bad "no pair was even inspected — check TUKUK_ROOT ($TUKUK_ROOT)"
  exit 1
fi

# The end state, asserted rather than assumed: one real directory, and the legacy
# path resolving into it.
say
for row in "${PAIRS[@]}"; do
  IFS='|' read -r name legacy new mode <<<"$row"
  [ -d "$new" ] || continue
  if [ -e "$legacy" ] && [ "$(readlink -f "$legacy")" != "$(readlink -f "$new")" ]; then
    bad "$legacy does not resolve to $new"
    exit 1
  fi
  ok "$name → $new"
done
say
ok "everything lives under $TUKUK_ROOT"
if [ "$MOVES" -eq 0 ] && [ "$LINKS" -eq 0 ] && [ "$CREATED" -gt 0 ]; then
  say "  Fresh box: the folders were created. Nothing to migrate, no symlinks to prune."
elif [ "$MOVES" -gt 0 ] || [ "$LINKS" -gt 0 ]; then
  say "  The legacy paths are symlinks now. Once a deploy has gone green, drop them:"
  say "    sudo bash scripts/consolidate-layout.sh --prune-links"
fi
