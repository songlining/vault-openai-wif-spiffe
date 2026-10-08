#!/usr/bin/env bash
# Run Vault in a Podman container. Nothing is installed or run on the host.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a

CONTAINER=vault-wif
IMAGE=docker.io/hashicorp/vault-enterprise:2.1.2-ent
PORT=8200

# Enterprise licence. Mounted read-only straight from where it already lives, so
# it never enters this repo. *.hclic is gitignored as a backstop.
VAULT_LICENSE_FILE="${VAULT_LICENSE_FILE:-$HOME/work/hashicorp/ldap-service-account-rotation/vault-config/vault.hclic}"
[ -r "$VAULT_LICENSE_FILE" ] || { echo "licence not readable: $VAULT_LICENSE_FILE"; exit 1; }

# This container may be exposed to the internet via a tunnel, so the root token
# must not be a guessable default. Generate one into .env first:
#   printf 'VAULT_DEV_ROOT_TOKEN=%s\n' "$(openssl rand -hex 24)" >> .env
: "${VAULT_DEV_ROOT_TOKEN:?set VAULT_DEV_ROOT_TOKEN in .env (openssl rand -hex 24)}"

# api_addr is what the OIDC `iss` claim is built from, and a tunnel hostname
# changes on every restart, so it lives in .env (gitignored) rather than in the
# tracked vault.hcl. out/vault.hcl is generated with the value substituted in.
VAULT_API_ADDR="${VAULT_API_ADDR:-http://127.0.0.1:${PORT}}"
mkdir -p out
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

echo "vault up: $(podman exec "$CONTAINER" vault version)"
echo "api_addr: $VAULT_API_ADDR"
echo "issuer:   $(curl -sf "http://127.0.0.1:${PORT}/v1/identity/oidc/.well-known/openid-configuration" | python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])')"
podman exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$VAULT_DEV_ROOT_TOKEN" "$CONTAINER" \
  vault license get -format=json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];l=d.get("autoloaded") or d;print("licence:  %s expires %s (%d features)" % (l["license_id"], l["expiration_time"], len(l.get("features", []))))' \
  || echo "licence:  not reported"
