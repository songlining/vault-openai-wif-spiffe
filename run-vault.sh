#!/usr/bin/env bash
# Run Vault in a Podman container. Nothing is installed or run on the host.
set -euo pipefail

cd "$(dirname "$0")"

CONTAINER=vault-wif
IMAGE=docker.io/hashicorp/vault:2.1.2
PORT=8200

podman rm -f "$CONTAINER" >/dev/null 2>&1 || true

podman run -d --name "$CONTAINER" \
  -p "127.0.0.1:${PORT}:8200" \
  -e VAULT_DEV_ROOT_TOKEN_ID=root \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  -v "$PWD/vault.hcl:/vault/config/vault.hcl:ro" \
  "$IMAGE" server -dev -config=/vault/config/vault.hcl >/dev/null

for _ in $(seq 1 40); do
  curl -sf --max-time 2 "http://127.0.0.1:${PORT}/v1/sys/health" >/dev/null 2>&1 && break
  sleep 0.5
done

curl -sf --max-time 2 "http://127.0.0.1:${PORT}/v1/sys/health" >/dev/null \
  || { echo "vault did not become healthy; logs:"; podman logs "$CONTAINER" | tail -20; exit 1; }

echo "vault up: $(podman exec "$CONTAINER" vault version)"
echo "issuer:   $(curl -sf "http://127.0.0.1:${PORT}/v1/identity/oidc/.well-known/openid-configuration" | python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])')"
