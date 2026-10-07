#!/usr/bin/env bash
# Mint a Vault-signed OIDC subject JWT and assert it has what OpenAI requires.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR
ROLE=wif-lab
OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"

TOKEN=$(vault login -method=userpass username=wif-lab password=wif-lab \
  -format=json | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')

VAULT_TOKEN="$TOKEN" vault read -format=json "identity/oidc/token/$ROLE" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["token"])' >"$OUT/subject.jwt"

python3 - "$OUT/subject.jwt" <<'EOF'
import base64, json, sys

def dec(seg):
    return json.loads(base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4)))

raw = open(sys.argv[1]).read().strip()
head, payload, _ = raw.split(".")
h, p = dec(head), dec(payload)

print("header :", json.dumps(h))
print("payload:", json.dumps(p, indent=1))

# OpenAI requires iss/aud/sub/exp/iat and a kid in the header.
missing = [c for c in ("iss", "aud", "sub", "exp", "iat") if c not in p]
assert not missing, f"missing required claims: {missing}"
assert h.get("kid"), "header has no kid"
assert h.get("alg") in ("RS256", "RS384", "RS512", "ES256"), f"unsupported alg {h.get('alg')}"
print("\nOK: subject JWT is shaped for OpenAI token exchange")
EOF
