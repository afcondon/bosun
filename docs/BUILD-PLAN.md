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
  generators' coverage).

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

## Phase 6 — `apply` + `emit` (launch tier MVP + atomic demo)

**Goal:** stand up the polyglot showcases; close the round-trip.

- `apply` sequential via os-exec (no concurrency yet); reads `BindsTo`/`PartOf`
  for `Stop`.
- `emit` compose; the differential test (emit byte-identical to the
  hand-written file) — a *separate* validation/migration capability.
- The atomic demo (`DESIGN.md §6/§7`): author overlay → validate → render DAG +
  status grid → `plan` → `apply` boots the showcases in `BootOrder` → emit
  byte-identical compose.

**DoD:** `bosun apply` brings up the polyglot showcases in order, without
rewriting any source config; `bosun emit compose` round-trips byte-identical.
**MVP complete — gates backend-go's MVP.**

---

## Phase 7+ — Breadth / post-MVP

In rough priority: the typed-EDSL overlay surface (build-time MISU) ·
runtime data-overlay reader (pure binary can reconcile, not just detect) ·
`apply` concurrency (Go errgroup) + SDI-style lazy-spawn router (hits the
`_lazy`/`_force` thunk thread-safety roadblock) · systemd / k8s / Procfile /
Terraform-state adapters · `Rollout` strategies · continuous reconcile loop ·
the Hylograph DAG view as a first-class artifact (the Minard-for-containers
angle) · the E10 EdgeKind×tool fidelity matrix.

---

## Critical path & "start here"

```
0 ─→ 1 ─→ 2 ─→ 3 ─→ 4 ─→ 5 ─→ 6
              (PBT harness rides 2→6)
```

The single highest-value early milestone is **Phase 3** — `bosun check` on the
real rig — because it turns the whole paper design into a thing that finds
real bugs. Everything before it (0–2) is the runway to get there.

**Immediate next actions (a fresh session can just go):**
1. Phase 0: `spago init` the workspace, the four packages, the test runner,
   the stub CLI on the node backend.
2. Phase 1: transcribe `DESIGN.md §3` into `core` types; unit-test the smart
   ctors.
3. Phase 2: `validate` + the first fault injectors.

Reference while building: `DESIGN.md` (types), `DECISIONS.md` (the resolved
edge cases), `PRINCIPLES.md` (the invariant-boundary ledger — *which* phase
establishes *which* invariant), `SCENARIOS.md §G` (the PBT shape), `spike/`
(the EDSL encoding, for Phase 7's overlay surface).
