#!/usr/bin/env bash
# r2-inventory.sh — what is inside the Cloudflare R2 buckets, and is it still free?
#
# R2 is the rung the failover brain serves FIRST during an outage (see
# deploy/GCP-FAILOVER.md), and Cloudflare's free R2 tier ends at **10 GB stored per
# account** (all buckets together) plus 1M Class A / 10M Class B operations per month.
# R2 egress is free, so the only ways this storage can cost money are growth and op counts.
# The audit makes both visible instead of assumed.
#
# Read-only: it lists objects, it never writes or deletes.
#
# WHERE TO RUN IT: it needs a credential with **Account · R2 Storage · Read**. The box's
# `cfut_…` token has Workers scope only (verified: /workers/scripts answers, every /r2/…
# call returns "Authentication error") — by design, because the box writes R2 through the
# backup *Worker* (`BACKUP_WORKER_URL` + secret), never through the R2 API. So run this on a
# machine with a wrangler login, or mint an R2-read token for the box first.
#
#   bash scripts/r2-inventory.sh                 # every bucket in the account
#   R2_BUCKET=tukuk-fallback bash scripts/r2-inventory.sh    # just one
#
# Exit 1 when something breaks the free posture: the account over 60% of the 10 GB ceiling,
# or a prefix whose keys are timestamped still being written (see DATED_CUTOFF).
#
# The API token is read from the environment, the repo .env, or wrangler's cached OAuth
# login, in that order. It is handed to curl on stdin only — never argv, never printed.
set -uo pipefail
cd "$(dirname "$0")/.."
ONLY="${R2_BUCKET:-}"
ACC="${CLOUDFLARE_ACCOUNT_ID:-391d9aa59cfcc5ec44c3d25c855c45cb}"
CEILING_GB=10
WARN_GB=6

TOK="${CLOUDFLARE_API_TOKEN:-}"
[ -n "$TOK" ] || TOK=$(grep -m1 '^CLOUDFLARE_API_TOKEN=' .env 2>/dev/null | cut -d= -f2- | tr -d '"')
if [ -z "$TOK" ] && [ -f "$HOME/.config/.wrangler/config/default.toml" ]; then
  # the .env token is empty on some machines; wrangler's OAuth login works on the same API
  TOK=$(awk -F'"' '/^oauth_token/ {print $2; exit}' "$HOME/.config/.wrangler/config/default.toml")
fi
[ -n "$TOK" ] || { echo "no usable Cloudflare token (env, .env, or wrangler OAuth)"; exit 1; }

api() { # $1 = path under /accounts/$ACC
  printf 'Authorization: Bearer %s\n' "$TOK" \
    | curl -s -m 60 -H @- "https://api.cloudflare.com/client/v4/accounts/$ACC$1"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== R2 inventory (account ${ACC:0:8}…, ${CEILING_GB} GB free across ALL buckets)"
api '/r2/buckets' > "$WORK/buckets.json"
python3 - "$WORK" "$ONLY" <<'PY' || exit 1
import json, sys, os
d = json.load(open(os.path.join(sys.argv[1], 'buckets.json')))
if not d.get('success'):
    err = (d.get('errors') or [{}])[0]
    print('  API refused the bucket list: %s (code %s)' % (err.get('message'), err.get('code')))
    print('  This needs a token with Account · R2 Storage · Read. The box\'s cfut_ token is')
    print('  Workers-only (it writes R2 through the backup Worker instead), so run this')
    print('  where wrangler is logged in, or mint an R2-read token and set it in .env.')
    raise SystemExit(1)
r = d.get('result')
bs = r.get('buckets') if isinstance(r, dict) else r
only = sys.argv[2]
names = [b.get('name') for b in (bs or []) if not only or b.get('name') == only]
open(os.path.join(sys.argv[1], 'buckets'), 'w').write('\n'.join(names) + ('\n' if names else ''))
PY
[ -s "$WORK/buckets" ] || { echo "  no buckets${ONLY:+ named $ONLY} — nothing to audit"; exit 1; }
echo "  buckets: $(tr '\n' ' ' < "$WORK/buckets")"

for BUCKET in $(cat "$WORK/buckets"); do
  CUR=''
  for page in $(seq 1 60); do
    if [ -z "$CUR" ]; then Q="objects?per_page=1000"; else Q="objects?per_page=1000&cursor=$CUR"; fi
    api "/r2/buckets/$BUCKET/$Q" > "$WORK/page.json"
    python3 - "$WORK" "$BUCKET" <<'PY' || exit 1
import json, sys, os
try:
    d = json.load(open(os.path.join(sys.argv[1], 'page.json')))
except Exception as e:
    print('  %s: unreadable API response (%s) — check the token and account id' % (sys.argv[2], e))
    raise SystemExit(1)
if not d.get('success'):
    print('  %s: API error: %s' % (sys.argv[2], d.get('errors'),))
    raise SystemExit(1)
with open(os.path.join(sys.argv[1], 'objects.jsonl'), 'a') as out:
    for o in (d.get('result') or []):
        out.write(json.dumps({'bucket': sys.argv[2], 'key': o.get('key'),
                              'size': int(o.get('size') or 0),
                              'class': o.get('storage_class'),
                              'modified': o.get('last_modified')}) + '\n')
ri = d.get('result_info') or {}
cur = ri.get('cursor', '') if ri.get('is_truncated') else ''
open(os.path.join(sys.argv[1], 'cursor'), 'w').write(cur or '')
PY
    CUR=$(cat "$WORK/cursor" 2>/dev/null || true)
    rm -f "$WORK/cursor"
    [ -z "$CUR" ] && break
  done
  echo "  $BUCKET: paged in $page page(s)"
done

python3 - "$WORK" "$CEILING_GB" "$WARN_GB" "${DATED_CUTOFF:-2026-10-29}" "${SELF_PRUNING_DATED:-laptop-backup}" <<'PY'
import json, os, re, sys
work, ceiling, warn = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
cutoff, exempt = sys.argv[4], set(filter(None, sys.argv[5].split(',')))
path = os.path.join(work, 'objects.jsonl')
objs = [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else []
tot = sum(o['size'] for o in objs)
gb = tot / 1e9
print("  objects=%d  stored=%.3f GB  (%.1f%% of the %g GB free allowance)"
      % (len(objs), gb, gb / ceiling * 100, ceiling))

# A key is BOUNDED when the same key is rewritten (slot-<weekday><hour>, or a fixed name)
# and UNBOUNDED when it carries a date, so every run adds one more object forever.
dated = re.compile(r'(^|[/_.-])(20\d{2})[-/](\d{2})[-/](\d{2})|(20\d{6})T?\d{0,6}')

def agg(rows, keyfn):
    out = {}
    for o in rows:
        k = keyfn(o)
        e = out.setdefault(k, [0, 0, ''])
        e[0] += 1
        e[1] += o['size']
        e[2] = max(e[2], o.get('modified') or '')
    return out

print('  per bucket:')
for b, (n, sz, newest) in sorted(agg(objs, lambda o: o['bucket']).items(), key=lambda kv: -kv[1][1]):
    print('    %-24s objects=%-5d %9.2f MB  newest=%s' % (b, n, sz / 1e6, newest[:10] or '-'))

bounded = agg([o for o in objs if not dated.search(o['key'] or '')], lambda o: (o['bucket'], (o['key'] or '').split('/')[0] or '(root)'))
grown = agg([o for o in objs if dated.search(o['key'] or '')], lambda o: (o['bucket'], (o['key'] or '').split('/')[0] or '(root)'))

print('  biggest prefixes (slot/fixed keys — overwritten, cannot grow):')
for (b, p), (n, sz, newest) in sorted(bounded.items(), key=lambda kv: -kv[1][1])[:10]:
    print('    %-22s %-16s objects=%-5d %9.2f MB  newest=%s' % (b, p, n, sz / 1e6, newest[:10] or '-'))
print('  biggest objects:')
for o in sorted(objs, key=lambda o: -o['size'])[:8]:
    print('    %10d  %s/%s' % (o['size'], o['bucket'], (o['key'] or '?')[:58]))

problems = []
if gb > warn:
    problems.append('stored %.2f GB is over %.0f%% of the free ceiling' % (gb, warn / ceiling * 100))
if grown:
    print('  prefixes whose keys are DATE-STAMPED (one new object per run) — cutover was %s:' % cutoff)
    for (b, p), (n, sz, newest) in sorted(grown.items(), key=lambda kv: -kv[1][1]):
        tag = 'prunes itself' if p in exempt else ('STILL WRITING' if newest[:10] >= cutoff else 'frozen history')
        print('    %-22s %-16s objects=%-5d %9.2f MB  newest=%-10s %s'
              % (b, p, n, sz / 1e6, newest[:10] or '-', tag))
        if p not in exempt and newest[:10] >= cutoff:
            problems.append('%s/%s writes date-stamped keys after %s — unbounded growth'
                            % (b, p, cutoff))
    print('    Fix: write a slot key instead (backup-data.sh, backup-meili.sh, backup-chat.sh do).')
print()
if problems:
    print('RESULT: ' + '; '.join(problems))
    raise SystemExit(1)
print('RESULT: free posture OK — %.1f%% of the %g GB allowance used, no unbounded writer.'
      % (gb / ceiling * 100, ceiling))
PY
