#!/usr/bin/env bash
# ==============================================================================
# verify-builder-fix.sh — is the Builder crash fix ACTUALLY live?
#
#   bash scripts/verify-builder-fix.sh
#
# Reads only public URLs: no SSH, no credentials. Run it from anywhere, before and
# after a deploy, and after any nginx/tunnel change.
#
# WHY THIS EXISTS. The 2026-10-29 deploy reported nothing wrong and shipped nothing:
# every check in deploy-builder.sh runs ON the box and several end in `|| true`, so a
# skipped scp or a failed restart still printed "done". Meanwhile the browser was still
# loading the pre-fix bundle, and the two crashes in the browser console were identical
# to the original report. This script asks the question from the outside — the same
# place the user asks it from — and never marks a check PASS on a guess.
#
# Exit code: 0 = every check passed, 1 = at least one FAIL (see the summary).
# ==============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_HOST="${BUILD_HOST:-https://build.tukuk.org}"
ALIAS_HOST="${ALIAS_HOST:-}"   # empty = retired: dashboard.tukuk.org is gone, nothing to check
ORIGIN_HOST="${ORIGIN_HOST:-https://tukuk.org}"
TIMEOUT="${TIMEOUT:-20}"

pass=0
fail=0
passes=()
failures=()

ok()   { pass=$((pass + 1)); passes+=("$1");   printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); failures+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }

command -v curl >/dev/null 2>&1 || { echo "✗ curl is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "✗ node is required (JSON parsing)"; exit 1; }

echo "── 1. the builder's own API must return a modelList array ──"
body="$(curl -s -m "$TIMEOUT" "$BUILD_HOST/api/models" 2>/dev/null || true)"
verdict="$(printf '%s' "$body" | node -e '
  let s = "";
  process.stdin.on("data", (d) => { s += d; }).on("end", () => {
    let j = null;
    try { j = JSON.parse(s); } catch { process.stdout.write("not-json"); return; }
    if (Array.isArray(j && j.modelList)) process.stdout.write("ok:" + j.modelList.length);
    else process.stdout.write("no-modelList");
  });
' 2>/dev/null || echo "not-json")"
case "$verdict" in
  ok:*) ok "build.tukuk.org/api/models is the builder (modelList, ${verdict#ok:} models)" ;;
  *)    bad "build.tukuk.org/api/models has no modelList — the chat will crash on it"
        note "got: $(printf '%s' "$body" | head -c 120)" ;;
esac

echo
echo "── 2. no alias host may serve the builder ──"
# dashboard.tukuk.org was retired: it shared the apex app's /api namespace, so a builder served
# there fetched Tukuk-OS's /api/models and crashed on the spread. The default is now empty (the
# hostname is gone). Set ALIAS_HOST to re-check any hostname that still points at the front door:
# then the acceptable answers are a redirect to the canonical origin, or no answer at all.
if [ -z "$ALIAS_HOST" ]; then
  note "no alias host configured — dashboard.tukuk.org is retired (the panel is tukuk.org/admin)"
else
  code="$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "$ALIAS_HOST/" 2>/dev/null || echo 000)"
  target="$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{redirect_url}' "$ALIAS_HOST/" 2>/dev/null || true)"
  case "$code" in
    2??) bad "alias host still SERVES the app (http ${code}) — its /api belongs to Tukuk-OS, the crash is reachable"
         note "either retire the hostname or point it at ${BUILD_HOST}" ;;
    3??) case "$target" in
           *build.tukuk.org*) ok "alias host answers ${code} -> ${target}" ;;
           *) bad "alias host answers ${code} but to the wrong place: ${target:-<empty>}" ;;
         esac ;;
    *)   ok "alias host is gone (http ${code}) — retired, nothing served there" ;;
  esac
fi

echo
echo "── 3. the served bundle must carry the no-auto-translate opt-out ──"
# The insertBefore NotFoundError is a hydration mismatch: Chrome/Edge auto-translate
# rewrites the DOM under React. translate="no" + the notranslate meta are the fix, so
# their absence in the SERVED html proves the new build is not live.
page="$(curl -s -m "$TIMEOUT" "$BUILD_HOST/" 2>/dev/null || true)"
if printf '%s' "$page" | grep -q 'name="google" content="notranslate"'; then
  ok "served HTML opts out of browser auto-translation"
else
  bad "served HTML has no notranslate meta — the insertBefore hydration crash is still possible"
fi
hashes="$(printf '%s' "$page" | grep -oE 'entry\.client-[A-Za-z0-9_-]+\.js' | sort -u | tr '\n' ' ')"
if [ -n "$hashes" ]; then note "served entry bundle: ${hashes}"; fi
case "$hashes" in
  *BB23yigM*) note "⚠ that is the 2026-10-29 pre-fix hash — the browser is running the old build" ;;
esac

echo
echo "── 4. the Tukuk-OS brain must not be using the vetoed provider ──"
brain="$(curl -s -m "$TIMEOUT" "$ORIGIN_HOST/api/models" 2>/dev/null || true)"
provider="$(printf '%s' "$brain" | node -e '
  let s = "";
  process.stdin.on("data", (d) => { s += d; }).on("end", () => {
    let j = null;
    try { j = JSON.parse(s); } catch { process.stdout.write("not-json"); return; }
    const p = j && j.backend && j.backend.provider;
    process.stdout.write(typeof p === "string" ? p : "unknown");
  });
' 2>/dev/null || echo "not-json")"
case "$provider" in
  groq) bad "production brain reports provider=groq — the owner's veto is not deployed" ;;
  not-json|unknown) bad "could not read backend.provider from ${ORIGIN_HOST}/api/models" ;;
  *) ok "production brain reports provider=${provider} (Groq veto satisfied)" ;;
esac

echo
echo "────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then
  echo "✓ ALL ${pass} CHECK(S) PASSED — the fix is live on the public origin."
  exit 0
fi
echo "✗ ${fail} CHECK(S) FAILED, ${pass} passed — the fix is NOT (fully) live."
echo
echo "What to do: deploy from a machine that can reach the box (port 22 must answer):"
echo "  bash scripts/deploy-builder.sh          # rsync fork + rebuild + restart units"
echo "Then run this script again; it must print every line as PASS."
exit 1
