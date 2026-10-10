#!/usr/bin/env bash
# STEP 1 — mint a Vault SPIFFE JWT-SVID and assert it has what OpenAI requires.
#
#   ./mint-token.sh [workload]        default: wif-lab
#
# The workload logs in and can mint ONLY from its own role (see setup-vault.sh),
# so the metadata in the SVID comes from the role, not from an identity entity.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR
WORKLOAD="${1:-wif-lab}"
AUDIENCE="${OPENAI_AUDIENCE:-https://api.openai.com/v1}"
OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"

# The role name equals the workload name, and the password equals the username,
# as setup-vault.sh creates them.
TOKEN=$(vault login -method=userpass username="$WORKLOAD" password="$WORKLOAD" \
  -format=json | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')

VAULT_TOKEN="$TOKEN" vault write -format=json "spiffe/role/$WORKLOAD/mintjwt" \
  audience="$AUDIENCE" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["token"])' >"$OUT/subject.jwt"

python3 - "$OUT/subject.jwt" "$AUDIENCE" <<'EOF'
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
assert p["sub"].startswith("spiffe://"), f"sub is not a SPIFFE ID: {p['sub']}"
assert p["aud"] == [sys.argv[2]], f"aud is {p['aud']}, expected [{sys.argv[2]}]"
meta = [c for c in ("project", "cost_centre", "bu") if c in p]
assert meta == ["project", "cost_centre", "bu"], f"role metadata claims missing: {meta}"

print(f"\nOK: SVID carries {p['sub']} plus role metadata {'/'.join(meta)}")
EOF
