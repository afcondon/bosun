# Bosun — Prior Art

A type-design-oriented survey of existing work. The point is not the
feature lists; it's the **type-design lessons** and the **decisions they
force on Bosun**. Each entry: what it is → the lesson → links. Resolved
design deltas are folded into `DESIGN.md`; this file is the citable
reference behind them.

PureScript finding up front: **the deployment/infra/config-DAG space is
essentially empty in PureScript.** No NixOps/Pulumi/Dhall-k8s analogue, no
maintained k8s/docker client. Bosun is greenfield there — we write our own
codec-value decoders (house style) against JSON/YAML. The one reusable
PureScript lesson is Spago's `graph --topo`: the topo-sort should *consume
an already-proven-acyclic type* so the sort itself is total.

---

## Shortlist — study firsthand, in order

1. **systemd dependency taxonomy** — *do first; it directly fixes `EdgeKind`.*
2. **Propellor** — closest *typed* prior art (GADT MetaTypes; check-then-ensure).
3. **CUE** — the principled model for reconcile + drift (unification + bottom).
4. **Build Systems à la Carte (+ Shake)** — *is* our plan/apply; applicative-vs-monadic.
5. **NixOS module system** — the merge-strategy taxonomy (+ its ergonomic failures).

Reference-tier (borrow one idea each): **Pulumi** (two-graph separation;
infer edges from dataflow), **Terraform** (three-way state; typed change-set),
**Dhall** (explicit shallow merge; the absent-vs-empty cautionary tale),
**kustomize** (merge lists by identity key, never by position).

---

## The decisions this survey forces (the deltas)

These are the changes to the `DESIGN.md` v1 types. Each is justified below.

| # | Change | From | Driving prior art |
|---|---|---|---|
| D-1 | **Edge is a *product*, not a sum**: ordering ⟂ requirement | `EdgeKind` flat sum | systemd |
| D-2 | **Requirement is a gradient**: Wants / Requires(gate) / Requisite / BindsTo / PartOf | single `Requires`+`BoundTo` | systemd |
| D-3 | **Reconcile = lattice meet with explicit `Conflict`** (report, don't resolve) | ad-hoc merge | CUE |
| D-4 | **Open-ingest / closed-validate** resolves E9 (round-trip fidelity) | unresolved | CUE open/close + NixOS freeform |
| D-5 | **Two separate graphs**: dependency vs containment; never topo-sort containment | selectors as "2nd edge type" (vague) | Pulumi |
| D-6 | **Edge provenance**: `Inferred DataRef` vs `Declared` | all edges hand-declared | Pulumi |
| D-7 | **Three-way state**: desired / recorded / observed; drift = observed ≠ recorded | two-way WorldState | Terraform |
| D-8 | **Rebuilder = verifying-traces** (hash in+out → external-drift-aware) | unspecified | Build à la Carte |
| D-9 | **Core graph stays applicative** (statically acyclic = a real theorem); runtime-discovered edges quarantined | implicit | Build à la Carte |
| D-10 | **`Absent \| Present a`, never silent default-fill** in decoders | implicit | Dhall (omitNull) |
| D-11 | **List-of-record merge keyed by identity**, not concat/position | unspecified | kustomize |
| D-12 | Two-path MISU: ingestion via smart-ctors/phantoms (runtime); **authoring EDSL via type-level rows-as-sets (compile-time), which *fixes* Propellor's list-not-set wart** | "type-level" hand-wave | Propellor (adapted + improved) |

---

## Haskell

### Propellor — *closest typed prior art*
Haskell config-management; the *property* is the unit of config, and a host
is a list of `Property` values that each **check** then **ensure**
(idempotent — Terraform-like). Properties carry a **type-level MetaTypes
list** (`HasInfo`, target-OS witnesses); a type family
`EnsurePropertyAllowed` makes lossy/unsatisfiable compositions a **compile
error** (e.g. you can't `ensureProperty`-wrap a property whose aggregated
Info would be silently dropped; you can't run a Debian-only property on an
Arch host).
- **Lesson:** make executor/edge *incompatibilities* type errors, not
  validate-phase checks — the template for Tier-1 MISU. **D-12: PureScript
  has no GADTs, but the workarounds are easy and one *improves* on Propellor.**
  Two paths converge on `ValidatedDeployment`: the *ingestion* path (YAML →
  validate) is runtime-checked (smart constructors, phantom `ServiceRef`,
  sums, `Either`-for-XOR) because parsed data can't carry compile-time tags;
  the *authoring* EDSL path is where type-level guarantees live. Crucially,
  **PureScript row types ARE type-level sets**, which *fixes Joey's own
  stated wart* — he wanted a set but had an order-sensitive type-level
  *list*. A service phantom-indexed by a row (`reachable`, `hasReadiness`, …)
  with `Row.Cons`/`Union`/`Lacks` constraints models the metatype set
  natively; `type-equality`/Leibniz + final-tagless cover genuine
  GADT-refinement. Result: `routeTo`/`requiresReady`/`bindsTo` combinators
  that only typecheck against compatible endpoints — `UncheckableGate`
  becomes a compile error in authored deployments.
- **Lesson:** check-then-ensure = `plan`/`apply` in miniature; a satisfied
  property is a no-op = "reconcile only the stale."
- Links: [Hackage](https://hackage.haskell.org/package/propellor),
  [GADTs post](https://joeyh.name/blog/entry/making_propellor_safer_with_GADTs_and_type_families/),
  [multi-OS post](https://joeyh.name/blog/entry/type_safe_multi-OS_Propellor/).

### Dhall (+ dhall-kubernetes / -docker-compose)
A *total*, non-Turing-complete typed config language (strongly normalizing).
- **Merge:** Dhall has **no deep merge** — only shallow `//` (prefer-right);
  merging is done by *explicit functions* (`λ overrides → defaults //
  overrides`), the auditable opposite of CUE/NixOS implicit merge. Lesson:
  whatever merge we pick, **state and test its associativity/commutativity**.
- **Open vs closed / D-10:** the `omitNull` vs `omitEmpty` saga — "field
  absent" and "field present-but-empty" are *semantically different* in k8s
  (an absent `labelSelector` matches nothing; an empty one matches
  everything). Collapsing them inverts deployment semantics. **Model `Absent
  | Present a` explicitly; never let decoders default-fill silently.**
- **Totality:** safety comes from giving up Turing-completeness; the *proven*
  artifact is a distinct type. Mirrors our post-`validate` acyclic boot order
  being constructible only by the validator.
- Links: [safety guarantees](https://docs.dhall-lang.org/discussions/Safety-guarantees.html),
  [dhall-kubernetes](https://dhall-lang.github.io/dhall-kubernetes/),
  [omitNull #86](https://github.com/dhall-lang/dhall-kubernetes/issues/86),
  [deep-merge #340](https://github.com/dhall-lang/dhall-lang/issues/340).

### Build Systems à la Carte (Mokhov/Mitchell/PJ) + Shake — *the plan/apply core*
Factors every build system into **scheduler** (order: topological /
restarting / suspending) × **rebuilder** (staleness: dirty-bit / verifying-
traces / constructive-traces). The key type:
`Task c k v = forall f. c f => (k -> f v) -> f v` — `c = Applicative` ⟹
**static** deps (knowable before running → provably acyclic); `c = Monad` ⟹
**dynamic** deps (chosen from fetched values → not statically checkable).
- **D-8:** our "reconcile only the stale" is a rebuilder. Use
  **verifying-traces** (hash inputs+outputs) because deployment reality
  drifts *out of band* — a dirty-bit misses external drift.
- **D-9:** keep Bosun's dependency graph **applicative** so "proven-acyclic
  boot order" is a real theorem. Any edge whose existence depends on
  *observed runtime state* (e.g. a route to a discovered upstream) is
  **monadic** — quarantine it in an explicitly-typed escape hatch, don't let
  it pollute the static acyclicity guarantee.
- Links: [paper PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2018/03/build-systems.pdf),
  [JFP extended](https://www.cambridge.org/core/services/aop-cambridge-core/content/view/097CE52C750E69BD16B78C318754C7A4/S0956796820000088a.pdf/build_systems_a_la_carte_theory_and_practice.pdf),
  [`build` on Hackage](https://hackage.haskell.org/package/build).

### NixOps & Haskell k8s libs (reference-tier)
NixOps: **logical/physical separation** (what a machine does vs where it
runs) → keep Bosun's dependency graph executor-agnostic; attach the executor
as a separate swappable layer. (Nix is dynamically typed → reference, not
study-firsthand.) Haskell `kubernetes-api` is OpenAPI-codegen'd, one package
*per k8s minor version* — lesson: handle schema drift by **versioning the
whole generated type set**; and those types guard only the wire boundary,
not semantic validity (cycles, collisions) — *that gap is Bosun's value-add*.
Ingest *from* them, validate *into* our own tight model; don't reuse their
enormous open-record surfaces.

---

## Adjacent typed-config / IaC

### systemd — *fixes the `EdgeKind` ADT (D-1, D-2)*
The reference dependency taxonomy, and its core lesson is **orthogonality**:
- **Ordering** (`After=`/`Before=`) — purely *when*, no implication the other
  unit is even wanted.
- **Requirement** — *whether*, on a gradient: `Wants=` (best-effort, absent
  OK) < `Requires=` (hard; fail if it fails) ; `Requisite=` (must *already*
  be active, never auto-start — external deps); `BindsTo=` (Requires +
  crash-coupling: stop if it stops unexpectedly); `PartOf=` (reverse-only:
  stop/restart of parent propagates to me, but starting parent does *not*
  start me).
- **Lesson:** ordering and requirement are **separate fields**, not one enum —
  real edges combine them (the canonical `Wants=`+`After=` pair). Our single
  "co-life" must split into start-coupling (Requires), crash-coupling
  (BindsTo), reverse-propagation (PartOf). Reverse-proxy-route is *not* a
  lifecycle edge — keep it in a separate graph (Pulumi, below).
- Links: [systemd.unit](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html),
  [systemd by example pt2](https://seb.jambor.dev/posts/systemd-by-example-part-2-dependencies/),
  [PartOf vs BindsTo #23194](https://github.com/systemd/systemd/issues/23194).

### CUE — *the model for reconcile + drift (D-3, D-4)*
Config = **unification** on a single lattice of types-and-values; unification
is **commutative, associative, idempotent**; agreement merges, conflict
yields **bottom (`_|_`)**; order-independent.
- **D-3:** model Bosun's `reconcile` as a **lattice meet with an explicit
  `Conflict` value**, not last-write-wins. Because meet is comm/assoc/idem,
  **cross-source drift detection falls out for free** — drift is just
  non-idempotent re-unification. CUE *preserves and reports* disagreement;
  NixOS *resolves* it by priority. For a tool whose headline is drift
  detection, **CUE's stance is the right default.**
- **D-4 (resolves E9):** CUE's **open vs closed structs** (`{...}` allows
  extra fields; `close()`/`#Def` forbid them) *are* our lingua-franca↔lossless
  toggle. **Ingest as open** (passthrough preserved → round-trip fidelity);
  **validate by unifying against a closed `#Service`** so a surviving
  unmodeled field becomes bottom = "unmodeled field present," *reported*
  (neither silently dropped nor silently kept).
- Links: [The Logic of CUE](https://cuelang.org/docs/concept/the-logic-of-cue/),
  [Unification](https://cuelang.org/docs/tour/basics/unification/),
  [Bottom](https://cuelang.org/docs/tour/types/bottom/).

### NixOS module system — *the merge-strategy catalog (D-11)*
Many modules each declare typed `options` (with a per-type merge fn) + partial
`config`; the system fixed-points and merges them.
- **Per-option-type merge + priority lattice:** `attrsOf` key-union+recurse;
  `listOf` concat; scalars **refuse to merge** (conflict = error) unless one
  wins; priorities `mkDefault`(1000) < normal(100) < `mkForce`(50).
- **Lesson:** make Bosun's merge **type-directed** — encode each field's
  merge strategy in its type (replicas: conflict-on-disagree; labels: union;
  …) so reconcile is total and conflicts are *values*. But adopt **CUE's
  report-don't-resolve** default over NixOS's priority-resolve (which *hides*
  disagreement — the opposite of what we want). NixOS's opaque priority
  conflicts are a top user pain; learn the taxonomy, not the ergonomics.
- `freeformType` = the passthrough escape hatch (with known merge gaps).
- Links: [option types](https://nlewo.github.io/nixos-manual-sphinx/development/option-types.xml.html),
  [lib/modules.nix](https://github.com/NixOS/nixpkgs/blob/master/lib/modules.nix).

### Pulumi — *two-graph separation + inferred edges (D-5, D-6)*
Two *separate* graphs: (a) parent/child **organizational** graph (no
provisioning effect) and (b) the **real dependency** graph, **inferred from
`Output`→`Input` dataflow**; `dependsOn` only adds edges it can't infer.
- **D-5:** Bosun's **containment** edges (profiles/namespaces) are Pulumi's
  organizational graph — **never topo-sort over them**; only the
  ordering/requirement graph drives boot order. Two distinct edge types in
  two distinct graphs.
- **D-6:** tag dependency edges `Inferred DataRef | Declared`. Edges derivable
  from a service referencing another's port/socket/env should be **inferred**;
  only genuinely external ordering is hand-declared. Aids drift explanation
  and lets validate warn on redundant manual edges.
- Links: [dependsOn](https://www.pulumi.com/docs/iac/concepts/resources/options/dependson/),
  [resource model #1108](https://github.com/pulumi/pulumi/issues/1108).

### Terraform — *three-way state + typed change-set (D-7)*
Desired (`.tf`) vs **recorded** (state file = last-known) vs **observed**
(`refresh` reads reality). `plan` = three-way diff → typed CRUD change-set;
drift = observed ≠ recorded.
- **D-7:** model **all three** as separate typed values. Diffing only
  desired-vs-observed can't distinguish "*I* changed the config" (→ apply)
  from "reality drifted underneath me" (→ adopt/import) — different actions.
  `plan` emits a reviewable **typed `Plan` ADT**, never an imperative
  one-pass reconcile.
- Link: [drift with Terraform](https://www.hashicorp.com/en/blog/detecting-and-managing-drift-with-terraform).

### kustomize / jsonnet (D-11)
kustomize: no templating, pure strategic-merge — and it merges container
**lists by their `name` key**, not by position. **Lesson:** lists-of-records
need **merge-by-identity-key**; decide each list field's key explicitly
(neither concat nor positional). jsonnet (Turing-complete templating) is the
un-analyzable opposite of what `validate` needs — avoid.

### Academic — session types (inspiration only)
No mature "typed deployment calculus" exists. Session-typed processes
formalize protocols where the type enforces order + data dependence — the
backbone framing for **probe-gated edges** ("B may receive traffic only after
announcing readiness"). A `Requires(OnReady)` edge guarded by a `readiness`
probe is a tiny two-state session. Inspiration for the *framing*, not an MVP
dependency. [Depending on Session-Typed Processes](https://arxiv.org/pdf/1801.08114).
