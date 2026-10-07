#!/usr/bin/env bash
# Remove the Vault container. Dev mode keeps everything in memory, so this
# discards all state — re-run run-vault.sh && setup-vault.sh to rebuild.
set -euo pipefail
podman rm -f vault-wif >/dev/null 2>&1 || true
echo "vault-wif container removed"
