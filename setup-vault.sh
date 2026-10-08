#!/usr/bin/env bash
# Configure the Vault container as an OIDC issuer for the OpenAI WIF probe.
#
# Run ./run-vault.sh first. Produces:
#   - an OIDC key + role whose template lifts entity metadata into JWT claims
#   - a userpass user, because identity/oidc/token/<role> requires the calling
#     token to be attached to an entity, and only an auth-method login creates one
#   - entity metadata on that user, which is what the claims are built from
#   - out/jwks.json  (only needed if OpenAI cannot use OIDC discovery)
#
# Nothing here talks to OpenAI.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
export VAULT_ADDR VAULT_TOKEN

AUDIENCE="${OPENAI_AUDIENCE:-https://api.openai.com/v1}"
ROLE=wif-lab
USER=wif-lab
PASS=wif-lab
OUT="$PWD/out"
mkdir -p "$OUT"

# Business identity carried in the subject JWT. These values are what an OpenAI
# mapping matches on, so `project` must equal the OpenAI project name exactly.
CLAIM_PROJECT="${CLAIM_PROJECT:-sea-change}"
CLAIM_COST_CENTRE="${CLAIM_COST_CENTRE:-CC-4471}"
CLAIM_BU="${CLAIM_BU:-Institutional Banking}"

curl -sf --max-time 3 "$VAULT_ADDR/v1/sys/health" >/dev/null \
  || { echo "no Vault at $VAULT_ADDR — run ./run-vault.sh first"; exit 1; }

# 1. OIDC key. The role's client_id becomes the token's `aud` claim, so
#    allowed_client_ids on the key must permit that same value.
vault write "identity/oidc/key/$ROLE" \
  allowed_client_ids="$AUDIENCE" \
  algorithm=RS256 \
  rotation_period=24h \
  verification_ttl=24h >/dev/null

# 2. OIDC role. The template pulls entity metadata into custom claims.
#    The directives must NOT be wrapped in quotes — Vault emits the JSON value
#    itself. Quoted, the write fails with a misleading "invalid JSON" error.
#    A metadata key that does not exist renders as "" with no warning.
vault write "identity/oidc/role/$ROLE" \
  key="$ROLE" \
  ttl=10m \
  client_id="$AUDIENCE" \
  template='{"project":{{identity.entity.metadata.project}},"cost_centre":{{identity.entity.metadata.cost_centre}},"bu":{{identity.entity.metadata.bu}}}' >/dev/null

# 3. A caller that has an entity, plus a policy that only allows minting.
vault policy write wif-mint - >/dev/null <<EOF
path "identity/oidc/token/$ROLE" { capabilities = ["read"] }
EOF

vault auth enable userpass >/dev/null 2>&1 || true
vault write "auth/userpass/users/$USER" password="$PASS" policies=wif-mint >/dev/null

# 4. Log in once to materialise the entity, then write its metadata.
#    A partial write REPLACES the whole metadata map, so always send every key.
EID=""
for _ in 1 2 3; do
  T=$(vault login -method=userpass username="$USER" password="$PASS" -format=json \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')
  EID=$(VAULT_TOKEN="$T" vault token lookup -format=json \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"].get("entity_id",""))')
  [ -n "$EID" ] && break
  sleep 1
done
[ -n "$EID" ] || { echo "could not resolve an entity for user $USER"; exit 1; }

curl -sf -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  -d "{\"metadata\":{\"project\":\"$CLAIM_PROJECT\",\"cost_centre\":\"$CLAIM_COST_CENTRE\",\"bu\":\"$CLAIM_BU\"}}" \
  "$VAULT_ADDR/v1/identity/entity/id/$EID" >/dev/null

# 5. JWKS — only needed if OpenAI cannot reach the issuer for discovery.
curl -sf "$VAULT_ADDR/v1/identity/oidc/.well-known/keys" >"$OUT/jwks.json"

ISSUER=$(curl -sf "$VAULT_ADDR/v1/identity/oidc/.well-known/openid-configuration" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])')

echo
echo "Vault is configured."
echo "  OIDC Issuer URL : $ISSUER"
echo "  Audience        : $AUDIENCE"
echo "  entity id (sub) : $EID"
echo "  claims          : project=$CLAIM_PROJECT cost_centre=$CLAIM_COST_CENTRE bu=$CLAIM_BU"
echo
echo "The issuer is the cluster's api_addr, not the address you reach Vault on here."
echo "If it is a public https URL, OpenAI can use OIDC discovery and you do not"
echo "need out/jwks.json. Run ./mint-token.sh to see the claims in the token."
