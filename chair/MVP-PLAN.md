# Bosun's Chair — MVP plan (Pillar 1: ingestion made visible)

The first real slice of the workbench vision (`DESIGN.md`). Goal: **fire up the
Chair, point it at existing configs, and watch them climb the loose→tight MISU
ladder — ending in either a MISU-typed consistent spec or a clear error with
suggested resolution steps.** Pillar 1 only; Pillars 2 (EDSL editor) and 3
(Hylograph graph) are later milestones.

## Decisions locked (2026-06-15)

| # | Decision | Choice |
|---|---|---|
| 1 | Where the pipeline runs | **Chair backend** (`chair-server`, HTTPurple) — a sibling of the CLI, another Effect-edge host of the pure `bosun-core`. *Not* browser-core. |
| 2 | The MVP loop | point at configs → select → **MISU spec OR clear error + remediation**. (`bosun check` with a UI and good error rendering.) |
| 3 | Cross-source aliasing | **editable**, session-local. Auto-derive the default aliases, let the user merge/split, recompute live. **Persistence deferred.** |
| 4 | The deploy editor | **structured/forms first** (no parser). Textual `.deploy` DSL is its own milestone. |
| 5 | Adapter coverage | **compose + registry only** for MVP. plist/systemd/k8s are typed-for but adapter-unbuilt; deliberate additions later. |
| — | MISU | the *principle* (Make Illegal States Unrepresentable). Pillar 1 = **signal-box's ladder made visible** on a real deployment. |

## The shape

The Chair frontend now talks to **two** backends, and they must not be
confused:

```
  Bosun's Chair (Halogen, :3020)
  ├─ runtime cockpit (pillar 0, built) ──► bosun serve (:3997)   resident router, process authority
  └─ ingestion ladder (pillar 1, this) ──► chair-server (NEW)    pure analysis, read-only
```

`chair-server` reuses `bosun-core` + `bosun-adapters` verbatim. It reads config
files at its edge, runs the pure pipeline, and serves the laddered result as
JSON. The no-Aff seam holds: the core stays pure/total; only file-read +
HTTP sit in `Aff`.

## The ladder, as the wire contract

One stateless endpoint drives the whole view:

```
POST /analyze
  body: { sources : [ { kind: "compose"|"registry", path|text, label } ]
        , aliases : [ AliasOverride ]            -- user merge/split, on top of auto
        }
  resp: { instances  : [ServiceInstanceView]     -- RUNG 1  loose/open, per source×unit
        , reconcile  : { groups, divergences, conflicts, aliasesUsed }  -- RUNG 2
        , result     : Validated ValidatedDeploymentView
                     | Invalid  [ { error: DeployErrorView, remediation: [String] } ]  -- RUNG 3
        }
```

The frontend renders all three rungs from one response and **re-POSTs whenever
the alias overrides change** — that's the live recompute. Stateless; no
session.

## Workstreams

### A — the IR JSON contract (codecs) · `core/`
The biggest discrete chunk and the highest-value (it's the shared frontend↔backend
contract; both ends are PureScript and import the *same codec values*, so no
drift). Per house style: **codec values, not type-class instances**; ADTs
tagged. Cover the rungs we expose:
- `ServiceInstance` (incl. `Source`, `Executor`, `Exposure`, `Health`, the
  `extra` passthrough as opaque JSON).
- the reconcile result: `LooseService`/`Deployment`, `Divergence`, the
  `CrossSourceDrift` conflicts, the `AliasMap` actually used.
- `ValidatedDeployment` (the boot-order stages, routes, selectors).
- `DeployError` (all variants) — paired with remediation (workstream D).
- Round-trip tests for each codec.
- *Provenance granularity:* instance-level (`source` per instance) +
  conflict-level (`CrossSourceDrift.claims`). Per-field provenance is **not**
  in the model; MVP does not add it. (Noted as a known limit.)

### A0 — extract the auto-alias heuristic to a pure shared function · `adapters/` or `core/`
Today the dir-basename auto-alias logic lives in `cli/.../Main.purs`
(`aliasFor`/`dirKey`/`canonId`/`registryKey`, ~ll.265–284). Lift it into a pure
function so **both** the CLI and `chair-server` derive the same default
`AliasMap`. Small refactor; keep the CLI green. The user's overrides are then
merged on top of this default.

### B — `chair-server` (HTTPurple) · NEW package
- New workspace package depending on `bosun-core` + `bosun-adapters`.
- `POST /analyze` (above): read each source at the edge (reuse the CLI's sync
  fs/yaml FFI; sync read inside an `Aff` handler is fine at the edge), run
  `ingest → reconcile(aliases) → validate`, encode the laddered result.
- Registry: a URL or a file path (the CLI already treats it polymorphically).
- CORS for the :3020 frontend (mirror what `serve`'s status server does).
- Register a dev port via `/marginalia` before first run (suggest next free);
  pick one near the Chair (e.g. 3019/3021). *Register when we build it, not now.*

### C — the Pillar-1 frontend (the ladder view) · `chair/`
- **Source picker:** add a compose path and a registry (path/URL); a fixtures
  quick-pick is a nicety (the `fixtures/` set). Mirrors `bosun check <a> <b>`.
- **Rung 1 — instances:** list, grouped/coloured by `Source`; show provenance.
- **Rung 2 — reconcile:** facet groups per `ServiceId`; **divergence**
  (informational — "two ways to deploy this") visually distinct from
  **conflict** (error). Show the alias map *and why each pair grouped*
  ("aliased by dir `tidal/`").
- **Rung 3 — validate:** on success, the MISU `ValidatedDeployment` (boot-order
  stages, backed routes); on failure, the `DeployError` ledger **with
  remediation hints**.
- **The ladder framing:** label each rung with the illegal-state family it
  extinguishes (the signal-box tie) — even statically in MVP, it tells the
  story Pillar 1 exists to tell.
- Swiss/light styling, reusing the existing Chair CSS.

### C2 — editable aliases
- Frontend holds `Array AliasOverride` (`Merge [ServiceId]` / `Split alias`),
  session-local.
- Affordances on Rung 2: "these look like the same service — **alias them**"
  (the natural remediation for under-grouping) and "**split**" (for an
  over-eager auto-merge that manufactured a false conflict).
- Each change re-POSTs `/analyze`; facets/divergences/conflicts recompute live.
- **Persistence deferred** — overrides die with the session. (Later: write a
  `.bosun-aliases` overlay.)

### D — remediation hints · `core/`
- Pure `remediation :: DeployError -> Array String` (or richer structured
  hints). Net-new capability — today `DeployError` says *what* broke, not *how
  to fix it*. Tested per variant.
- The under-grouping/alias case ties to C2 (a hint that maps to a button).

## Sequencing

```
A0 (extract auto-alias)  ─┐
A  (IR codecs)            ─┼─► B (chair-server /analyze) ─► C (ladder view, read-only)
D  (remediation)         ─┘                                      └─► C2 (editable aliases)
```

A0 + A + D are pure and independently testable (land first, keep everything
green). B needs A. C needs B. C2 is the last step and the one that turns the
Chair from "pretty `bosun check`" into a tool you *resolve* identity ambiguity
in.

## Risks / things to watch

- **Codec surface (A) is the real work** — `Map` / `NonEmptyArray` / nested
  ADTs. Bounded and reusable, but don't underestimate it.
- **HTTPurple is a new heavy dep** for the workspace (Calypso uses it; precedent
  exists). Confirm it resolves in registry 77.5.0.
- **Two-backend frontend** — keep `serve` (:3997, cockpit) and `chair-server`
  (analysis) clearly separated in the UI and the code; never let analysis reach
  into `serve`'s process authority.
- **Provenance is instance-level only** — set expectations; per-field is a
  later model enrichment, not MVP.

## Explicitly out of scope for this MVP

Pillar 2 (EDSL editor), Pillar 3 (Hylograph graph), plist/systemd/k8s adapters,
alias persistence, per-field provenance, anything that mutates the rig (that's
`serve`/`apply`, already built and separate).
