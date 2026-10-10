# Vault server config. Mounted read-only into the container.
#
# Dev mode derives api_addr from its listen address unless it is set here. It is
# the address Vault advertises, and the SPIFFE engine's default issuer URL is
# derived from it — setup-vault.sh sets jwt_issuer_url explicitly from
# VAULT_API_ADDR, so this is the same value.
#
# A tunnel hostname changes on every restart, so run-vault.sh regenerates
# out/vault.hcl from .env rather than using this tracked file directly; editing
# this file alone has no effect.
#
# If OpenAI fetches discovery/JWKS itself, the host must be public HTTPS on 443
# with a real DNS name (IP literals are rejected). See README.md.
api_addr = "http://127.0.0.1:8200"
