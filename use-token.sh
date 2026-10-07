#!/usr/bin/env bash
# Step 3: the client uses the minted credential against the OpenAI API.
#
#   ./use-token.sh             free check — proves the credential authorises, spends nothing
#   ./use-token.sh --consume   metered — one minimal inference call, spends real tokens
#
# Default is the free check on purpose: a 200 from GET /v1/models already proves
# the credential is accepted, and needs no credit on the org. The inference call
# is the only step that costs money, so it is opt-in.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

TOKEN=$(cat out/access_token 2>/dev/null) || {
  echo "no credential at out/access_token — run ./exchange.sh first (step 2)"
  exit 1
}
AUTH="Authorization: Bearer $TOKEN"
BASE=https://api.openai.com/v1

echo "--- GET $BASE/models"
CODE=$(curl -sS -o out/models.json -w '%{http_code}' -H "$AUTH" "$BASE/models")
echo "HTTP $CODE"

if [ "$CODE" != "200" ]; then
  cat out/models.json; echo
  case "$CODE" in
    401) echo "401 -> the credential itself was rejected" ;;
    403) echo "403 -> credential valid, but the service account lacks permission for this endpoint." ;;
  esac
  exit 1
fi

python3 -c '
import json
d = json.load(open("out/models.json"))
ids = sorted(m["id"] for m in d.get("data", []))
print(f"{len(ids)} models visible to this credential, e.g. {ids[:5]}")
'
echo
echo "STEP 3a OK: the client authenticated to the OpenAI API with Vault-derived credentials."
echo "            No API key, no static secret, and nothing was spent."

[ "${1:-}" = "--consume" ] || {
  echo
  echo "Re-run with --consume to spend one minimal inference call."
  exit 0
}

: "${OPENAI_MODEL:?set OPENAI_MODEL in .env (pick one from the list above)}"

echo
echo "--- POST $BASE/responses  (metered)"
CODE=$(curl -sS -o out/response.json -w '%{http_code}' -H "$AUTH" \
  -H 'Content-Type: application/json' "$BASE/responses" \
  -d "$(python3 -c '
import json, os
print(json.dumps({"model": os.environ["OPENAI_MODEL"], "input": "Reply with the single word: ok"}))
')")
echo "HTTP $CODE"

if [ "$CODE" != "200" ]; then
  cat out/response.json; echo
  [ "$CODE" = "429" ] && echo "429 -> likely no credit / quota on the org, or a rate limit."
  exit 1
fi

python3 -c '
import json
d = json.load(open("out/response.json"))
usage = d.get("usage", {})
text = "".join(c.get("text", "") for o in d.get("output", []) for c in o.get("content", []))
print("reply:", text.strip()[:80])
print("usage:", usage)
'
echo
echo "STEP 3b OK: the client consumed tokens with a credential that originated from Vault."
