# Promotion — the gated dev → published edge

**Status:** DESIGN (2026-06-18). Surfaced from a concrete case: Signal-Box runs
locally on `:3009` *and* is published at `signal-box.hylograph.net`. The question
was how to model the relationship between a service's local-dev form and its
published form — and the answer generalises to a typed edge that is the
build↔deploy seam of `UNIFIED-DAG-VISION` / `[[three-DAG]]`.

## The pattern

You develop a service **locally**, and at a milestone you **publish** it —
often **gated** (tests green, a release tag, a manual nod). The local form and
the published form are clearly *the same thing*, but they are not the same
*deployment*, and they are not in lockstep.

Two tempting framings, both wrong on their own:

- **"Two linked services."** Duplicates the identity. You lose the truth that
  it's one thing, and every cross-reference has to pick a side.
- **"One service, two symmetric ways of being served."** Closer — but they are
  *not* symmetric. The published form **lags** the local one (it's a snapshot at
  a milestone, not a live mirror); crossing from local to published is an **act**
  (build, test, deploy), not a config toggle; and the crossing is **gated**.

## The model: one node, many facets, a directed gated promotion edge

A logical service is **one node**. Bosun's reconcile/divergence model already
gives it **multiple facets** (per-(host, executor) placements grouped under one
identity — `tilted-radio` is `mbp/Process` *and* `macmini/Container` today). So:

- a **dev facet** — `mbp` / `Process` / a local port, serve-managed;
- a **published facet** — e.g. `cloudflare` / `StaticCDN` with a `Published`
  address, or `macmini` / `Container` behind the edge.

What's new is the **edge between facets**: a directed, gated **promotion**.

```
service ──dev facet──▶ runs locally (mbp / Process / :PORT, serve-managed)
   │
   └─[ build + gate ]─▶ published facet (the deployed artifact)
```

The promotion edge carries exactly what the relationship is about:

- **Direction** — the dev facet is the authoritative *upstream source*; the
  published facet is the *downstream artifact*. Never the reverse.
- **A gate** — a typed precondition on crossing: tests green, a release tag, a
  manual approval. (Analogous to — but distinct from — the *startup* gates in
  `Bosun.Edge`: those say "when may a dependent **start**"; a promotion gate says
  "when may this be **published**." A quality gate, not an ordering gate.)
- **Freshness** — is the published facet **stale** relative to the dev facet's
  current source? This is the `[[three-DAG]]` build↔deploy freshness edge made
  first-class: "published is N commits / one failing test behind local."

## Worked examples

**Signal-Box** (the trigger):

| facet | host | executor | reachability | managed by |
|---|---|---|---|---|
| dev | `mbp` | `Process` (`python3 -m http.server`) | `:3009` | `bosun serve` (lazy-spawn) |
| published | `cloudflare` | `StaticCDN` | `signal-box.hylograph.net` (`Published`) | a publish step |

Promotion: `dev ─[build webapp/public + tests]→ published`. Today the two exist
independently; the model should record the published facet and the edge so
"where does Signal-Box live?" answers *both*, with the freshness between them
visible.

**Polyglot / MacMini** (the same edge, a different substrate — this is the
unification): the showcases and site develop **locally** (served by `bosun serve`
on the MBP) and publish to the **MacMini Docker deploy** (`macmini` /
`Container`, behind the edge, some `Published` via tailscale funnel) — and the
static sites publish to **Cloudflare Pages**. The promotion edge is the *same
type*; only the published facet's substrate differs (`Container` vs `StaticCDN`).
One edge type spans Process→Container and Process→CDN — exactly the cross-tool
unification Bosun exists to provide.

## Why this is the build↔deploy seam

`[[three-DAG]]` unifies version-control → build → deploy → runtime as one
typed-edge DAG. The promotion edge **is** the typed crossing from the **runtime**
view (the dev facet, running locally) to the **deploy** view (the published
facet) — and its gate + freshness are precisely the seam that doc flagged as the
thing to make first-class. Bosun already owns both ends (it serves the local dev
facet and it `apply`s the macmini/Cloudflare deploy); promotion is the edge that
joins them under one model.

## What this is NOT

- **Not a live mirror.** The published facet deliberately lags; the freshness
  edge measures by how much. Conflating them (a "redirect" or a sync) would lose
  the milestone semantics.
- **Not automatic.** Crossing is an act. Bosun *reports* the gate/freshness
  state; a future `bosun publish` (build → run the gate → deploy to the facet's
  substrate) is what *enacts* it — with the user's go, like every outward step.
- **Not a new identity.** One node. The promotion edge is between its facets, not
  between two services.

## Consequences / what to build (later)

- A **promotion edge type** in `Bosun.Edge` (`promotes-to` / `published-from`),
  gate-bearing, sibling to `Requires`/`BindsTo` — directed, with a typed gate
  condition.
- First real use of the `StaticCDN` facet (Cloudflare) and reuse of the
  `Container` facet as **publish targets**, not just runtime placements.
- A **freshness check** — published vs the dev facet's source HEAD (the
  quartermaster/stale-source idea), surfaced wherever the node is shown.
- A `bosun publish <service>` path: resolve the promotion edge → run the gate →
  build → deploy to the published facet's substrate (Cloudflare Pages push;
  ssh `docker compose up -d` on macmini). Reuses the existing apply command tier.

Not built now — this is the design the next phase slots into; the immediate work
is the SSOT registry (Phase 1 done) and fixing the rejected dev rows (Phase 2).
