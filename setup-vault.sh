#!/usr/bin/env bash
# Configure the Vault container as an OIDC issuer for the OpenAI WIF probe.
#
# Run ./run-vault.sh first. Produces:
#   - an OIDC key + role (machine-to-machine tokens; no provider/scope needed)
#   - a userpass user, because identity/oidc/token/<role> requires the calling
#     token to be attached to an entity, and only an auth-method login creates one
#   - out/jwks.json  (upload this to the OpenAI Workload Identity Provider)
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

curl -sf --max-time 3 "$VAULT_ADDR/v1/sys/health" >/dev/null \
  || { echo "no Vault at $VAULT_ADDR — run ./run-vault.sh first"; exit 1; }

# 1. OIDC key + role. The role's client_id becomes the token's `aud` claim.
#    allowed_client_ids on the key must permit that same value.
vault write "identity/oidc/key/$ROLE" \
  allowed_client_ids="$AUDIENCE" \
  algorithm=RS256 \
  rotation_period=24h \
  verification_ttl=24h >/dev/null

vault write "identity/oidc/role/$ROLE" \
  key="$ROLE" \
  ttl=10m \
  client_id="$AUDIENCE" >/dev/null

# 2. A caller that has an entity, plus a policy that only allows minting.
vault policy write wif-mint - >/dev/null <<EOF
path "identity/oidc/token/$ROLE" { capabilities = ["read"] }
EOF

vault auth enable userpass >/dev/null 2>&1 || true
vault write "auth/userpass/users/$USER" password="$PASS" policies=wif-mint >/dev/null

# 3. JWKS — upload this to the OpenAI provider.
curl -sf "$VAULT_ADDR/v1/identity/oidc/.well-known/keys" >"$OUT/jwks.json"

ISSUER="$VAULT_ADDR/v1/identity/oidc"
echo
echo "Vault is configured. Paste these into OpenAI:"
echo "  OIDC Issuer URL : $ISSUER"
echo "  Audience        : $AUDIENCE"
echo "  JWKS            : $OUT/jwks.json  (upload)"
echo
echo "The issuer above is only reachable from this machine. With JWKS uploaded"
echo "OpenAI never fetches it, so that may not matter — which is what the probe"
echo "tests. If the issuer is rejected, see the tunnel section in README.md."
