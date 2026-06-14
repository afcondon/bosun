# Bosun — Build Plan

A dependency-ordered roadmap, written to survive session boundaries: a fresh
session reads this + the design docs and knows exactly what to do next. Each
phase has a **goal**, the **pieces**, a **definition of done**, and what it
**unblocks**. Phases 0–6 are the MVP; 7+ is breadth.

## Ordering principles (why this sequence)

1. **Pure core first.** The Detect tier (`ingest → reconcile → validate`) is
   pure, total, signal-box-shaped, and the easiest thing to test. The effectful
   edges (`observe`, `apply`) come last, along the no-Aff seam.
2. **Vertical slice over breadth.** Get one source → report working
   end-to-end before adding more adapters. Prove the pipeline shape early on
   *real* data.
3. **Measured from day one.** The PBT harness (`SCENARIOS.md §G`) grows
   *alongside* `validate`, not after — the signal-box "measured, not asserted"
   ethos. Every phase ships with its properties.
4. **Dogfood the real polyglot rig.** The actual `docker-compose.yml` +
   registry + plists are both the test corpus and the demo. The first useful
   artifact is `bosun check` finding the *real* drift we catalogued in
   `DESIGN.md §7`.
5. **Develop on the JS backend; treat purescript-go as a conformance target.**
   The pure core is backend-agnostic. Build/test fast with the standard
   (node) backend; run the same core through **purescript-go** as a separate
   conformance column (Phase 4) — that *is* the backend-go showcase. Don't
   block early dev on backend quirks.

## Repo layout (decided in Phase 0)

Mirrors signal-box's `core` / `harness` split — the core is the
conformance-portable part:

```
core/      pure: atoms, types, validate, reconcile, plan, emit, DeployError
adapters/  pure ingest/emit per source (compose, registry, plist)
cli/       the `bosun` entrypoint + the Effect edges (observe, apply) + report
test/      scenario corpus as tests + PBT generators / injectors / shrinkers
```

---

## Phase 0 — Scaffold & harness  *(unblocks everything)*

**Goal:** a spago workspace that builds and runs a trivial `bosun` and a green
test suite.

- spago workspace + package set; the `core` / `adapters` / `cli` / `test`
  packages; `"type": "module"`, FFI conventions per `/purescript-tooling`.
- A test runner (e.g. `purescript-spec`) wired to `spago test`.
- A stub `bosun` CLI (prints version) building on the **node** backend.
- A one-line `purescript-go` build invocation stubbed for later (Phase 4).

**DoD:** `spago build`, `spago test` (one trivial passing test), and
`spago run` all green.

---

## Phase 1 — The vocabulary (atoms + the tight type)  *(unblocks 2)*

**Goal:** the type design from `DESIGN.md §3` as compiling code — no logic yet.

- Atoms with smart ctors: `Port`, `AbsPath`, `Host` (opaque!), `Domain`,
  `RoutePath`, `EnvVar`, `ProjectSlug`, `ServiceId`.
- The closed ADTs: `Executor` (+`ContainerSpec`), `Exposure`, the **edge
  product** (`Ordering` ⟂ `Requirement` + `Provenance`), `Gate`, `Probe`,
  `Health`, `RestartPolicy`, `Selector`, `Source` (incl. `FromOverlay`).
- The three shapes: `ServiceInstance` (loose, open `extra`), `Deployment`,
  `ValidatedDeployment` (+`ServiceRef`, `BootOrder`).
- `DeployError`.
- JSON codecs (codec *values*, not instances — house style) for the boundary.

**DoD:** the module compiles; smart ctors have unit tests (`mkPort 0 == Nothing`,
`mkAbsPath "node x" == Nothing` — the SDI footgun). First reality-check of the
type design as code.

---

## Phase 2 — `validate` (the v4 rung — the heart)  *(unblocks 3; measured)*

**Goal:** the pure tightening pass + the PBT harness.

- `validate :: Deployment -> V (Array DeployError) ValidatedDeployment`:
  referential integrity (mint `ServiceRef`s), acyclicity (topo-sort →
  `BootOrder`), selector closure, route backing, gate checkability.
- **Stand up the PBT harness here** (`SCENARIOS.md §G`): a generator for
  `ValidatedDeployment`; round-trip (`validate ∘ loosen = id`); the first fault
  injectors (`addBackEdge → DependencyCycle`, `dangleDep → DanglingDependency`,
  `collide → PortCollision`, `dropGatedProbe → UncheckableGate`).
- Encode must-fail scenarios B1–B9 as example tests too (the corpus seeds the
  generators' coverage). This is where `Show DeployError` gets added — *for the
  spec assertions only* (entry-73 use); confirm generic-`Show`-over-records
  compiles on this package set, or hand-write the few record-bearing instances.
  The user-facing renderer is Phase 3 and stays separate (`renderError`).

**DoD:** `validate` rejects every B-scenario with the *specific* error; the
round-trip and fault-injection properties pass. The design is now *measured*.

---

## Phase 3 — One adapter + `reconcile` → first real report  *(the first useful artifact)*

**Goal:** `bosun check` finds the real drift in `DESIGN.md §7`.

- `ingest` **compose** (YAML → `ServiceInstance`; `parseStartCommand →
  Executor`; open `extra` passthrough; `Absent | Present`, no default-fill).
- `ingest` the **service registry** (the second source — needed for drift).
- `reconcile` (the facet model, `DECISIONS.md D-E3`: lattice meet, facet
  partition, facet-divergence vs conflict).
- A report renderer (the `bosun check` output in `FOR-DEVOPS.md`).
  **`renderError :: DeployError -> String`, never `show`** (Elements of
  PureScript Style, entry 73: `Show` is for the REPL and test-failure
  messages; user-facing text gets a `display` function with an explicit,
  documented format, and any data crossing a boundary gets a codec). Derived
  `Show` on the error/IR types — when present — exists only for spec
  assertions; it must not leak into the report or the JSON boundary.

**DoD:** pointed at the real polyglot `docker-compose.yml` + registry, `bosun
check` reports the actual cases from §7 (tilted-radio facet divergence; the SDI
`node router.mjs` no-`cd` violation; route-without-backing; the under-specified
DAG). **This is the demo that proves the thing.**

---

## Phase 4 — Detect tier complete + the purescript-go conformance column

**Goal:** Bosun becomes the backend-go MVP showcase.

- `ingest` **launchd plists** (third adapter).
- Wire the CLI: `bosun check` proper.
- **Run the pure core through purescript-go**, diff against the node-backend
  report → identical (the signal-box conformance pattern). This is the
  byte-identical-across-backends claim, realised, and the MVP gate for
  backend-go.

**DoD:** `bosun check` covers compose + registry + plists; the purescript-go
column matches the node column exactly (or only on the seeded INT64/ASTRAL
ledger). **Detect tier shippable.**

---

## Phase 5 — `plan` + the observation edge

**Goal:** diff intent against reality.

- `plan :: ValidatedDeployment -> WorldState -> Plan` (pure given `WorldState`);
  the verifying-traces rebuilder; three-way state; `Stop`-propagation closure
  (`DECISIONS.md D-E5`).
- `observe :: Probe -> Effect Status` (the observation edge — first Effect, but
  synchronous and simple; `Unknown Reason` first-class).
- PBT: convergence (`plan ∘ apply ∘ plan = no-op`); `Status` parsing total.

**DoD:** `bosun plan` shows what would change against the running rig.

---

## Phase 6 — `apply` + `emit` (launch tier MVP + the real deploy test)

**Goal:** stand up the polyglot showcases *for real*; close the round-trip.

- `apply` sequential via os-exec (no concurrency yet); reads `BindsTo`/`PartOf`
  for `Stop`.
- `emit` compose; the differential test (emit byte-identical to the
  hand-written file) — a *separate* validation/migration capability.
- **THE HEADLINE FUNCTIONAL TEST (user, 2026-06-14): can the Go program
  actually deploy the polyglot stack to the MacMini?** Take a `Plan`, run its
  `BootOrder` stages via os-exec against the real target — `ssh
  andrew@andrews-mac-mini` + `docker compose --profile <p> up -d` for the
  container facets — and verify the showcases come up. This is `apply` proving
  it *does the devops*, not just describes it. Needs an os-exec foreign on BOTH
  columns; the **Go column is where this belongs** (the concurrency tier).
- The atomic demo (`DESIGN.md §6/§7`): overlay → validate → render → `plan` →
  `apply` boots the showcases in `BootOrder` → emit byte-identical compose.

**DoD:** `bosun apply` brings the polyglot showcases up on the MacMini in
`BootOrder`, without rewriting any source config; `bosun emit compose`
round-trips byte-identical. **MVP complete — gates backend-go's MVP.**

---

## Phase 7+ — Breadth / post-MVP

In rough priority: the typed-EDSL overlay surface (build-time MISU) ·
runtime data-overlay reader (pure binary can reconcile, not just detect) ·
`apply` concurrency (Go errgroup) + SDI-style lazy-spawn router (hits the
`_lazy`/`_force` thunk thread-safety roadblock) · systemd / k8s / Procfile /
Terraform-state adapters · `Rollout` strategies · continuous reconcile loop ·
the Hylograph DAG view as a first-class artifact (the Minard-for-containers
angle) · the E10 EdgeKind×tool fidelity matrix.

### Parser-hardening track (user, 2026-06-14 — independent, can run anytime)

**Stress-test the heck out of both adapters.** The Phase-3 adapters are
minimal-viable; harden them against the real corpus:
- Run `ingestCompose`/`ingestRegistry` over the FULL inputs — the entire
  ~44-row registry (`/api/ports`) and the whole `docker-compose.yml` — and
  every A–D scenario in `SCENARIOS.md`, asserting no crash and sane decode.
- Compose edge cases: map-form `depends_on` (with `condition:`), `image:` form,
  multi-port, `env_file`, YAML anchors/aliases, the routes-in-a-comment header,
  the commented-out `anscombe` stale service (§7.3).
- Registry edge cases: NULL/prose `startCommand` (→ `Unmanaged`), `ssh …`
  rows (→ `Remote`, currently `Unmanaged`), `udp://` / `ws://` urls, workers
  with null port, the SDI `node router.mjs` row (→ `SdiContractViolation`).
- Turn these into a test *population* (extend AdapterSpec + a fixtures dir).
  Goal: the parsers never crash and degrade gracefully (`Unmanaged`/skip +
  surfaced note), never silently mis-decode.

### Benchmarking track (user, 2026-06-14 — "fairly distant later session")

Node vs purescript-go on the **apply / sysadmin-devops** path, à la
backend-go's own `run_bench.sh`. Same PureScript source, two columns; compare
wall-clock on the os-exec-heavy `apply` (and the pure pipeline). Extends the
Phase-4 conformance harness from *correctness* (byte-identical) to
*performance*. Belongs after Phase 6 (there must be an `apply` to benchmark).

---

## Critical path & "start here"

```
0 ─→ 1 ─→ 2 ─→ 3 ─→ 4 ─→ 5 ─→ 6
              (PBT harness rides 2→6)
```

### Status — Phases 0–5 + 6A DONE (as of 2026-06-14)

Since the Phase-4 win, in this session:
- **Phase 5A — `plan` (pure):** `Bosun.Plan` — `Status`/`Reason`/`Snapshot`/
  `WorldState`, `Change`, `Plan`, `plan :: ValidatedDeployment -> WorldState ->
  Plan`. Total by construction (validate already proved acyclic + resolved).
  Base status→change pass + **D-E5 backward Stop/Restart propagation** along
  reverse `BindsTo`/`PartOf` as a severity-monotone fixpoint; stops staged
  before starts (reverse boot order). `renderPlan` in `Bosun.Report`. PlanSpec
  (base mapping, both propagation rules, staging, + 2 convergence properties
  reusing `genLegal`) → **46 tests green**. The plan path rides the **go-
  conformance gate too** (planReport in `Bosun.Conformance.Main`, byte-identical
  node vs backend-go, 27 Go files).
- **Phase 5B — `bosun plan` CLI:** `bosun plan <compose> <registry>
  [snapshot.json]`; reads an observed Snapshot (JSON object {id: status},
  absent ⇒ down). Refuses to plan a deployment that doesn't validate (prints the
  check report). `fixtures/valid/` seeds the corpus. Live rig correctly REFUSED
  (real `macmini:80` edge port-collision).
- **Phase 6A — the observation edge (`bosun observe`), READ-ONLY:**
  `Bosun.CLI.Observe` — `observe :: Maybe Host -> Probe -> Effect Status` via
  synchronous `execSync` (curl/nc), no-Aff seam intact. `effectiveProbe`: a
  portful service with no declared probe is observed by a TCP connect to its
  port (implicit liveness). Prints a Snapshot JSON that pipes straight into
  `bosun plan` — the **observe → plan loop is closed**. Verified live: 22
  running / 7 down / 24 unknown over the 53-service rig.

**Remaining for MVP: Phase 6B — `apply` (the mutating edge) + the headline
MacMini deploy.** Two open decisions block it (see below).

### Phase 6B — `apply`: the two open decisions (for the next session)

1. **Executor threading.** The validated `Service` carries only structural
   fields (id/host/exposure/readiness/deps/routes/selectors) — NOT the
   `Executor`, nor compose-coordinates (compose service name, file, profile).
   `apply` needs them to emit launch commands. Options: (a) thread `Executor`
   (+ a small `LaunchSpec`) through `LooseService`→`Service` properly (a type
   evolution across reconcile/validate); (b) pass a side `Map ServiceId
   Executor` from the CLI. (a) is the principled end state; (b) unblocks faster.
2. **Live fire.** `apply` mutates the running rig (`ssh andrew@andrews-mac-mini`
   + `docker compose --profile X up -d`). Recommended sequence: build `apply`
   as **pure command-generation** (`Plan → Array StagedCommand`, conformance-
   gated — "the Go binary emits the identical docker/ssh script") + a
   `--dry-run` that PRINTS the commands, THEN wire `os-exec` to actually fire,
   and only run live against the MacMini with the user present.

### Status — Phases 0–4 DONE (as of 2026-06-14)

`0 ─→ 1 ─→ 2 ─→ 3 ─→ 4` all green and committed:
- **0–2:** workspace; the §3 vocabulary in `bosun-core`; `validate` (B1–B6
  caught, Kahn-levels `BootOrder`, tight ctors hidden in
  `Bosun.Service.Internal`); the PBT harness.
- **3:** the real adapters (`Bosun.Adapters.{StartCommand,Registry,Compose}`,
  pure `Json -> ServiceInstance`; CLI sync fs+js-yaml FFI) + `reconcile` (facet
  model, auto-alias by dir basename) + `Bosun.Report`. `bosun check <compose>
  <registry>` runs on the LIVE rig: 15 services flagged two-facet divergence
  (incl. §7 tilted-radio) + a port-collision. 37 tests green.
- **4:** `scripts/go-conformance.sh` — the pure Detect pipeline transpiles via
  backend-go to ~25 Go files and runs **byte-identical to node**. The
  backend-go MVP gate, green. Harness: `conformance/Bosun.Conformance.Main`.

**Detect tier is shippable and gated across both backends.**

### Next-session agenda (set by user, 2026-06-14, after the Phase-4 win)

1. **The real deploy test (Phase 5 → 6):** can the Go program actually deploy
   the polyglot stack to the MacMini? → `plan` (Phase 5, pure) then `apply`
   (Phase 6) via os-exec / ssh + `docker compose up`, run through the Go
   column. *This is the priority — "does it do the devops."*
2. **Parser hardening** (the track above): stress-test both adapters against
   the full registry + compose + the A–D scenarios. Independent; can interleave.
3. **Benchmarking** (the track above): node vs Go on the apply path — *"a
   fairly distant later session."*

Reference while building: `DESIGN.md` (types), `DECISIONS.md` (the resolved
edge cases — D-E5 for `Stop`-propagation in `plan`), `PRINCIPLES.md` (the
two edges — Phase 5 stands up the *observation* edge), `SCENARIOS.md §G` (PBT),
`spike/` (the EDSL overlay, Phase 7).
