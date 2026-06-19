# Three engines, one typed spine — the build / deploy / run architecture

**Status:** DESIGN (2026-06-18). Companion to `UNIFIED-DAG-VISION.md` (the
primary ShapedSteer vision); extends `ARTIFACTS.md` (the artifact axis, built),
`EXECUTORS.md` (the executor seam), `FEDERATION.md`. Written from the
SDI-replacement → Bosun work, which "unravelled into the OS" coherently: the
deploy/process engine turned out to be one face of a single typed-edge DAG that
runs from a code file to a running instance on a remote machine.

> Provisional home: lives in `bosun/docs/` beside its siblings; promote to the
> ShapedSteer vision level next to `UNIFIED-DAG-VISION.md` when convenient.

## 1. The whole picture — one typed-edge DAG

```
  VCS ─build─▶ artifact ─deploy─▶ instance ─run─▶ (supervised process)
       └────────── one typed-edge DAG; same nodes, different typed edges ──────────┘
```

The end goal of the superset tooling: render *that whole chain* — code file →
build → artifact → deploy → running remote instance — as **one Sankey-like
chart**, because it is **one traversable typed graph**, not three stitched-together
exports. ShapedSteer *is* that graph. Everything below serves making it a single
introspectable structure.

## 2. The shared pattern (proven by Bosun, applied three times)

```
  typed model (MISU)  ─▶  pure decisions (conformance-portable)  ─▶  thin pluggable effect seam (executors)
```

Bosun did this for deploy+process. The build layer does it twice more (build
algebra, derivation authoring). Three engines, one pattern, **one type layer**.

## 3. The three engines (siblings, joined at the pin)

| engine | role | nature |
|---|---|---|
| **BSàlC** (Build-Systems-à-la-Carte, PS port) | the build *algebra* — `Task` (Applicative=static deps / Monad=dynamic deps), scheduler × rebuilder, freshness traces | pure PS, decides *what/whether to build* |
| **Nix-eDSL** | authoring *derivations* — a typed PS eDSL that emits `.drv` | pure PS, the *front* of Nix |
| **Bosun** | deploy+process — reconcile/plan/apply + supervise/observe | pure core + executor seam (built) |

They join at **the artifact pin**: a build's output content-hash *is*
`x-bosun.artifact { source, pin }` (already built), which *is* the deploy DAG's
input. BSàlC's *trace* and Bosun's *freshness edge* are the same notion at the two
ends of that seam.

## 4. Nix: replace the front, delegate the back

Nix is two stacked things with opposite verdicts:

- **Front — the language + evaluator** (evaluates expressions → a `.drv`, a pure
  data structure). **Replace it** with a typed PS eDSL that emits `.drv` / the
  JSON-derivation format directly — skipping the Nix language *and* evaluator. This
  is the part better written in PS, and the part tooling must be able to introspect.
- **Back — the store + sandbox + substituters + nixpkgs.** Content-addressed
  `/nix/store`, the hermetic build sandbox, binary caches, the curated package
  set. **Delegate it** (`nix-store --realise`) — OS-deep, security-sensitive, and
  *the* reproducibility guarantee; reuse it exactly as we reuse macOS/Linux.

This is the same algebra/executor split as Bosun-over-Docker and BSàlC-over-Nix:
own the description, delegate the heavy substrate.

**Scope discipline (so this doesn't become its own sweater):**
- Emit derivations; do **not** reimplement the store, the sandbox, or the
  evaluator-in-full. A small *derivation-emitting* eDSL (declare inputs, builder,
  env → a typed `Derivation`) is the whole job — not a Nix-language reimplementation.
- **Reference nixpkgs, don't rebuild it.** Derivations depend on
  nixpkgs-provided toolchains (`purs`, `spago`, `go`, `julia`, `python`) *by store
  path* — inherit the reproducible toolchain closure for free; replace only the
  *glue*.

## 5. Two orthogonal axes — keep them distinct

1. **Executor axis — what an engine *drives*.** `process | docker | launchd |
   nix-store | …` — the foreign substrate it observes/controls. (`EXECUTORS.md`.)
2. **Runtime axis — what a PS engine/tool is *compiled to*.** `Go | BEAM | Node |
   …` — chosen by the runtime's *fitness* for the tool.

They are independent. A supervisor written **once in PureScript** compiles to **Go**
(a static binary for the eurorack surface / minimal targets) *or* to **BEAM**
(supervision trees, distribution, hot reload for a server) — same source, same
types, different runtime by fitness.

## 6. PureScript as the typed control/consistency spine (the real "language independence")

Language independence here is **runtime choice over a shared PS type layer** — not
"any language via wire contracts." Write each tool in the runtime whose properties
fit the job, but **define the control/consistency types ONCE in PureScript** and
compile them to every runtime via the backend family (Gnomon → Go, purerl → BEAM,
JS → Node, …).

The payoff is structural: the contracts **between** runtimes — a Go executor ↔ a
BEAM supervisor ↔ a Node UI — are **generated from the same PS types via codecs**,
so cross-runtime wire compatibility is guaranteed *by construction*, not by
hand-synced schemas. **No schema drift across the federation.** This is
`FEDERATION.md`'s "typed capability > ssh shell" realized, and it is exactly
Bosun's node≡Go conformance generalised from {node, Go} to {Go, BEAM, Node, …}
with types shared across all.

The `{substrate} × {runtime} × {target}` cube (from the eurorack-surface note);
**PureScript is what holds the cube together with types.**

## 7. Why the eDSL, not Nix expressions — the decisive reason

Not syntax taste. The Sankey chart (§1) requires build+deploy+run to be the **same
introspectable typed structure**. Nix expressions make the build region a *black
box* — you'd run the Nix evaluator to know what it does. A typed PS `Derivation`
makes the build graph the same `Data.Graph`-able value as the deploy and process
DAGs. **The eDSL is what makes the one-chart goal possible at all.**

## 8. First steps (smallest honest path; each is forward-compatible)

1. **BSàlC algebra on Gnomon** — the pure build-DAG core (same pure-core +
   conformance pattern, a third time).
2. **`Derivation` model + a LOCAL realizer** (build + hash → pin). Closes
   code→artifact→deploy **end-to-end with zero Nix**; proves the pin seam.
3. **Spike: hand-emit one `.drv` from PS and `nix-store --realise` it.** This is the
   load-bearing assumption of the whole front-replace/back-delegate plan — prove it
   *before* building the eDSL on top.
4. **Nix realizer as an executor** — slots in behind the realizer seam exactly
   where Docker slotted into Bosun. PureScript on top, Nix's hermetic store
   underneath.

## 9. Prior art to evaluate (next, fresh session)

**`purs-nix`** — https://github.com/purs-nix/purs-nix. It is *Nix-builds-PureScript*
(the inverse of what we author), so it is most relevant to the **realizer for our
own PS-language artifacts**: how a PS tool (a Gnomon→Go binary, a purerl→BEAM
service, a Node bundle) becomes a reproducible derivation. Evaluate against this
plan:
- usable **as-is** as the PS-artifact realizer (step 4 for PS inputs), or
- **inspiration** for the eDSL's derivation codegen?
- Note the direction we want is **PS → `.drv`** (emit derivations), which is one
  level *lower* than emitting Nix-expression text — confirm whether purs-nix gives
  us derivation-level hooks or only expression-level.

**Sequencing — do the spike (§8.3) FIRST.** Prove `.drv`-emission +
`nix-store --realise` by hand before the purs-nix deep dive, so the evaluation
happens against a *known-good* front-replace/back-delegate baseline rather than in
the abstract. The spike answers "does our seam hold at all?"; purs-nix then answers
"can we reuse it / what does it inspire?" — and the order matters because a failed
spike would change what we even want from purs-nix.
