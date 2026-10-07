# Vault → OpenAI Workload Identity Federation — probe

Testing whether **HashiCorp Vault can act as the OIDC identity provider for OpenAI's
Workload Identity Federation**, the way it can for Anthropic's.

This is a probe, not a product. The goal is one answer: does OpenAI's token exchange
accept a JWT signed by Vault? Nothing here calls a model.

## Why this is interesting

Both providers do the same thing — exchange a short-lived IdP JWT for a short-lived
platform token, so no static API key exists in the workload. They diverge on who may
be the IdP:

| | Anthropic | OpenAI |
|---|---|---|
| Custom OIDC issuer | any standards-compliant issuer | documented providers only; otherwise *"contact OpenAI support"* |
| Grant | RFC 7523 `jwt-bearer` | RFC 8693 token exchange |
| Rule selection | client names the rule ID | server resolves exactly one matching mapping |
| Config API | — | dashboard only (no Admin API, no Terraform resource) |

Vault is not on OpenAI's provider list. So the question is whether "not supported yet"
means *rejected* or merely *undocumented*.

## Run it

```bash
./setup-vault.sh     # Vault dev server -> OIDC issuer + JWKS, prints what to paste
./mint-token.sh      # mint the subject JWT, assert it has the claims OpenAI requires
./exchange.sh        # POST auth.openai.com/oauth/token, no API key
```

Stop the dev server with `pkill -f 'vault server -dev'`.

## The two manual clicks

OpenAI has **no API and no Terraform resource** for these two objects — the documented
OpenAPI spec has 228 paths and none of them create a Workload Identity Provider or a
mapping. This is the only non-scriptable part of the whole flow.

1. **platform.openai.com → Settings → Organization → Security → Workload Identity Provider**
   - OIDC Issuer URL: what `setup-vault.sh` printed
   - Audience: same
   - Enable **"Use uploaded JWKS for token verification"** and paste `out/jwks.json`
     (this avoids the public-HTTPS discovery fetch, which a local Vault cannot serve)
   - Record the provider ID → `OPENAI_IDENTITY_PROVIDER_ID`
2. **Project → Service accounts → create**, then on the provider page **Create mapping**
   targeting that service account, matching on `sub`
   - Record the service account ID → `OPENAI_SERVICE_ACCOUNT_ID`

```bash
cp .env.example .env   # fill in the two IDs
```

## Verified: what Vault actually issues

Measured against Vault v1.20.0, not read off a doc page:

```json
{
  "aud": "https://api.openai.com/v1",
  "exp": 1791414536,
  "iat": 1791413936,
  "iss": "http://127.0.0.1:8200/v1/identity/oidc",
  "namespace": "root",
  "sub": "0cc5cc33-9e3a-2439-1627-abf864803bbf"
}
```

Things that cost time to work out:

- **The machine-token issuer is `<VAULT_ADDR>/v1/identity/oidc`** — *not* the provider
  path. `identity/oidc/provider/<name>` is for the browser authorization-code flow and
  advertises a different `iss`. For WIF you want the plain identity/oidc issuer.
- **`aud` comes from the role's `client_id`.** Set it to whatever you type into OpenAI's
  Audience field, and make sure the key's `allowed_client_ids` permits the same value.
- **No provider and no scope are needed** for machine-to-machine. Key + role is enough.
  (`identity/oidc/scope/openid` is reserved and cannot be created.)
- **Minting requires the calling token to have an entity.** A token-accessor entity alias
  did not bind in testing, so `setup-vault.sh` uses a userpass login, which creates one.
- JWKS: `<issuer>/.well-known/keys`. Discovery: `<issuer>/.well-known/openid-configuration`.
- `kid` and `alg: RS256` are present, and `iss/aud/sub/exp/iat` are all present — the
  claim set OpenAI documents as mandatory.

## The two failure modes, and how to tell them apart

| Symptom | Meaning |
|---|---|
| No *Workload Identity Provider* in Organization Settings | account/plan gating on a personal org |
| `invalid_subject_token` — issuer or audience mismatch | config error; check `iss` and `aud` above |
| Issuer rejected outright | the arbitrary-OIDC-issuer gap: Vault is not a supported provider |
| `invalid_grant` — mapping resolution | no enabled mapping matched, or more than one did |

## If the issuer is rejected

The issuer string is `http://` + an IP literal. With JWKS uploaded, OpenAI never fetches
it, so it may simply be compared as a string — which is the thing under test. If OpenAI
rejects it, the fallback is to give Vault a public HTTPS identity:

1. Tunnel `127.0.0.1:8200` (cloudflared / ngrok).
2. Start Vault with a config setting `api_addr` to the tunnel URL, so the `iss` claim
   itself is the public one. The dev flag alone does not change `api_addr`.
3. Re-run `setup-vault.sh`, re-upload `out/jwks.json`, update the issuer.

That makes Vault look like a conventional public OIDC issuer, which is the closest thing
to a supported configuration this probe can reach.

## Findings

Recorded as the probe runs:

- 2026-10-08 — Vault-side issuer/JWKS/claims verified locally. OpenAI exchange not yet
  attempted (no `platform.openai.com` session available to create the provider).
- Not yet established: whether a personal OpenAI org exposes Workload Identity Provider
  and Service accounts at all.

## Not in scope

No inference calls — the probe stops at the access token. The exchange is an auth
endpoint, so it consumes no tokens and needs no credit. The Admin API key
(`OPENAI_ADMIN_KEY`) is also unnecessary: it can only list/read/delete admin keys, not
create them, and it buys nothing here.
