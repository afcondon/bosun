# Bosun — Scenario Corpus

A test-bench for the type design (`DESIGN.md`), to be worked *before*
implementation. Each scenario is a real or invented deployment pattern; for
each we ask **does the model express it cleanly, reject it correctly, or
strain?** Strain points become the design agenda — they are collected in §E.

The discipline: a type design is only as good as the scenarios it survives.
We would rather find the awkward case here, on paper, than discover it
mid-implementation.

Legend: ✅ expresses cleanly · 🛑 should be *rejected* (and by which
mechanism) · ⚠️ strains the model → see §E.

---

## A. Canonical topologies — does the model express them?

### A1. Single static site ✅
A Cloudflare-Pages site (e.g. `hylograph.net`): no dependencies, no host
port, no health check, no restart.
- `Executor = StaticCDN { provider: Cloudflare, domain }`,
  `Exposure = PublicDomain domain`, `Health = all NoProbe`,
  `RestartPolicy = Never`, no edges.
- *Tests:* the portless, healthless, depless corner. The `Health` record of
  all-`NoProbe` must be legal. **OK.**

### A2. Three-tier: frontend → api → db ✅
Classic. `frontend Requires(OnReady) api`, `api Requires(OnReady) db`.
- `BootOrder = [[db], [api], [frontend]]` — three stages, each gated on the
  prior's readiness.
- *Tests:* gate chain; boot-order stage derivation. **OK** — this is the
  happy path the whole pipeline exists for.

### A3. Reverse-proxy fan-out (the polyglot edge) ✅
`edge` proxies N backends by path; `edge Requires(OnReady) website`; each
backend has an inbound `RoutesTo path` edge from `edge`.
- *Tests:* `RoutesTo` edges as first-class; the route table is the set of
  `RoutesTo` edges out of `edge`. Boot order puts `edge` last (it `Requires`
  what it routes to? — see ⚠️ E1: does routing imply a *requirement* edge,
  or only an ordering one?). **Mostly OK; surfaces E1.**

### A4. Worker + queue (no inbound network) ✅
A background worker consuming from Redis: `worker NoNetwork`,
`worker Requires(OnHealthy) redis`, `redis` health via `TcpConnect`.
- *Tests:* `NoNetwork` exposure; non-HTTP (`TcpConnect`) health; a node that
  nothing depends on (leaf consumer). **OK.**

### A5. Sidecar / co-process (BoundTo) ✅
A log-shipper that must live exactly as long as its app: `shipper BoundTo app`.
If `app` dies, `shipper` must be stopped too.
- *Tests:* `BoundTo` co-life semantics — distinct from `Requires` (ordering +
  readiness) in that it also propagates *shutdown*. The planner must read
  `BoundTo` when computing `Stop` changes, not just `Start`. **OK, but note
  the planner obligation (E5).**

### A6. One-shot migration job (OnCompleted) ✅
A DB migration that runs to completion, then the API starts:
`migrate RestartPolicy=Never`, `api Requires(OnCompleted) migrate`.
- *Tests:* a non-long-lived service (it's *supposed* to exit 0);
  `Gate = OnCompleted`; the planner must treat "exited 0" as success, not
  "down → restart." This is compose `service_completed_successfully` /
  k8s initContainer / a one-shot systemd unit. **OK, but the WorldState
  model must distinguish "exited 0 (done)" from "exited ≠0 (failed)" from
  "not running" — see E6.**

### A7. Unix-socket daemon (the music rig) ✅
`es9-daemon` reached at `~/.es9/control.sock`; a consumer
`Requires(OnReady) es9-daemon`, readiness probed via `SocketReady path`.
- *Tests:* `UnixSocket` exposure + `SocketReady` probe. A model assuming
  service⇒TCP could not even describe this. **OK — breadth pays off.**

### A8. Same service, two facets (the reconciliation case) ✅→⚠️
`psd3-tilted-radio` deployed *both* as mbp-native (SDI-spawned, port 3013)
and macmini-container (behind edge, no host port). Same `ServiceId`, two
facets differing on host/port/mechanism.
- *Tests:* facet partitioning; agreement on invariants (project, role,
  dep-shape) vs intended divergence (host/port/mechanism). **Surfaces E2
  (single-facet ≠ drift) and E3 (which fields are "must-agree").**

---

## B. The should-reject set — does `validate` catch them?

### B1. Dependency cycle 🛑 `DependencyCycle`
`a Requires b`, `b Requires a`. Topo-sort fails → no `BootOrder` → no
`ValidatedDeployment`. Unrepresentable past `validate`.

### B2. Dangling dependency 🛑 `DanglingDependency`
`frontend Requires "bakend"` (typo). No `ServiceId` resolves → `validate`
refuses to mint the `ServiceRef`. *But:* does this apply to **soft** edges
(`Informs`) too? — see E4.

### B3. Port collision 🛑 `PortCollision`
Two services both `HostPort 3000` on the same host. (Note: *different* hosts
is fine — that's A8's facets.) `validate` groups by `(host, port)` and
rejects multiples.

### B4. Profile not closed 🛑 `SelectorNotClosed`
`frontend` in profile `web`, `frontend Requires backend`, but `backend` not
in `web`. Starting `--profile web` would bring up a frontend with no backend.
The universal "selector closed under `Requires`" invariant. (Real-world
cousins: kustomize overlay with a Deployment but not its ConfigMap; a systemd
target that `Wants` a unit whose `After`-dep isn't pulled in.)

### B5. Uncheckable gate 🛑 `UncheckableGate`
`api Requires(OnHealthy) db`, but `db.health.readiness = NoProbe`. The gate
can never be satisfied (hang) or is silently ignored (blind race). Every tool
lets you write this; Bosun rejects it. *This is the sharpest "many illegal
states" example* — the gate and the probe are written in different places and
nothing cross-checks them.

### B6. Route without backing 🛑 `RouteWithoutBacking`
`edge RoutesTo "/sankey"` but no service answers at that target. (The real
"comment says /sankey, nothing serves it" bug.) Mirror:
`ServiceExpectsRouteButNone` — a service marked as needing edge routing with
no inbound `RoutesTo`.

### B7. image + build both 🛑 *Tier-1, unrepresentable*
compose lets you set `image:` and `build:` together (ambiguous). Bosun's
`ContainerSpec.source :: Either ImageRef BuildContext` makes it
unconstructable. Caught at *ingestion*, not validation.

### B8. Relative / missing cwd 🛑 *Tier-1, unrepresentable* → `SdiContractViolation`
The real SDI row `node router.mjs` (no `cd /abs`). `mkAbsPath` returns
`Nothing` → can't construct a `Process` executor → flagged at ingestion.

### B9. Cross-source drift 🛑 `CrossSourceDrift`
Registry says `psd3-tilted-radio` is role `frontend`; compose's
`tidal-frontend` (same `ServiceId`) says role `backend`. Disagreement on a
must-agree field. (Contrast A8: host/port differing across facets is *fine*.)

---

## C. Edge cases that stress the design

### C1. Internal service *with* a health check ⚠️→✅ (E7)
A compose service behind the edge: **no host port**, but a `healthcheck`
that hits `http://localhost:<internalPort>/` *inside the container*.
- Requires: `Exposure = InternalPort p` AND `Health.liveness = HttpGet { port: p, … }`
  referencing that same internal port.
- *Strain:* is a `Probe`'s port allowed to be an internal (non-host-exposed)
  port? It must be — health probes run from inside the container/host. So
  `Probe` ports are **not** constrained to be host-exposed. Resolved as a
  *note*: probes address the service's own listening port, host-published or
  not. **OK once stated (E7).**

### C2. A backend that is *both* port-bearing and routed ✅
`minard` listens on `InternalPort 3000` *and* has an inbound `RoutesTo "/code"`
from `edge`. Exposure (how it listens) and the route edge (how it's reached
from outside) are **orthogonal** — the separation holds. **OK** — validates
the Exposure-vs-edge split.

### C3. Fan-in: one DB, many APIs ✅
Five APIs each `Requires(OnReady) db`. `BootOrder = [[db], [api1..api5]]` —
the five APIs share stage 1 (independent → parallel within the stage = the Go
errgroup). **OK** — and a nice demonstration of why `BootOrder` is stages-of-sets,
not a flat list.

### C4. Optional dependency, absent ⚠️ (E4)
`app Informs cache` (soft: start cache if present, don't fail if not), and
`cache` isn't in the deployment.
- *Strain:* B2 says a dependency target that doesn't resolve is
  `DanglingDependency`. But a *soft* (`Informs`) edge to an absent service
  should arguably be *dropped with a warning*, not a hard error. So
  resolution must be **edge-kind-aware**: hard edges (`Requires`/`BoundTo`/
  `RoutesTo`) dangling = error; soft (`Informs`) dangling = drop+warn. **→ E4.**

### C5. Restart backoff masking liveness ⚠️ (E6)
A service crash-looping: launchd `ThrottleInterval`/systemd
`StartLimitIntervalSec` means it *looks* down for ~40s while actually being
restarted. (The documented Marginalia gotcha.)
- *Strain:* `WorldState` must distinguish `Running` / `Starting` / `InBackoff`
  / `Failed` / `Down` / `CompletedOk`, not a boolean. `plan` must not emit a
  redundant `Restart` for a service already in backoff. **This is a WorldState
  type question, not a Deployment one → E6.**

### C6. Env interpolation: `${VAR:-default}` ⚠️ (E8)
compose `${PORT:-3000}` — bound from env, or defaulted, or unbound.
- Only **unbound with no default and no supplier** is `UnboundReference`.
  Requires a `ConfigSource` model that tracks suppliers (env / env_file /
  ConfigMap) and resolves references against them. **→ E8.**

### C7. A service with multiple selectors ✅
compose lists a service in `["minard","full"]`. `selectors :: Array Selector`
— many-to-many membership. **OK.**

### C8. Single-facet service ⚠️ (E2)
A service that exists *only* in the registry (mbp-dev) with no compose
counterpart, or vice-versa.
- *Strain:* reconciliation must NOT flag a single-facet service as "drift"
  (missing from the other source). Drift is *disagreement between present
  facets*, not *absence of a facet*. The model needs "expected facet set" vs
  "observed facet set" to even ask the question — or it simply never
  complains about absence. **→ E2.**

---

## D. Cross-tool translation — does the lingua-franca claim hold?

These are the deepest tests. The thesis is that the IR is the intersection of
what tools mean and the union of what they forbid. Translation will be *lossy*;
the question is whether the loss is acceptable and where the escape hatch goes.

### D1. compose round-trip fidelity ⚠️⚠️ (E9 — the big one)
Ingest a real `docker-compose.yml` → IR → emit `docker-compose.yml`,
byte-identical (the MVP differential test).
- *Strain:* compose has fields the IR deliberately doesn't model — `networks`,
  `volumes`, `deploy.resources`, `logging`, `cap_add`, arbitrary labels.
  A pure intersection-IR **cannot** round-trip them → not byte-identical.
- *The tension:* lingua-franca (small, clean, cross-tool) **vs** lossless
  round-trip (must carry every source field). This is the open-vs-closed-record
  problem every typed-config system faces (Dhall, CUE, Nix all have a stance).
  Likely resolution: an **`unmodeled :: Json` passthrough** per node, carried
  through ingest→emit but invisible to reconcile/validate/plan. Decide
  deliberately — see E9. *This may be the single most important design call.*

### D2. EdgeKind across tools — lossy both ways ⚠️ (E10)
- compose `depends_on` (flat + `condition`) → has no `BoundTo`, no `Informs`
  distinction. Emitting IR→compose must *collapse* `BoundTo`→`depends_on`
  (losing co-life shutdown) and *drop* `Informs` or render as plain
  `depends_on`.
- systemd → has the full taxonomy but no native `Profile` (selectors map to
  `.target` + `WantedBy=`, imperfectly).
- *Tests:* which `EdgeKind`s survive a round-trip through which tool? Build a
  fidelity matrix (EdgeKind × tool: preserved / collapsed / dropped). The
  lossy cells are *expected* but must be **reported**, not silent. **→ E10.**

### D3. launchd `KeepAlive` richer than `RestartPolicy` ⚠️ (E11)
launchd `KeepAlive` can be a bool *or* a conditional dict
(`{SuccessfulExit, NetworkState, PathState, OtherJobEnabled, …}`).
- *Strain:* `RestartPolicy = Never|OnFailure|Always|UnlessStopped` cannot
  express "restart only while path /x exists." Conditional KeepAlive →
  `Always` loses the condition. Either enrich `RestartPolicy` (a
  `RestartCondition` set) or accept the loss + report it. **→ E11.**

### D4. k8s readiness gate ↔ compose condition ↔ systemd notify ✅(?)
All three express "wait until upstream is ready before starting dependent":
k8s readinessProbe + (no native gate — uses init/ordering), compose
`condition: service_healthy`, systemd `Type=notify`. They *should* all map to
`Requires(OnReady)` + a `readiness :: Probe`. *Tests:* whether the
readiness/liveness/startup triple is the right universal shape. Tentatively
**yes** — this is the part of the panoply that converges cleanly. Confirm
against prior art (the research agent).

---

## E. Open design questions surfaced (the polish agenda)

These are the deltas between the current `DESIGN.md` types and what the
scenarios demand. Each needs a decision before implementation.

> **Status after the prior-art survey (`PRIOR-ART.md`).** Several are now
> resolved and folded into `DESIGN.md`:
> - **E1 ✓** — `RouteEdge` is a separate data graph and does *not* imply
>   ordering; a companion `Inferred (Requires OnReady)` dep edge is derived.
> - **E4 ✓** — resolution is edge-kind-aware by construction: `Wants` means
>   "absent is OK" (drop+warn); hard requirements dangling = error.
> - **E6 ✓** — `WorldState` is now three-way (desired/recorded/observed,
>   Terraform D-7) with a rich `Status` enum incl. `InBackoff`/`CompletedOk`.
> - **E9 ✓✓** — resolved by **open-ingest / closed-validate** (CUE, D-4):
>   `extra :: Map String Json` passthrough preserves byte-identical round-trip;
>   `validate` unifies against a closed `#Service` and *reports* survivors.
> - **E10 (partial)** — the EdgeKind fidelity matrix is still TODO, but the
>   richer `Requirement` gradient (Wants/Requires/Requisite/BindsTo/PartOf)
>   means we now know *what* must be preserved/collapsed/dropped per tool.
>
> **Now all resolved — see `DECISIONS.md`:** **E2** (single-facet ≠ drift;
> opt-in `expectedFacets`), **E3** (three-tier facet model; "drift" splits
> into facet-divergence vs conflict), **E5** (backward transitive-closure
> Stop/restart propagation over `BindsTo`/`PartOf`, terminates by acyclicity),
> **E7** (probe ports are the service's own listening port, unconstrained by
> host-exposure), **E8** (`ConfigRef`/`ConfigSupplier` resolution at validate),
> **E11** (enriched `RestartPolicy` = base + portable `RestartCondition`s;
> exotic launchd `KeepAlive` keys ride in `extra`, reported on lossy emit).
> Deferred (non-blocking): **E10** (the full EdgeKind×tool fidelity matrix —
> a per-adapter implementation-time task).

- **E1. Does `RoutesTo` imply a `Requires` ordering edge?** A proxy should
  start after (and arguably require the readiness of) what it routes to — or
  should routing and ordering be independent edges you can both assert?
  *Leaning:* `RoutesTo` implies an ordering+readiness obligation, so a route
  edge contributes to `BootOrder` and to the `UncheckableGate` check. (A3, C2.)
- **E2. Single-facet ≠ drift.** Reconciliation must treat *absence* of a facet
  as normal, and flag only *disagreement* between present facets. Needs an
  explicit "is multi-facet expected?" notion, or a policy of never complaining
  about absence. (A8, C8.)
- **E3. Which fields must agree across facets?** Project, role, and dependency
  *shape* = must-agree (disagreement = `CrossSourceDrift`). Host, port,
  mechanism = may-diverge (that's what a facet *is*). Pin the exact partition.
  (A8, B9.)
- **E4. Edge-kind-aware dependency resolution.** Hard edges
  (`Requires`/`BoundTo`/`RoutesTo`) to an absent target = `DanglingDependency`;
  soft (`Informs`) to absent = drop + warn. Resolution is not uniform. (B2, C4.)
- **E5. The planner reads `BoundTo` for shutdown,** not just startup — `Stop`
  changes must propagate along co-life edges. `Plan` is not only about
  `Start`. (A5.)
- **E6. `WorldState` is a rich status, not a boolean.** At least
  `Running | Starting | InBackoff | Failed | Down | CompletedOk`. `plan` must
  not double-restart a backing-off service, and must treat `CompletedOk` as
  success for `OnCompleted` gates. (A6, C5.)
- **E7. `Probe` ports are the service's own listening port** (host-published
  or internal), not constrained to host-exposed ports. State this; don't
  over-constrain. (C1.)
- **E8. `ConfigSource` model with supplier tracking** so `${VAR:-default}`
  resolves to bound / defaulted / `UnboundReference`. (C6.)
- **E9. ⚠️ THE BIG ONE — open vs closed records / unmodeled passthrough.**
  Does each node carry an `unmodeled :: Json` (or per-source raw) blob so
  ingest→emit can round-trip fields the IR doesn't model, enabling the
  byte-identical differential test? Or is the IR deliberately closed and
  "round-trip" means "semantically equivalent, not byte-identical"? This is
  the lingua-franca-vs-fidelity tension. Study how Dhall/CUE/Nix resolve open
  vs closed before deciding. (D1.)
- **E10. EdgeKind translation fidelity matrix** (EdgeKind × target tool:
  preserved / collapsed / dropped), and a rule that lossy emits are
  *reported*, never silent. (D2.)
- **E11. Is `RestartPolicy` rich enough** for conditional launchd `KeepAlive`?
  Enrich with `RestartCondition`, or accept+report the loss. (D3.)

---

## F. Scenarios still to write (TODO)

- Secrets/credentials lifecycle (rotation, never-in-logs).
- Multi-host scheduling (a service pinned to `macmini` vs `mbp`) and the host
  as a constraint in `plan`/`apply`.
- Rolling vs blue-green vs canary `apply` (post-MVP `Rollout`).
- Continuous reconcile loop (controller style) vs one-shot `apply`.
- A genuinely large graph (the full ~44-entry registry) — does the DAG view
  stay legible? (Connects to the hierarchical-force-rollup work.)
- Partial deployment / targeted apply ("just bring up the `minard` profile").

---

## G. Property-based testing — generalizing the corpus

The scenarios above are **examples**. The type design's claims are
**properties**, so the corpus wants a property-based companion (QuickCheck
family) that turns each example into a population. The decisive design choice
is *what to generate* — get that wrong and the generators re-encode the rules
(and the bugs); get it right and the generators can't disagree with the spec.

### The rule that avoids the buggy-generator trap

**Generate the *tight typed value*; derive everything else.** A generator for
`ValidatedDeployment` (a type that by construction can only express legal
deployments) cannot produce an illegal one — an attempt won't compile. So the
generator carries *no rule knowledge to get wrong*; the types are the spec.
The thing **not** to build is a hand-rolled generator of config **text** that
re-encodes well-formedness and hopes for coverage — that is exactly where a
complex `Arbitrary` grows its own bugs.

### Property families (each needs only well-typed generators)

1. **Round-trips (no oracle needed).** `ingest (emit vd) == Right vd` —
   the byte-identical differential test (D1), generalized from one hand-written
   case to a population. `validate`-after-`loosen` recovers the original.
2. **Algebraic laws — test the claims we asserted.** D-3 says `reconcile` is a
   lattice meet: **commutative, associative, idempotent**. PBT is purpose-built
   for this — permute source order, feed a source twice, regroup the merges;
   the result must be identical. (Order-independence of reconciliation is a
   property, not an example.) Likewise: a consistent rename across all sources
   yields the same `ValidatedDeployment` up to the rename (identity stability).
3. **Structural invariants.** For every dependency edge `A → B`, `B`'s
   `BootOrder` stage precedes `A`'s (topological correctness). No `ServiceRef`
   dangles. Every selector is closed under `Requires`. Every route is backed.
4. **Fault injection — the must-fail corpus, generalized *safely*.** Generate a
   *legal* deployment, then apply **one small typed break** and assert the
   *specific* error: `introducePortCollision → PortCollision`,
   `dangleADependency → DanglingDependency`, `addBackEdge → DependencyCycle`,
   `dropGatedReadinessProbe → UncheckableGate`. The injectors are individually
   trivial and checkable — the antithesis of a monolithic `Arbitrary`. B1–B9
   become B1–B9 *populations*.
5. **Convergence (the rebuilder's whole point).** `plan` then `apply` then
   `plan` again = no-op; `apply` over a `BootOrder` stage is order-safe.

### The validity partition (Kerckhove / Notothenia)

This is the `GenValid` (legal) vs *fault-injected invalid* split, and it is
**[[Notothenia]]'s thesis exercised** — Bosun's test strategy is a concrete
instance of the QuickCheck-family approach designed for these linting engines
(validity-based generator partition; scope-minimization-as-shrinking). The
example corpus (must-pass A1–A8, must-fail B1–B9) and the generators
**cross-validate**: the must-pass shapes should lie in the valid generator's
range; the must-fail ones should be reachable by the injectors.

### Honest caveats (where the real work is)

- **Shrinking a graph is non-trivial.** A shrinker must preserve well-typedness
  *and* the invariant under test (drop-a-node-and-its-edges, drop-an-edge,
  canonicalize a port toward a fixed value). Prefer **integrated /
  Hedgehog-style shrinking** if a PureScript library offers it — it removes the
  whole "shrinker disagrees with generator" bug class.
- **Keep text-fuzzing narrow.** A *dumb* generator of malformed bytes/structure
  is fine for the weak assertion "`ingest` rejects garbage gracefully (returns
  `V Errors`, never crashes)." Do **not** try to make a text generator that
  produces *meaningfully varied valid* configs — that is the trap.

### Verdict

Not a blind alley — *if* aimed at laws / round-trips / fault-injection over
typed generators. The "AI-writes-one-big-`Arbitrary`-over-config-text-and-we-
hope" version is the blind alley the typed approach specifically avoids. An AI
is well-suited to the *safe* version: well-typed value generators + a library
of small, single-purpose fault injectors + graph shrinkers.
