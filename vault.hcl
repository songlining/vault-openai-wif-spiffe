# Vault server config. Mounted read-only into the container.
#
# Dev mode derives api_addr from its listen address unless it is set here, and
# api_addr is what the OIDC `iss` claim is built from. That makes this the one
# knob that matters for the OpenAI side.
#
# Default: the issuer becomes http://127.0.0.1:8200/v1/identity/oidc
#
# If you need OpenAI to fetch discovery/JWKS itself (rather than uploading the
# JWKS), point this at a public HTTPS URL from a tunnel and restart. OpenAI
# requires public HTTPS on 443 with a real DNS name for discovery; IP literals
# are rejected. See README.md.
api_addr = "http://127.0.0.1:8200"
