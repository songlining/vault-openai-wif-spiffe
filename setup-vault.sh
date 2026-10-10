#!/usr/bin/env bash
# Configure the Vault Enterprise container as a SPIFFE JWT-SVID issuer for the
# OpenAI WIF probe.
#
# Run ./run-vault.sh first. Produces:
#   - the SPIFFE secrets engine, enabled and given a trust domain + issuer URL
#   - ONE role PER WORKLOAD. The role template carries that workload's business
#     metadata as literal claims, so the SVID is built from the role and needs no
#     identity entity at all.
#   - ONE policy per workload that permits minting from that role and no other
#   - one userpass user per workload, bound to its policy, as a stand-in for the
#     workload's real auth method (Kubernetes, AppRole, OIDC, ...)
#   - out/jwks.json  (only needed if OpenAI cannot use OIDC discovery)
#
# The gate is the policy, not the auth method: a workload can mint only from the
# mintjwt path of its own role, so it can only ever get its own metadata.
#
# Nothing here talks to OpenAI.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
export VAULT_ADDR VAULT_TOKEN

AUDIENCE="${OPENAI_AUDIENCE:-https://api.openai.com/v1}"
TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-lab.example.org}"
VAULT_API_ADDR="${VAULT_API_ADDR:-http://127.0.0.1:8200}"
ISSUER_URL="${SPIFFE_ISSUER_URL:-${VAULT_API_ADDR}/v1/spiffe}"
OUT="$PWD/out"
mkdir -p "$OUT"

curl -sf --max-time 3 "$VAULT_ADDR/v1/sys/health" >/dev/null \
  || { echo "no Vault at $VAULT_ADDR — run ./run-vault.sh first"; exit 1; }

# The SPIFFE secrets engine is Enterprise-only. Fail with a clear message here
# rather than a 404 from the enable call.
curl -sf "$VAULT_ADDR/v1/sys/health" | grep -q '"enterprise": *true' \
  || { echo "this Vault is not Enterprise; the SPIFFE secrets engine needs it — run ./run-vault.sh"; exit 1; }

# 1. SPIFFE engine. Config sets the trust domain (prefixed onto every `sub`) and
#    the issuer URL that becomes the `iss` claim. Idempotent: re-running setup
#    against a live container rebuilds the roles without a restart.
vault secrets enable spiffe >/dev/null 2>&1 || true
vault write spiffe/config \
  trust_domain="$TRUST_DOMAIN" \
  jwt_issuer_url="$ISSUER_URL" >/dev/null

# 2. One role and one policy per workload.
#    Format: name:password:sub_path:project:cost_centre:bu
#    The role name is the workload name — one workload, one role, one policy.
#    The template is literal JSON — the metadata belongs to the ROLE, not to an
#    entity. These are plain values, not identity directives, so they must be
#    quoted to keep the template valid JSON.
#    `iss` and `aud` are filled in by the engine; `sub` is required and may be a
#    bare path (the trust domain is prefixed) or a full spiffe:// ID.
WORKLOADS=(
  "wif-lab:wif-lab:/sea-change/wif-lab:sea-change:CC-IB-4471:Institutional Banking"
  "team-payments:team-payments:/payments/team-payments:payments:CC-RB-2210:Retail Banking"
)

vault auth enable userpass >/dev/null 2>&1 || true

for entry in "${WORKLOADS[@]}"; do
  IFS=: read -r name pass sub proj cc bu <<<"$entry"
  role="$name"

  vault write "spiffe/role/$role" \
    template="{\"sub\":\"$sub\",\"project\":\"$proj\",\"cost_centre\":\"$cc\",\"bu\":\"$bu\"}" \
    ttl=10m use_jti_claim=true >/dev/null

  # The whole authorisation gate: this workload's own role, nothing else.
  # Vault's documented default is that most write paths need BOTH `create` and
  # `update`, and the SPIFFE docs note no exception, so grant both. (Measured on
  # 2.1.2-ent: an update-only token also mints, and a create-only token gets 403 on
  # PUT and POST — but that is undocumented behaviour a future build could change.
  # Both is the same path, so the extra capability buys no extra reachable surface.)
  vault policy write "${role}-mint-svid" - >/dev/null <<EOF
path "spiffe/role/$role/mintjwt" { capabilities = ["create", "update"] }
EOF

  # Password equals username, and both are throwaway dev credentials that die with
  # the in-memory container. Never reuse this pattern outside the lab.
  vault write "auth/userpass/users/$name" password="$pass" \
    "policies=${role}-mint-svid" >/dev/null

  echo "  $name  ->  role=$role  sub=spiffe://$TRUST_DOMAIN$sub"
done

# 3. JWKS — only needed if OpenAI cannot reach the issuer for discovery.
curl -sf "$VAULT_ADDR/v1/spiffe/.well-known/keys" >"$OUT/jwks.json"

ISSUER=$(curl -sf "$VAULT_ADDR/v1/spiffe/.well-known/openid-configuration" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])')

echo
echo "Vault is configured for SPIFFE."
echo "  SPIFFE issuer   : $ISSUER"
echo "  Audience        : $AUDIENCE"
echo "  Trust domain    : $TRUST_DOMAIN"
echo "  Workloads       : ${#WORKLOADS[@]} roles, each with its own metadata + policy"
echo
echo "On the OpenAI side, register the issuer above and use the audience above."
echo "The claims to match on are the workload's own (project, cost_centre, bu)."
echo "Run ./mint-token.sh to see them in a minted SVID."
