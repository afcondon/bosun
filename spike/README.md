# Spike: rows-as-type-level-sets for the authoring DSL

**Question.** `DESIGN.md` D-12 claims the type-level MISU guarantees can live
in a hand-written PureScript `.deploy` EDSL using **row types as type-level
sets** — so combinators like `routeTo` / `requiresReady` / `bindsTo` only
typecheck against *compatible* endpoints, and `UncheckableGate` becomes a
*compile* error rather than a validate-time one. This spike falsifies (or
confirms) that claim with the actual compiler.

**Result: CONFIRMED.** Zero dependencies (only `Prim.Row` builtins),
`purs` 0.15.15.

## What it shows

A `Service` is phantom-indexed by a **row** of capability tags
(`reachable`, `hasReadiness`, `lifecycle`). `Prim.Row.Cons` is used as a
*membership test* (does this capability set contain X?), and `Prim.Row.Lacks`
enforces **set semantics** on construction (you can't add a capability twice).

- `Authoring.purs` — the positive module. **Compiles clean** (exit 0):
  ```
  $ purs compile "spike/Authoring.purs"
  [1 of 1] Compiling Authoring
  ```
  The positive cases that compile: routing to a reachable backend; gating on
  an upstream that has a readiness probe; co-life between two lifecycle-managed
  services; building a capability onto a service that lacked it.

- Four negative cases (reproduced below) are each **correctly rejected**:

  | Bad case | Why it must fail | Compiler says |
  |---|---|---|
  | `routeTo mkStaticSite mkWorker` | backend is a `NoNetwork` worker → not `reachable` | Could not match `( reachable :: Present … )` |
  | `requiresReady mkWorker mkStaticSite` | upstream (static site) has no readiness probe | Could not match `( hasReadiness :: Present … )` |
  | `bindsTo mkStaticSite mkProcessReady` | a CDN site isn't lifecycle-managed | Could not match `( lifecycle :: Present … )` |
  | `withReadiness mkProcessReady` | it already has readiness → adding twice | `No … instance … Prim.Row.Lacks "hasReadiness"` |

  The last one is the key result: `Lacks` makes double-adding a capability a
  type error — genuine **set** behaviour, which is exactly the property
  Propellor wanted but couldn't get from a type-level *list* (his stated wart).
  PureScript rows are also **unordered**, so capability sets compare
  order-independently for free.

## Reproduce

```sh
# positive: must compile (exit 0)
purs compile "spike/Authoring.purs"

# negative: each must be REJECTED (nonzero exit). Compile alongside Authoring:
cat > /tmp/B1.purs <<'EOF'
module B1 where
import Authoring (routeTo, mkStaticSite, mkWorker, RouteEdge)
bad :: RouteEdge
bad = routeTo mkStaticSite mkWorker
EOF
purs compile "spike/Authoring.purs" /tmp/B1.purs   # → type error, as intended
```

## Caveat / next step

The error messages are *adequate* but generic ("Could not match type
( reachable :: Present … )"). PureScript's `Prim.TypeError` (`Fail`/`Warn`
custom-message constraints) can turn these into purpose-written diagnostics
(e.g. *"a route's backend must be reachable; `worker` is NoNetwork"*) — a known
technique, deferred to implementation. Not needed to validate the encoding.

**Conclusion for the design:** D-12's two-path MISU stands. Authored
deployments are illegal-by-non-compilation; ingested ones are
illegal-by-`validate`; both land in the same proven `ValidatedDeployment`.
