#!/usr/bin/env bash
# The whole Vault -> OpenAI workload identity flow in one screen.
#
# This is the condensed version for the deck's client slide. The runnable
# step-by-step pipeline is the three scripts at the repo root:
#
#   ./mint-token.sh    step 1  Vault mints the JWT-SVID
#   ./exchange.sh      step 2  OpenAI returns the credential
#   ./use-token.sh     step 3  the client calls the API
#
# Nothing below is an API key. The credential is minted from the workload's SPIFFE
# role (its metadata template, not an identity entity) and lives for the role's TTL
# — 10 minutes.
#
# Steps 1-4 are free. Step 5 is the metered one (never succeeded here — the org has
# no credit; the loop is proven through step 4).
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
unset VAULT_TOKEN   # log in for real instead of inheriting the root token
: "${OPENAI_AUDIENCE:=https://api.openai.com/v1}"   # same default as the root scripts

# --- deck snippet starts here ---------------------------------------------

# 1. The workload authenticates to Vault. In production this is whatever auth
#    method it already uses — Kubernetes, AppRole, OIDC, LDAP. Here it is a
#    userpass user bound to the policy for its own SPIFFE role.
VAULT_TOKEN=$(vault login -method=userpass username=wif-lab password=wif-lab \
  -format=json | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth"]["client_token"])')

# 2. Ask Vault for a JWT-SVID from this workload's OWN role. The business
#    metadata (project, cost_centre, bu) is baked into that role's template, so
#    the workload can only ever mint its own claims.
SUBJECT=$(VAULT_TOKEN="$VAULT_TOKEN" vault write -field=token \
  spiffe/role/wif-lab/mintjwt audience="$OPENAI_AUDIENCE")

# 3. Exchange it with OpenAI for a short-lived access token
ACCESS=$(curl -sS https://auth.openai.com/oauth/token \
  -H 'Content-Type: application/json' \
  -d @- <<JSON | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
{
  "grant_type":           "urn:ietf:params:oauth:grant-type:token-exchange",
  "subject_token_type":   "urn:ietf:params:oauth:token-type:jwt",
  "subject_token":        "$SUBJECT",
  "identity_provider_id": "$OPENAI_IDENTITY_PROVIDER_ID",
  "service_account_id":   "$OPENAI_SERVICE_ACCOUNT_ID"
}
JSON
)

# 4. Use it — exactly like an API key, except it was never one.
#    Free: this authenticates the chain and spends nothing.
curl -sS https://api.openai.com/v1/models -H "Authorization: Bearer $ACCESS"

# 5. Ask the model a question — the metered step. The model is not a free
#    choice: the project's allowlist permits gpt-4o and nothing else. Ask for
#    anything else and you get 403, not a fallback.
curl -sS https://api.openai.com/v1/responses \
  -H "Authorization: Bearer $ACCESS" \
  -H 'Content-Type: application/json' \
  -d '{"model": "gpt-4o", "input": "Say hello world and nothing else."}' \
  | python3 -c 'import sys,json
d = json.load(sys.stdin)
print("".join(c["text"] for o in d.get("output", [])
              if o.get("type") == "message"
              for c in o.get("content", []) if c.get("type") == "output_text"))'
