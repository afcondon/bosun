# Frozen polyglot corpus — 2026-06-14

A snapshot of the **real** deployment mess as it stood on 2026-06-14, captured
*before* the #134 polyglot redeploy reshapes (and likely simplifies) it.

- `registry.json` — the live Marginalia port registry (`GET
  http://andrews-mac-mini:3100/api/ports`), 44 server rows.
- `docker-compose.yml` — `polyglot-deploy/docker-compose.yml` verbatim.

## Why this is here

Bosun's **Detect** tier (reconcile / validate / drift) earns its keep on
*heterogeneous, multi-source, real-world* config — exactly the thing a clean
greenfield redesign throws away. So we freeze the mess as an asset. The
findings over this corpus are locked as a golden regression gate
(`scripts/corpus-check.sh` vs `expected-check.txt`), so Detect coverage cannot
silently degrade as the adapters evolve — and it stays valid forever,
independent of what happens to the live rig.

This is the seed of the **parser-hardening track** (BUILD-PLAN §7): the next
layer adds targeted edge-case assertions (map-form `depends_on`, `ssh` rows →
`Remote`, NULL/prose `startCommand`, the SDI `node router.mjs` footgun, the
stale `anscombe`, routes-in-a-comment) on top of this baseline.

## What Bosun finds here (the golden output)

- **1 validation error** — a real `macmini:80` port collision: the edge router
  is claimed twice (`tango-hotel-victor-victor:edge` and a second `edge`).
  This is why `bosun plan`/`apply` correctly *refuse* to deploy the rig as-is.
- **15 facet divergences** (informational) — services deployed two ways:
  `(mbp, MechProcess)` native + `(macmini, MechContainer)` containerised. This
  is the §7 story, including `uniform-romeo-romeo-juliet:frontend`
  (tilted-radio). Divergence is *expected*, not drift (D-E2/E3).

Regenerate the golden file deliberately (and review the diff) only when a real
adapter improvement is meant to change the findings:

```
spago run -p bosun-cli -- check \
  fixtures/polyglot-2026-06-14/docker-compose.yml \
  fixtures/polyglot-2026-06-14/registry.json \
  > fixtures/polyglot-2026-06-14/expected-check.txt
```
