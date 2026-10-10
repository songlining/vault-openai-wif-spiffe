#!/usr/bin/env bash
# Exchange a workload's Vault SVID for an OpenAI credential, against a NAMED
# service account — so you can demo the one-to-many mapping on demand.
#
# One Vault issuer, one OpenAI provider, many workloads. Each workload has its
# OWN SPIFFE role carrying its own metadata and its own mint policy. The identity
# does not pick the project; the client names the service account, and the OpenAI
# mapping authorises the claims against it.
#
#   ./exchange-team.sh <vault-workload> <openai-service-account-id>
#
# Examples:
#   ./exchange-team.sh wif-lab        "$OPENAI_SERVICE_ACCOUNT_ID"
#   ./exchange-team.sh team-payments  "$OPENAI_SERVICE_ACCOUNT_ID_PAYMENTS"
#
# The workload name equals its role name and its password, as setup-vault.sh
# creates them.
#
# To demo isolation, cross the two — both of these must be REJECTED:
#   ./exchange-team.sh wif-lab        "$OPENAI_SERVICE_ACCOUNT_ID_PAYMENTS"
#   ./exchange-team.sh team-payments  "$OPENAI_SERVICE_ACCOUNT_ID"
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

USERNAME="${1:?usage: $0 <vault-workload> <openai-service-account-id>}"
SERVICE_ACCOUNT="${2:?usage: $0 <vault-workload> <openai-service-account-id>}"
: "${OPENAI_IDENTITY_PROVIDER_ID:?set it in .env}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
AUDIENCE="${OPENAI_AUDIENCE:-https://api.openai.com/v1}"

curl -sf --max-time 3 "$VAULT_ADDR/v1/sys/health" >/dev/null \
  || { echo "no Vault at $VAULT_ADDR — run ./run-vault.sh && ./setup-vault.sh"; exit 1; }

# 1. The workload authenticates. In production this is its real auth method; here
#    it is userpass, which binds the policy for this workload's own SPIFFE role.
TOKEN=$(vault login -method=userpass username="$USERNAME" password="$USERNAME" \
  -format=json | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')

# 2. Mint the subject SVID from THIS workload's role — claims come from the role
#    template, so a workload can only ever present its own metadata.
SUBJECT=$(VAULT_TOKEN="$TOKEN" vault write -field=token "spiffe/role/$USERNAME/mintjwt" \
  audience="$AUDIENCE")

echo "workload      : $USERNAME"
echo "service acct  : $SERVICE_ACCOUNT"
python3 - "$SUBJECT" <<'EOF'
import base64, json, sys
seg = sys.argv[1].split('.')[1]
p = json.loads(base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4)))
print("claims        : project=%s cost_centre=%s bu=%s"
      % (p.get("project"), p.get("cost_centre"), p.get("bu")))
print("sub           : %s" % p.get("sub"))
EOF

# 3. Exchange. The service account is REQUESTED here — that is what selects which
#    mapping applies; the mapping then decides whether the claims are allowed.
RESPONSE=$(curl -sS https://auth.openai.com/oauth/token \
  -H 'Content-Type: application/json' \
  -d @- <<JSON
{
  "grant_type":           "urn:ietf:params:oauth:grant-type:token-exchange",
  "subject_token_type":   "urn:ietf:params:oauth:token-type:jwt",
  "subject_token":        "$SUBJECT",
  "identity_provider_id": "$OPENAI_IDENTITY_PROVIDER_ID",
  "service_account_id":   "$SERVICE_ACCOUNT"
}
JSON
)

echo "$RESPONSE" | python3 -c '
import base64, json, sys
d = json.load(sys.stdin)
if "access_token" not in d:
    code = d.get("error", {}).get("code", "?")
    print("result        : REJECTED — %s" % code)
    if code == "invalid_grant":
        print("                no enabled mapping matched these claims for that service account")
    sys.exit(1)

p = d["access_token"].split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
a = c.get("https://api.openai.com/auth", {})
print("result        : SUCCESS")
print("  project     : %s" % a.get("project_id"))
print("  service acct: %s" % a.get("wif_service_account_id"))
print("  external subj: %s" % a.get("wif_external_subject"))
print("  expires_in  : %ss" % d.get("expires_in"))
'
