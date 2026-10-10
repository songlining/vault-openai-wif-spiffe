# Deck outline — Vault and Tokenomics: A FinOps Story

**Source of truth for the deck.** Review and edit this before the `.pptx` is generated.

## Audience and arc

Audience: FinOps and platform engineering, at a customer. They own the AI bill and
cannot currently attribute it.

**Vocabulary rule for this deck:** *credential* is the thing that carries attributes
(the key or token); *identity system* is the platform that issues it (Vault); *workload
identity federation* is the standard industry term. Never use a bare "the identity" —
in a Vault deck it reads as Vault's identity system, which inverts the point of slide 3.

The arc is deliberately **FinOps-led**: the cost pain comes first, identity is named
as the root cause, and "no static secrets" lands last as a dividend rather than the
headline. A security-first opening loses the finance audience; this order keeps both.

Slide 2 carries **both** symptoms of the same object — unattributable spend and
unmanageable keys. That is deliberate: it recruits the security stakeholder into a
deck that opens on cost, and it makes Vault the single answer to both.

```
pain → root cause → the gap → what Vault adds → proof (your existing demo slides)
     → broader value (machine identity, other platforms) → the dividend
```

## Design system (extracted from the existing deck — match it)

| Property | Value |
|---|---|
| Slide size | 16:9 (13.33 × 7.5 in) |
| Background | White |
| Title | `left 0.8, top 0.4, width 11.75, height 1.24` — theme major font, ~48pt, `TEXT_1` |
| Body | Your content slides are **images** (code panels as pictures) |
| Accent | HashiCorp palette — `#02A8EF` blue, `#FFCF25` gold for emphasis |
| Title slide | Dark band across the lower third, white text, 24pt |

New slides use the same title geometry. Value slides are text/bullet slides, since
they carry argument rather than code.

---

## Slide 1 — Title *(existing, unchanged)*

**Vault and Tokenomics – A FinOps Story**

Band text:
- One Issuer
- All Workloads
- Real Business Context

> **Notes:** Open on the finance problem, not the technology. "Every organisation is
> now buying AI tokens. Almost none of them can tell you which team spent them."

---

## Slide 2 — One key, two failures *(NEW)*

Two columns. The point is that the same object causes both failures.

**The bill nobody can split**

- AI spend arrives as one line item
- The key behind it has no owner and no team
- Finance asks which team spent it — nobody can answer
- Allocation becomes a spreadsheet

**The keys nobody can inventory**

- Every team gets its own key
- Copied into CI, wikis, notebooks, tickets
- No inventory, no owner, no expiry
- Nobody can revoke one safely — so nobody does
- Or they bypass you entirely and open their own account

Banner line: **You can't allocate it, and you can't revoke it.**

> **Naming note:** this slide deliberately says *key*, not *artifact*. The whole argument is
> that one object causes both failures, so the object must be named concretely — "artifact"
> reads as a build artefact or a document, not a credential.

> **Notes:** This is the pain slide and it should be uncomfortable. It also recruits
> the security stakeholder into a deck that opens on cost — FinOps does not own key
> rotation, security does. Do not resolve it yet; no product names. "Long-lived,
> unowned, unrotatable, org-wide."

---

## Slide 3 — What the credential doesn't know *(NEW)*

- A GitHub Actions token knows the repo and the ref
- A shared API key knows nothing at all
- Neither has ever heard of your cost centre — or whatever you slice by
- **You can't control what you can't allocate**

> **Notes:** This is the root cause, and it's the sentence the whole deck rests on:
> *you can't control what you can't attribute, and you can't attribute what the
> identity doesn't carry.* It pairs with slide 2's "you can't revoke what you can't
> find" — the two halves of the deck should rhyme. The upstream identity provider
> has no business context; it never has, and it never will.

---

## Slide 4 — OpenAI counts projects *(NEW)*

Banner: **Whatever you attribute by — cost centre, team, product, however you slice
it — that dimension doesn't exist on the OpenAI side.**

- OpenAI reports spend by project and service account — accurate, but they're
  OpenAI's own objects
- What you slice by lives in your identity system, not in OpenAI
- So allocating the spend needs a mapping between the two
- Two ways to bridge it: one project per team, or carry the team in the credential
- Only one of those scales

> **Notes:** Do **not** assert how the customer attributes spend — ask. This slide is
> an invitation: *"how do you attribute AI spend today?"* The answer determines which
> dimensions matter, but the argument holds either way, because the mapping has to
> exist somewhere. Avoid naming cost centre as *the* answer; it is one example among
> several.

---

## Slide 5 — What Vault adds *(NEW)*

- Business identity travels inside the credential
- Whatever your business tracks — here: `project`, `cost_centre`, `bu`
- Every spend carries who caused it
- Every credential records who asked for it — the audit trail writes itself
- Allocation becomes a lookup, not a guess
- Guardrails set once — every workload arrives inside them

> **Notes:** Land the mechanism, then the payoff. The three claims shown are this
> lab's example, not a fixed schema — Vault carries whichever business dimensions the
> customer already uses. The SVID's SPIFFE ID — its `sub`, built from the workload's
> role — travels all the way into the OpenAI credential as `wif_external_subject`, so
> per-workload spend traces back to a business dimension.

---

## Slide 6 — JWT from Vault IdP to OpenAI *(existing, unchanged)*

Existing code panels. No edits.

---

## Slide 7 — Settings on OpenAI *(existing, unchanged)*

Existing panels. No edits.

---

## Slide 8 — JWT from OpenAI back to the client *(existing, unchanged)*

Existing code panels. No edits.

---

## Slide 9 — The Code *(existing, unchanged)*

Existing code panel. No edits.

---

## Slide 10 — Built for machine identity *(NEW)*

- Pipelines, agents, dynamic workloads
- They live for minutes — static keys are the wrong shape
- Every machine that already logs into Vault
- Same guardrails, every workload

> **Notes:** Machine identities are ephemeral by nature; a long-lived key is the
> wrong instrument. Vault's core model is short-lived, dynamically-minted
> credentials for machines — this is what it was built for, and it is the only
> place in the chain holding the business metadata.

---

## Slide 11 — Same identity, different exchange *(NEW)*

- OpenAI and Anthropic both support workload identity federation today
- Same identity, same attributes, same metadata on both
- Only the exchange step differs
- The identity is portable — the client code isn't
- Define who a workload is, once

> **Notes:** We have verified **OpenAI and Anthropic only**. Do not extend the claim
> to other vendors — we have not assessed them, and a customer with a Bedrock or
> Vertex estate will ask. Do **not** say the two are "identical": Anthropic uses
> RFC 7523 `jwt-bearer`, OpenAI uses RFC 8693 token exchange, and rule selection is
> client-side vs server-side. The *identity* is portable; the exchange code is not.

---

## Slide 12 — Nothing left to leak *(NEW, closing)*

**No static secret left to leak.**

- Federated identity is the mechanism
- Cost allocation is the reason
- No long-lived AI key to rotate, leak, or forget

> **Notes:** Close by reframing security as the byproduct of fixing identity for
> cost. "You get this for free — but it was never the reason to do it."

---

## Two questions to be ready for

Both are load-bearing with a FinOps audience. Answering them first makes you the
person with the roadmap rather than the person who missed the gap.

1. **"Show me the spend-by-‹your dimension› report."** It's a join — OpenAI's
   per-project/per-service-account usage against Vault's role → business-dimension
   mapping. The claim *enables* it. Say that; don't say it's built.
2. **"Can I set a budget per ‹your dimension›?"** Budgets are project-scoped, so a
   per-dimension budget implies one project per dimension value. An architecture
   decision, and the natural next step after this demo.
