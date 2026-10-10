#!/usr/bin/env bash
# Run Vault ENTERPRISE in a Podman container. Nothing is installed or run on the
# host. Enterprise is required for the SPIFFE secrets engine.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

CONTAINER=vault-wif
IMAGE=docker.io/hashicorp/vault-enterprise:2.1.2-ent
PORT=8200

# Enterprise licence. Mounted read-only straight from where it already lives, so
# it never enters this repo. *.hclic is gitignored as a backstop.
VAULT_LICENSE_FILE="${VAULT_LICENSE_FILE:-}"
[ -r "$VAULT_LICENSE_FILE" ] || { echo "licence not readable: '${VAULT_LICENSE_FILE:-unset}' — set VAULT_LICENSE_FILE in .env to a .hclic on this machine"; exit 1; }

# This container may be exposed to the internet via a tunnel, so the root token
# must not be a guessable default. Generate one into .env first:
#   printf 'VAULT_DEV_ROOT_TOKEN=%s\n' "$(openssl rand -hex 24)" >> .env
: "${VAULT_DEV_ROOT_TOKEN:?set VAULT_DEV_ROOT_TOKEN in .env (openssl rand -hex 24)}"

# 1. Validate the licence file offline, before anything starts: signature,
#    format and entitlements. This fails loudly on an expired, corrupt or
#    wrong-product file, instead of starting a server that silently refuses the
#    Enterprise-only paths later.
mkdir -p out
podman run --rm -v "$VAULT_LICENSE_FILE:/lic/vault.hclic:ro" "$IMAGE" \
  vault license inspect /lic/vault.hclic >out/license.txt 2>&1 \
  || { echo "licence inspection failed:"; cat out/license.txt; exit 1; }
grep -q "License is valid" out/license.txt \
  || { echo "licence is NOT valid:"; cat out/license.txt; exit 1; }
echo "licence:  $(awk -F': ' '/Expiration Time/{print "valid, expires "$2}' out/license.txt)"

# A tunnel hostname changes on every restart, so it lives in .env (gitignored)
# rather than in the tracked vault.hcl. out/vault.hcl is regenerated with the
# value substituted in, and setup-vault.sh derives the SPIFFE issuer from it.
VAULT_API_ADDR="${VAULT_API_ADDR:-http://127.0.0.1:${PORT}}"
sed "s|^api_addr.*|api_addr = \"${VAULT_API_ADDR}\"|" vault.hcl > out/vault.hcl

podman rm -f "$CONTAINER" >/dev/null 2>&1 || true

podman run -d --name "$CONTAINER" \
  -p "127.0.0.1:${PORT}:8200" \
  -e VAULT_DEV_ROOT_TOKEN_ID="$VAULT_DEV_ROOT_TOKEN" \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  -e VAULT_LICENSE_PATH=/vault/license/vault.hclic \
  -v "$VAULT_LICENSE_FILE:/vault/license/vault.hclic:ro" \
  -v "$PWD/out/vault.hcl:/vault/config/vault.hcl:ro" \
  "$IMAGE" server -dev -config=/vault/config/vault.hcl >/dev/null

for _ in $(seq 1 40); do
  curl -sf --max-time 2 "http://127.0.0.1:${PORT}/v1/sys/health" >/dev/null 2>&1 && break
  sleep 0.5
done

curl -sf --max-time 2 "http://127.0.0.1:${PORT}/v1/sys/health" >/dev/null \
  || { echo "vault did not become healthy; logs:"; podman logs "$CONTAINER" | tail -20; exit 1; }

# 2. Verify the running server actually autoloaded the licence and is entitled to
#    the SPIFFE secrets engine — a valid file is not the same as a served feature.
echo "vault up: $(podman exec "$CONTAINER" vault version)"
echo "api_addr: $VAULT_API_ADDR"
curl -sf -H "X-Vault-Token: $VAULT_DEV_ROOT_TOKEN" \
  "http://127.0.0.1:${PORT}/v1/sys/license/status" | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
lic = d.get("autoloaded") or d.get("persisted_autoload") or {}
feats = lic.get("features", [])
assert "SPIFFE Secrets Engine" in feats, "licence does not entitle the SPIFFE secrets engine"
print("licence:  autoloaded %s, expires %s, %d features (SPIFFE Secrets Engine present)"
      % (lic.get("license_id"), lic.get("expiration_time"), len(feats)))
'
