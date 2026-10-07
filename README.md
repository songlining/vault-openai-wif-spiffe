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

Everything runs in Podman. Nothing is installed or run on the host.

```bash
./run-vault.sh       # Vault 2.1.2 container -> http://127.0.0.1:8200
./setup-vault.sh     # OIDC key/role + caller, writes out/jwks.json, prints what to paste
./mint-token.sh      # mint the subject JWT, assert it has the claims OpenAI requires
./exchange.sh        # POST auth.openai.com/oauth/token, no API key
./stop-vault.sh      # remove the container
```

`run-vault.sh` uses `hashicorp/vault:2.1.2` — the current release. Bump the tag in that
script when a newer one lands.

Dev mode means in-memory storage and an auto-unsealed server, so **state is lost when
the container is removed**; `run-vault.sh && setup-vault.sh` rebuilds it in seconds.
That is the right trade here, because the thing under test is the JWT's issuer and
claims, not Vault's storage or HA story.

## Does this need ngrok?

Only if you use OIDC **discovery**. OpenAI can be given Vault's keys two ways:

| Mode | Does OpenAI fetch anything? | Public exposure needed? |
|---|---|---|
| **Uploaded JWKS** | No — you paste the key set; the issuer URL is only compared as a string against the `iss` claim | **No** |
| **OIDC discovery** | Yes — `https://<issuer>/.well-known/openid-configuration`, then the `jwks_uri` | **Yes** — public HTTPS on 443, real DNS name, no IP literals |

So the probe tries **uploaded JWKS first, with no tunnel**. If OpenAI rejects
`http://127.0.0.1:8200/v1/identity/oidc` as an issuer string, that is itself the finding,
and the tunnel is the fallback (below).

## The two manual clicks

OpenAI has **no API and no Terraform resource** for these two objects — the documented
OpenAPI spec has 228 paths and none of them create a Workload Identity Provider or a
mapping. This is the only non-scriptable part of the flow.

1. **platform.openai.com → Settings → Organization → Security → Workload Identity Provider**
   - OIDC Issuer URL: what `setup-vault.sh` printed
   - Audience: same
   - Enable **"Use uploaded JWKS for token verification"** and paste `out/jwks.json`
     (this is what avoids the public-HTTPS discovery fetch)
   - Record the provider ID → `OPENAI_IDENTITY_PROVIDER_ID`
2. **Project → Service accounts → create**, then on the provider page **Create mapping**
   targeting that service account, matching on `sub`
   - Record the service account ID → `OPENAI_SERVICE_ACCOUNT_ID`

```bash
cp .env.example .env   # fill in the two IDs
```

## Verified: what Vault actually issues

Measured against Vault v2.1.2 in Podman, not read off a doc page:

```json
{
  "aud": "https://api.openai.com/v1",
  "exp": 1791414898,
  "iat": 1791414298,
  "iss": "http://127.0.0.1:8200/v1/identity/oidc",
  "namespace": "root",
  "sub": "3e87a74f-2a29-2226-1807-87dc3eb01a7f"
}
```

Things that cost time to work out:

- **The machine-token issuer is `<api_addr>/v1/identity/oidc`** — *not* the provider
  path. `identity/oidc/provider/<name>` is for the browser authorization-code flow and
  advertises a different `iss`. For WIF you want the plain identity/oidc issuer.
- **`api_addr` is what the issuer is built from**, and dev mode honours it from a config
  file (`vault.hcl`), not from the `-dev` flags. This is the knob for the tunnel case.
- **`aud` comes from the role's `client_id`.** Set it to whatever you type into OpenAI's
  Audience field, and make sure the key's `allowed_client_ids` permits the same value.
- **No provider and no scope are needed** for machine-to-machine. Key + role is enough.
  (`identity/oidc/scope/openid` is reserved and cannot be created.)
- **Minting requires the calling token to have an entity.** A token-accessor entity alias
  did not bind in testing, so `setup-vault.sh` uses a userpass login, which creates one.
- JWKS: `<issuer>/.well-known/keys`. Discovery: `<issuer>/.well-known/openid-configuration`.
- `kid` and `alg: RS256` are present, and `iss/aud/sub/exp/iat` are all present — the
  claim set OpenAI documents as mandatory.

## The failure modes, and how to tell them apart

| Symptom | Meaning |
|---|---|
| No *Workload Identity Provider* in Organization Settings | account/plan gating on a personal org |
| `invalid_subject_token` — issuer or audience mismatch | config error; check `iss` and `aud` above |
| Issuer rejected outright | the arbitrary-OIDC-issuer gap: Vault is not a supported provider |
| `invalid_grant` — mapping resolution | no enabled mapping matched, or more than one did |

## If the issuer is rejected

Give Vault a public HTTPS identity so the `iss` claim is one OpenAI will accept:

1. Tunnel `127.0.0.1:8200` (cloudflared / ngrok).
2. Set `api_addr` in `vault.hcl` to the tunnel's URL, then `./run-vault.sh` again.
   The issuer becomes `https://<tunnel-host>/v1/identity/oidc`.
3. Re-run `setup-vault.sh`, update the issuer in OpenAI, and either re-upload
   `out/jwks.json` or switch the provider to OIDC discovery.

Use a **stable** hostname. A free quick tunnel gets a new random name on every restart,
which changes the `iss` claim and forces you to update the provider each time — and
OpenAI caches discovery and JWKS for 600 seconds.

## Findings

Recorded as the probe runs:

- 2026-10-08 — Vault-side issuer, JWKS and claims verified on v2.1.2 in Podman.
- 2026-10-08 — OpenAI exchange not yet attempted (no `platform.openai.com` session
  available to create the provider).
- Not yet established: whether a personal OpenAI org exposes Workload Identity Provider
  and Service accounts at all.

## Not in scope

No inference calls — the probe stops at the access token. The exchange is an auth
endpoint, so it consumes no tokens and needs no credit. The Admin API key
(`OPENAI_ADMIN_KEY`) is also unnecessary: it can only list/read/delete admin keys, not
create them, and it buys nothing here.
