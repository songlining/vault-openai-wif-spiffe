#!/usr/bin/env bash
# Exchange the Vault-signed subject JWT for a short-lived OpenAI access token.
# No OpenAI API key is used anywhere in this request.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

: "${OPENAI_IDENTITY_PROVIDER_ID:?set it in .env (Organization Settings > Security > Workload Identity Provider)}"
: "${OPENAI_SERVICE_ACCOUNT_ID:?set it in .env (Project > Service accounts)}"

SUBJECT=$(cat out/subject.jwt)
OUT=out/exchange.json

curl -sS https://auth.openai.com/oauth/token \
  -H "Content-Type: application/json" \
  -d @- >"$OUT" <<JSON
{
  "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "subject_token": "$SUBJECT",
  "identity_provider_id": "$OPENAI_IDENTITY_PROVIDER_ID",
  "service_account_id": "$OPENAI_SERVICE_ACCOUNT_ID"
}
JSON

python3 - "$OUT" <<'EOF'
import base64, json, sys

d = json.load(open(sys.argv[1]))
print(json.dumps(d, indent=1))

if "access_token" not in d:
    print("\nFAILED: no access_token. Read the error above:")
    print("  - provider/mapping config problem  -> issuer, audience, or claims mismatch")
    print("  - 'arbitrary OIDC issuer' rejection -> Vault is not a documented provider")
    sys.exit(1)

t = d["access_token"]
if t.count(".") == 2:
    p = t.split(".")[1]
    print("\naccess token claims:", json.dumps(
        json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))), indent=1))
print(f"\nOK: minted a token, expires_in={d.get('expires_in')}s. No API key was used.")
EOF
