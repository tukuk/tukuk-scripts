#!/usr/bin/env bash
# Check the Cloudflare API token's ability to add a tunnel public hostname.
# Print only a summary (ID/status), never the token.
set -uo pipefail
ENVFILE="${1:-/opt/tukuk-os/.env}"
TUNNEL_ID="${2:-c1d8ea0f-b512-487b-b7e7-ad730c24da9e}"
TOKEN=$(grep -E '^CLOUDFLARE_API_TOKEN=' "$ENVFILE" | cut -d= -f2- | tr -d '"'"'")
[ -n "$TOKEN" ] || { echo "no token"; exit 1; }
H=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

echo "== accounts =="
curl -s "${H[@]}" https://api.cloudflare.com/client/v4/accounts \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result'][0]['id'] if d.get('success') and d['result'] else 'ERR '+str(d.get('errors'))[:160])"

ACC=$(curl -s "${H[@]}" https://api.cloudflare.com/client/v4/accounts \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result'][0]['id'] if d.get('success') and d['result'] else '')")
[ -n "$ACC" ] || { echo "token cannot read accounts (missing accounts.read scope?)"; exit 1; }

echo "== zone tukuk.org =="
curl -s "${H[@]}" "https://api.cloudflare.com/client/v4/zones?name=tukuk.org" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result'][0]['id'] if d.get('success') and d['result'] else 'ERR '+str(d.get('errors'))[:160])"

echo "== tunnel $TUNNEL_ID =="
curl -s "${H[@]}" "https://api.cloudflare.com/client/v4/accounts/$ACC/cloudflare-tunnel/tunnels/$TUNNEL_ID" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('OK' if d.get('success') else 'ERR '+str(d.get('errors'))[:160])"

echo "== existing routes (hostname) =="
curl -s "${H[@]}" "https://api.cloudflare.com/client/v4/accounts/$ACC/cfm/tunnels/$TUNNEL_ID/routes" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('\n'.join(r.get('hostname','') for r in d['result']) if d.get('success') else 'ERR '+str(d.get('errors'))[:200])"
