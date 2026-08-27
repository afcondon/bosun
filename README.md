# Bosun

A typed **deployment-configuration reconciler** — and the MVP-gating showcase
for the PureScript→Go backend. (A bosun keeps a ship's whole rig in working
order.)

A deployment is a **typed directed graph**: services are nodes, dependencies
are typed edges, a small set of executors bring nodes to life. Bosun's core
IR is a **lingua franca** that docker-compose, systemd, Kubernetes,
Terraform, launchd, Procfiles, and the local registry all *project onto* —
each tool becomes an adapter that parses **into** the IR and renders **out
of** it.

The point is **"parse, don't validate"** at two altitudes: messy config
strings become precise typed values (ingestion), and a loose multi-source
`Deployment` becomes a tight `ValidatedDeployment` with a proven-acyclic
boot order (validation) — after which `plan` and `apply` are *total*. The
showcase: **"the dozen ways your deploy breaks at 3am — and the half the
compiler won't let you write."**

## Status — built and running (2026-06-15)

Not "design, no code" any more. Bosun is built through **Phase 7** (the
resident router) plus **Bosun's Chair** (the front-end), and its pure
**Detect** tier (`ingest → reconcile → validate → plan`) runs **byte-identical
on node and on the purescript-go binary** — the backend-go MVP gate is green.
A backend-go–compiled binary has **deployed a running rig (HTTP 200)**.

| Capability | State |
|---|---|
| Ingest adapters (compose, registry, start-command) | ✅ pure `Json → ServiceInstance` |
| `reconcile` — facet model, cross-source aliasing | ✅ divergence vs. conflict (D-E3) |
| `validate` — the tight `ValidatedDeployment` | ✅ B1–B6 + Kahn `BootOrder` |
| `plan` — pure planner (D-E5 stop-propagation) | ✅ |
| `observe` — the observation edge (read-only) | ✅ sync probes → total `Status` |
| `apply` — pure command-gen + live os-exec | ✅ `--dry-run` + live; deploys a rig |
| `serve` — resident lazy-spawn router (ex-SDI) | ✅ admission / proxy / hot-reload |
| Go conformance (Detect tier, byte-identical) | ✅ `scripts/go-conformance.sh` |
| Go apply (native binary deploys) | ✅ `scripts/go-apply.sh` |
| Bosun's Chair (Halogen front-end) | ✅ v1 watch + control |
| Stress suite (PBT / chaos / corpus / Go-race) | ✅ all four dimensions |

**69 tests green.** Authoritative start/stop/build commands live in the
project's `/deploy` skill, not here.

## The pipeline and the CLI surface

```
config files ──ingest──► [ServiceInstance] ──reconcile──► Deployment ──validate──► ValidatedDeployment
  (compose, registry,      loose / open          (facets,         (TIGHT: dangling edge        │
   start-commands)         per source×unit        aliased)         unrepresentable; BootOrder   │
                                                                   ⇒ acyclic)                    │
                                                                                                 ▼
                            running reality ──observe──► Status ──────────────plan──────► Plan ──apply──► the rig
                            (HTTP / TCP / exit code)    (total)                (Change set)        (os-exec / ssh)
```

```
bosun check   <compose> <registry>            # ingest → reconcile → validate → drift report
bosun plan    <compose> <registry> [snapshot] # + observe → plan (the change set)
bosun observe <compose> <registry>            # the observation edge, read-only
bosun apply   <compose> <registry> [snapshot] # live: execute the plan (os-exec / ssh)
bosun apply --dry-run <compose> <registry>    # print the staged commands, mutate nothing
bosun serve   [registry]                      # resident lazy-spawn router (the ex-SDI duty)
bosun serve --plan  [registry]                # non-resident: print the admission plan
bosun serve --audit [registry]                # probe every route, report up/down/ms
```

## Layout

Six packages in one spago workspace. **Gnomon (PureScript→Go) is the primary
runtime; node is the development shell** — you work in node, the binary that
ships is Go, and `conformance/` is the gate that holds the two to the same
behaviour.

| Package | Role |
|---|---|
| `core/` | pure: atoms, the typed IR, `reconcile` / `validate` / `plan` / `apply` (pure), `serve` admission, `Report`, `DeployError` |
| `adapters/` | pure ingest per source (compose, registry, start-command) |
| `cli/` | the `bosun` entrypoint + the **Effect edges** (`observe`, `apply`, the resident `serve` shim) + synchronous fs/yaml FFI |
| `test/` | scenario corpus as tests + the PBT generators / fault injectors |
| `conformance/` | I/O-free `Main`s the backend-go column transpiles + runs (the cross-backend gate) |
| `chair/` | **Bosun's Chair** — the Halogen front-end (see `chair/DESIGN.md`) |

**Where the Go FFI lives.** Beside the `.purs` it implements, basename with the
extension swapped — `cli/src/Bosun/CLI/Serve.purs`, `Serve.js`, `Serve.go` are
three peers, and the backend finds the third via CoreFn `modulePath`, exactly as
`purs` finds the second. There is no directory of Go shims and nothing copies
them by hand; a missing twin is visible in an `ls` and caught by
`scripts/control-parity.sh`. The convention is polyglot-template's
(`docs/specs/co-located-user-foreigns.md`, after Kevin Jameson,
*Multi-Platform Code Management*). FFI for *packages Bosun depends on* is not
Bosun's to write — it belongs in `backend-go/foreign/`.

`spike/` is *not* a workspace package — it's a standalone compile-proof (see
"The EDSL" below).

## Bosun's Chair

The front-end. Today it's the **runtime cockpit** for `bosun serve` (watch the
live route table + admission picture; reload / spawn / stop / audit). The
**north-star** is the full **Bosun workbench** — four views over the *same*
`bosun-core` model: the cockpit (built), **ingestion made visible** (the
loose→tight MISU ladder), an **EDSL editor**, and a **Hylograph deployment
graph**. Full vision in [`chair/DESIGN.md`](chair/DESIGN.md).

## The EDSL — designed, spiked, not yet wired

`DESIGN.md` D-12 claims the MISU guarantees can move *up* into a hand-written
`.deploy` authoring DSL using **row types as type-level sets**, so combinators
like `routeTo` / `requiresReady` / `bindsTo` only typecheck against compatible
endpoints — turning e.g. `UncheckableGate` from a validate-time error into a
**compile** error. [`spike/`](spike/) **confirms this** against `purs` 0.15.15
(phantom row-indexed `Service`, `Prim.Row.Cons`/`Lacks` as membership / set
semantics, four negative cases correctly rejected).

⚠️ **It is a spike, not production code.** `Source` carries a `FromOverlay` tag
but **no `.deploy` parser, printer, or fixtures exist** — `FromOverlay` is
referenced nowhere but its own definition. Promoting the spiked encoding into
a real adapter + the Chair's EDSL editor is the substance of the unbuilt
Pillar 2.

## Documentation — and its currency

Two design docs are evergreen and authoritative; the plan docs lag reality in
places. **This README is the authoritative current-status source** — where a
plan doc's status section disagrees with it, the README wins.

| Doc | Kind | Currency |
|---|---|---|
| [`docs/FOR-DEVOPS.md`](docs/FOR-DEVOPS.md) | user guide — start here if you run things, don't care about types | current |
| [`docs/PRINCIPLES.md`](docs/PRINCIPLES.md) | the governing discipline (uncertainty at the edges; the invariant-boundary ledger; the signal-box ladder) | **evergreen** |
| [`docs/DESIGN.md`](docs/DESIGN.md) | the type design, cross-tool panoply, two-tier "illegal states" story | **evergreen** (reference) |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | ADR-style resolutions (facet model D-E3, stop-propagation D-E5, config refs, restart) | living |
| [`docs/PRIOR-ART.md`](docs/PRIOR-ART.md) | type-design lessons (Propellor, Dhall, CUE, systemd, NixOS, Pulumi, Terraform, Build-à-la-Carte) | evergreen |
| [`docs/SCENARIOS.md`](docs/SCENARIOS.md) | 29 type-stress scenarios + the open-questions agenda | **partly superseded** — many open questions are now resolved in `DECISIONS.md` |
| [`docs/BUILD-PLAN.md`](docs/BUILD-PLAN.md) | the phased build roadmap | **status section STALE** — stops at Phase 6B-pending; Phases 5/6/7 + Chair all shipped since. Use this README for state. |
| [`docs/BOSUN-SERVE.md`](docs/BOSUN-SERVE.md) | the resident-router design (admission, proxy, **broker**, hot-reload, the SDI contract) | current |
| [`docs/ENSURE-AND-LOCATE.md`](docs/ENSURE-AND-LOCATE.md) | the `/where` reference — the operation, the wire contract, opting a service into `serveMode: broker` | current (**authoritative** for the contract) |
| [`docs/RELAY-STALL-AND-BROKER-MODE.md`](docs/RELAY-STALL-AND-BROKER-MODE.md) | incident + design note: a proxied WebSocket went deaf one way (**not diagnosed** — read §2 before re-investigating), and the broker mode that answers it | current |
| [`docs/STRESS-TEST-PLAN.md`](docs/STRESS-TEST-PLAN.md) | the four stress dimensions | current (all four done) |
| [`docs/PHASE-6C-GO.md`](docs/PHASE-6C-GO.md) | completed-phase note: the Go binary deploys a rig | **historical** (kept for provenance) |
| [`docs/PHASE-7-GO.md`](docs/PHASE-7-GO.md) | completed-phase note: `serve` on the Go column | **historical** |
| [`spike/README.md`](spike/README.md) | the D-12 rows-as-sets compile-proof | reference (spike, not wired) |

## Family

Bosun double-belongs. By *structure* it's a **ShapedSteer** proof-of-concept
(a deployment is a typed DAG — Marginalia #227, child of ShapedSteer #132;
embodies the vision, written fresh, no obligation to share code). By *intent*
it's a candidate for the **Humboldt / "Minard for X"** cartography family:
**Minard-for-containers** — a map of your deployment that surfaces structure,
drift, and dependency the way Minard maps a codebase. The reconciler and the
map are the same artifact seen two ways. `serve` is the absorbed duty of the
old node **SDI** lazy-spawn router (Marginalia #184).

## Built with

The PureScript→Go backend. PureScript owns the pure core + synchronous I/O;
Go owns concurrency (and only concurrency). The pure **Detect** tier is the
cross-backend conformance column — signal-box's "illegal states made
unrepresentable, measured not asserted" applied to a real, infinite domain.
