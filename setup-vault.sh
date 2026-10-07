#!/usr/bin/env bash
# Configure a local Vault dev server as an OIDC issuer for the OpenAI WIF probe.
#
# Verified against Vault v1.20.0. Produces:
#   - an OIDC key + role (machine-to-machine tokens; no provider/scope needed)
#   - a userpass user, because identity/oidc/token/<role> requires the calling
#     token to be attached to an entity, and only an auth-method login creates one
#   - out/jwks.json  (upload this to the OpenAI Workload Identity Provider)
#
# Nothing here talks to OpenAI.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
export VAULT_ADDR VAULT_TOKEN

AUDIENCE="${OPENAI_AUDIENCE:-https://api.openai.com/v1}"
ROLE=wif-lab
USER=wif-lab
PASS=wif-lab
OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"

# 1. Start a dev server if one is not already listening.
if ! curl -sf --max-time 2 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
  echo "starting vault dev server on $VAULT_ADDR"
  vault server -dev -dev-root-token-id=root \
    -dev-listen-address="${VAULT_ADDR#http://}" >"$OUT/vault-dev.log" 2>&1 &
  for _ in $(seq 1 30); do
    curl -sf --max-time 2 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
vault status >/dev/null

# 2. OIDC key + role. The role's client_id becomes the token's `aud` claim.
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

# 3. A caller that has an entity, plus a policy that only allows minting.
vault policy write wif-mint - >/dev/null <<EOF
path "identity/oidc/token/$ROLE" { capabilities = ["read"] }
EOF

vault auth enable userpass >/dev/null 2>&1 || true
vault write "auth/userpass/users/$USER" password="$PASS" policies=wif-mint >/dev/null

# 4. JWKS — upload this to the OpenAI provider.
curl -sf "$VAULT_ADDR/v1/identity/oidc/.well-known/keys" >"$OUT/jwks.json"

ISSUER="$VAULT_ADDR/v1/identity/oidc"
echo
echo "Vault is configured. Paste these into OpenAI:"
echo "  OIDC Issuer URL : $ISSUER"
echo "  Audience        : $AUDIENCE"
echo "  JWKS            : $OUT/jwks.json  (upload)"
echo
echo "Note: this issuer is http:// + an IP literal. Whether OpenAI accepts that"
echo "string when JWKS is uploaded (no fetch) is exactly what the probe tests."
