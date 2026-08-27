# Bosun

A typed **deployment-configuration reconciler**. (A bosun keeps a ship's whole
rig in working order.)

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

Public and MIT-licensed: `github.com/afcondon/bosun`.

## Status — built and running (2026-08-27)

Built through **Phase 7** (the resident router), plus the **resident
supervisor**, **Bosun's Chair**, and — since 2026-08-26 — a group lifecycle
that is **an artifact the daemon obeys rather than code it contains**. The
pure **Detect** tier (`ingest → reconcile → validate → plan`) runs
**byte-identical on node and on the Go binary**, and a Go-compiled binary has
deployed a running rig.

| Capability | State |
|---|---|
| Ingest adapters (compose, registry, start-command) | ✅ pure `Json → ServiceInstance` |
| `reconcile` — facet model, cross-source aliasing | ✅ divergence vs. conflict (D-E3) |
| `validate` — the tight `ValidatedDeployment` | ✅ B1–B6 + Kahn `BootOrder` |
| `plan` — pure planner (D-E5 stop-propagation) | ✅ |
| `observe` — the observation edge (read-only) | ✅ sync probes → total `Status` |
| `apply` — pure command-gen + live os-exec | ✅ `--dry-run` + live; deploys a rig |
| `serve` — resident lazy-spawn router (ex-SDI) | ✅ admission / proxy / broker / hot-reload |
| `supervise` — keep-alive daemon, one per group | ✅ launch memory, boot grace, backoff, teardown verdicts |
| The group lifecycle as a Glassbox artifact | ✅ `machines/supervise-group.json` |
| Go conformance (Detect tier, byte-identical) | ✅ `scripts/go-conformance.sh` |
| Go supervise conformance (transition, byte-identical) | ✅ `scripts/go-supervise-conf.sh` |
| Go apply (native binary deploys) | ✅ `scripts/go-apply.sh` |
| The Menagerie (behavioural gate, both columns) | ✅ `scripts/menagerie-conf.sh` |
| Bosun's Chair (Halogen front-end) | ✅ watch + control |
| Stress suite (PBT / chaos / corpus / Go-race) | ✅ all four dimensions |

**228 tests green**, plus 16 shell gates under `scripts/`. Authoritative
start/stop/build commands live in the project's `/deploy` skill, not here.

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
bosun supervise <compose> <registry>          # resident keep-alive daemon for one group
```

Global flags, accepted anywhere: `--targets <file>` layers host overrides on
the built-in defaults; `--port <n>` gives a supervisor its own status port, so
one group is one daemon on one port; `--held` boots a group **resident but not
launched**, to be raised deliberately from the Chair.

## The group lifecycle is an artifact

`bosun supervise` does not decide its own transitions. They live in
[`machines/supervise-group.json`](machines/supervise-group.json) — a
[Glassbox](../../purescript-hylograph-libs/purescript-glassbox) state machine
loaded at runtime: seven states, eight events, fifty-six rules, nine commands,
four refusals, one config flag and one fact. `Bosun.CLI.Supervise.Machine` is
the seam, and the artifact's vocabulary is checked against the daemon's at
**compile time** — a state the daemon fails to handle is a missing-label type
error that names it, and an artifact naming a command the daemon does not
implement stops the daemon at boot rather than doing nothing at 3am.

Two things this bought immediately, both worth stating because they are the
argument for the approach:

- **A cell nobody had written down.** `restart` and `reload` were never gated
  on the group being up, so `POST /control/restart` on a `--held` group
  launched the service and quietly defeated the hold. Nothing had ever
  *decided* wrongly; the case simply had no answer, which is what totality is
  for.
- **A latent bug in the substrate.** Making `reconcile` the entry command of
  `raised` meant something observed a rig in the same instant it was launched,
  for the first time — and `Supervisor.decide` read every not-yet-spawned
  service as crashed. The machine did not introduce that; it asked a question
  the old shape never asked.

`machines/rendered/` carries the same artifact as a transition table, a block
form, and a Mermaid diagram, regenerated by `scripts/machine-vocabulary.sh`.

## Layout

Eight packages in one spago workspace. **Gnomon (PureScript→Go) is the primary
runtime; node is the development shell** — you work in node, the binary that
ships is Go, and `conformance/` is the gate that holds the two to the same
behaviour.

| Package | Role |
|---|---|
| `core/` | pure: atoms, the typed IR, `reconcile` / `validate` / `plan` / `apply` (pure), `serve` admission, the supervisor's `refine` / `decide`, `Report`, `DeployError` |
| `adapters/` | pure ingest per source (compose, registry, start-command) |
| `protocol/` | the wire types the CLI and the Chair both speak |
| `cli/` | the `bosun` entrypoint + the **Effect edges** (`observe`, `apply`, the resident `serve` and `supervise` shims) + synchronous fs/yaml FFI |
| `test/` | scenario corpus as tests + the PBT generators / fault injectors |
| `conformance/` | I/O-free `Main`s the Go column transpiles + runs (the cross-backend gate) |
| `chair/` | **Bosun's Chair** — the Halogen front-end (see `chair/DESIGN.md`) |
| `chair-server/` | the Chair's analysis backend and the fleet registry's owner |

Beside them: `machines/` (the lifecycle artifact + its renderings), `scripts/`
(16 gates), `fixtures/` (including the **Menagerie**, three specimen services
that misbehave on purpose), `registry/` (`fleet.json`), and `spike/`, which is
*not* a workspace package but a standalone compile-proof — see "The EDSL".

**Where the Go FFI lives.** Beside the `.purs` it implements, basename with the
extension swapped — `cli/src/Bosun/CLI/Serve.purs`, `Serve.js`, `Serve.go` are
three peers, and the backend finds the third via CoreFn `modulePath`, exactly as
`purs` finds the second. There is no directory of Go shims and nothing copies
them by hand; a missing twin is visible in an `ls` and caught by
`scripts/control-parity.sh`. The convention is polyglot-template's
(`docs/specs/co-located-user-foreigns.md`, after Kevin Jameson,
*Multi-Platform Code Management*). FFI for *packages Bosun depends on* is not
Bosun's to write — it belongs in `backend-go/foreign/`.

## Federation

One Bosun per machine; identity is `(host, port)`; no cross-machine reads. The
MBP and the Mac Mini each run their own `supervise → serve → Chair` stack under
their own launchd plist, each `chair-server` owns its slice of `fleet.json`, and
a failure is contained to the host that owns it. See
[`docs/FEDERATION.md`](docs/FEDERATION.md).

## Bosun's Chair

The front-end, and a deliberately **thin client**: it reads `/state` and posts
to `/control`, and holds no opinion of its own about a group's lifecycle. The
artifact decides, the daemon obeys, the Chair shows. Today it is the runtime
cockpit for `serve` and `supervise` (the live route table, the admission
picture, reload / spawn / stop / audit, teardown verdicts). The north star is
the full **workbench** — four views over the *same* `bosun-core` model: the
cockpit (built), **ingestion made visible** (the loose→tight ladder), an
**EDSL editor**, and a **Hylograph deployment graph**. Full vision in
[`chair/DESIGN.md`](chair/DESIGN.md).

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

`docs/` holds forty-odd files and they are not of equal standing. Two design
docs are evergreen and authoritative; the plan docs lag reality in places.
**This README is the authoritative current-status source** — where a plan
doc's status section disagrees with it, the README wins.

| Doc | Kind | Currency |
|---|---|---|
| [`docs/FOR-DEVOPS.md`](docs/FOR-DEVOPS.md) | user guide — start here if you run things and don't care about types | current |
| [`docs/PRINCIPLES.md`](docs/PRINCIPLES.md) | the governing discipline (uncertainty at the edges; the invariant-boundary ledger; the signal-box ladder) | **evergreen** |
| [`docs/DESIGN.md`](docs/DESIGN.md) | the type design, cross-tool panoply, two-tier "illegal states" story | **evergreen** (reference) |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | ADR-style resolutions (facet model D-E3, stop-propagation D-E5, config refs, restart) | living |
| [`docs/PRIOR-ART.md`](docs/PRIOR-ART.md) | type-design lessons (Propellor, Dhall, CUE, systemd, NixOS, Pulumi, Terraform, Build-à-la-Carte) | evergreen |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | where this is going, in stages | current |
| [`docs/FEDERATION.md`](docs/FEDERATION.md) | one Bosun per machine; `(host, port)` identity | current |
| [`docs/BOSUN-SERVE.md`](docs/BOSUN-SERVE.md) | the resident-router design (admission, proxy, **broker**, hot-reload, the SDI contract) | current |
| [`docs/ENSURE-AND-LOCATE.md`](docs/ENSURE-AND-LOCATE.md) | the `/where` reference — the operation, the wire contract, `serveMode: broker` | current (**authoritative** for the contract) |
| [`docs/MENAGERIE.md`](docs/MENAGERIE.md) | the three misbehaving specimens and what supervision is held to | current |
| [`docs/MARGINALIA-SEAM.md`](docs/MARGINALIA-SEAM.md) | why the port/server registry moved out of Marginalia and into `chair-server` | current |
| [`docs/REGISTER-A-SERVICE.md`](docs/REGISTER-A-SERVICE.md) | the procedure — read this before adding a row by hand | current (**authoritative**) |
| [`machines/README.md`](machines/README.md) | the lifecycle artifact: what it says, how to change it, how to regenerate the renderings | current |
| [`docs/RELAY-STALL-AND-BROKER-MODE.md`](docs/RELAY-STALL-AND-BROKER-MODE.md) | incident + design note: a proxied WebSocket went deaf one way (**not diagnosed** — read §2 before re-investigating) | current |
| [`docs/STRESS-TEST-PLAN.md`](docs/STRESS-TEST-PLAN.md) | the four stress dimensions | current (all four done) |
| [`docs/SCENARIOS.md`](docs/SCENARIOS.md) | 29 type-stress scenarios + the open-questions agenda | **partly superseded** — many open questions now resolved in `DECISIONS.md` |
| [`docs/BUILD-PLAN.md`](docs/BUILD-PLAN.md) | the phased build roadmap | **status section STALE** — stops at Phase 6B-pending. Use this README for state. |
| [`docs/PHASE-6C-GO.md`](docs/PHASE-6C-GO.md), [`docs/PHASE-7-GO.md`](docs/PHASE-7-GO.md) | completed-phase notes | **historical** (kept for provenance) |
| [`spike/README.md`](spike/README.md) | the D-12 rows-as-sets compile-proof | reference (spike, not wired) |

## Family

Bosun double-belongs. By *structure* it's a **ShapedSteer** proof-of-concept
(a deployment is a typed DAG — Marginalia #227, child of ShapedSteer #132;
embodies the vision, written fresh, no obligation to share code). By *intent*
it's a candidate for the **Humboldt / "Minard for X"** cartography family:
**Minard-for-containers** — a map of your deployment that surfaces structure,
drift, and dependency the way Minard maps a codebase. The reconciler and the
map are the same artifact seen two ways. `serve` is the absorbed duty of the
old node **SDI** lazy-spawn router (Marginalia #184), and `supervise` is the
absorbed duty of DeepStar's supervisor role over the Atlantis rig.
**Quartermaster** (#238) path-imports it; **Bosun's Chair** is #236.

## Built with

The PureScript→Go backend (**Gnomon**). PureScript owns the pure core and
synchronous I/O; Go owns concurrency, and only concurrency. The pure **Detect**
tier and the supervisor transition are the cross-backend conformance columns —
signal-box's "illegal states made unrepresentable, **measured not asserted**"
applied to a real, infinite domain.
