# Bosun — Principles: all uncertainty at the edges

The discipline behind the pipeline shape. `DESIGN.md` gives the types;
`SCENARIOS.md` stress-tests them; `PRIOR-ART.md` justifies the choices. This
file states the *governing principle* they all serve.

## The principle

Alexis King, **"Parse, Don't Validate"** (2019,
`lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/`): a *parser* is
a function from less-structured input to more-structured output that **may
fail** and **preserves the evidence of its work in the result type**. A
*validator* checks and throws the evidence away (returns a bool / unit),
forcing every later stage to re-establish the same facts.

The fuller principle the post argues for: **push all partiality and
uncertainty to the edges of the system, and keep the interior total.** Do the
failure-prone work *once, at the boundary*, producing a value whose type
guarantees the invariants; the core then runs total functions over rich
types and never re-doubts what the edge already proved.

The anti-pattern this defeats — King draws the term from the LANGSEC
literature — is **shotgun parsing**: input checks scattered throughout the
code, interleaved with processing, so you can never be certain every check
has run before you act. (Compare Gary Bernhardt's "functional core, imperative
shell" — the same shape from a different angle.)

Bosun is, structurally, an argument for this principle applied to deployment.
The whole pipeline exists to move uncertainty to two edges and keep
everything between them total.

## Bosun has TWO edges, not one

The easy mistake is to think "the config files are the edge." There are two,
and they have different tempos:

1. **The configuration edge** — *static*, parsed once. compose / registry /
   plists / systemd units → `ServiceInstance` → `Deployment` →
   `ValidatedDeployment`. This is `ingest`/`reconcile`/`validate`.
2. **The observation edge** — *dynamic*, re-parsed every `plan` cycle. Running
   reality (an HTTP status, a TCP refusal, an exec exit code, a timeout, a
   permission error, `launchctl list` output) → a total `Status`.

The second edge is the one we'd most easily get wrong. Raw probe output is
*uncertain*, and that uncertainty must be **parsed at the observation edge**
into a closed, total `Status` — never inspected ad-hoc inside `plan`:

```purescript
-- The observation edge is a PARSER too: raw probe result → total Status.
data Status
  = Running | Starting | InBackoff | Failed | Down | CompletedOk
  | Unknown Reason          -- the probe could not determine the answer
                            -- (timeout / refused / no permission) — made
                            -- EXPLICIT, not silently coerced to Down.

observe :: Probe -> Effect Status   -- synchronous; the only place probe
                                    -- uncertainty is resolved
```

If `plan` ever branched on "the HTTP call returned an error, so assume the
service is down," that is shotgun parsing leaking into the core. Instead
`observe` is the sole place that turns a messy probe result into a `Status`,
and `Unknown` is a first-class outcome `plan` must handle deliberately (e.g.
"don't act on a service whose state I can't read"). `plan` and everything
downstream consume `Status`, never raw probe bytes.

## The invariant-boundary ledger (the anti-shotgun-parsing artifact)

Each invariant is established at **exactly one** boundary, **witnessed by the
output type**, and **never re-checked** downstream. This table is the
contract; a check that appears in two rows is a bug.

| Invariant | Established at | Witnessed by (type) | Never re-checked after |
|---|---|---|---|
| Port in 1..65535 | ingest | `Port` (smart ctor) | — total thereafter |
| cwd is absolute | ingest | `AbsPath` (smart ctor) | — |
| Exactly one launch mechanism | ingest | `Executor` (sum) | — |
| image XOR build | ingest | `Either ImageRef BuildContext` | — |
| Optionality preserved (absent ≠ empty) | ingest | `Absent \| Present a` | — |
| Sources agree (or `Conflict`) | reconcile | `Deployment` (meet result) | — |
| One logical identity per service | reconcile | `ServiceId` | — |
| Every dependency target exists | validate | `ServiceRef` (minted-present) | `plan` never sees a dangling ref |
| Graph is acyclic | validate | `BootOrder` (its existence ⇒ acyclic) | `plan` never topo-sorts |
| Every gate is checkable | validate | (readiness ≠ `NoProbe` on gated upstreams) | `apply` never waits on an unsatisfiable gate |
| Selectors closed under `Requires` | validate | `selectors :: Map …` in `ValidatedDeployment` | — |
| Every route is backed | validate | `routes :: Map RoutePath ServiceRef` | — |
| Observed reality → total status | observe (obs. edge) | `Status` | `plan` never reads raw probe output |

Read top-to-bottom, it's the proof that by the time you hold a
`ValidatedDeployment` + a `Status` map, **every uncertainty has already been
discharged at a named edge** — `plan` and `apply` are total over what
remains.

## Carried-but-inert: the `extra` rule

`extra :: Map String Json` (the open-ingest passthrough, `DESIGN.md` D-4)
carries *unmodeled* source fields through the core so emit can round-trip them
byte-for-byte. That is **carried uncertainty**, and it's only legitimate while
it stays **inert**:

> **`extra` is write-once at `ingest`, read-once at `emit`, and untouched in
> between.** No `reconcile`/`validate`/`plan` logic may branch on its
> contents.

The parsed *type* of `extra` is precisely "fields we have decided not to
understand" — that is a total statement, so carrying it does not violate the
principle. The day core logic wants to peek inside `extra` to make a decision
is the day that field must be **promoted into the modeled types** (and a new
ledger row). The rule makes that pressure visible instead of letting ad-hoc
`extra`-peeking accrete — which would be shotgun parsing by the back door.

## Type safety back and forth

King's follow-up framing (proof obligations can be discharged by the *caller*
or the *callee*): Bosun always pushes the obligation **up to the parse
boundary**. Every function takes the **tightest type it needs** and trusts it.

- `plan :: ValidatedDeployment -> WorldState -> Plan` — demands the *validated*
  type; it does not accept a loose `Deployment` and defensively re-validate.
- `apply :: Plan -> …` — demands a `Plan` (a reviewed, typed change-set), not
  a `ValidatedDeployment` it must re-plan.

The type signatures thus *track which proofs have been discharged*. You cannot
call `plan` without first having parsed your way to a `ValidatedDeployment`,
and the compiler enforces that ordering — the pipeline's stages are not a
convention, they're a type-level dependency chain.

## Why this is also the no-Aff seam

Effects are the deepest form of uncertainty (the world can do anything). The
principle therefore predicts the no-Aff seam (`DESIGN.md` §8): the only
genuinely effectful, can-fail-arbitrarily work — `observe` (sync probes) and
`apply` (os-exec / concurrency) — sits at the two edges. Everything between
(`reconcile`, `validate`, `plan`, all rendering) is pure and total. Keeping
uncertainty at the edges and keeping effects at the edges are the same
discipline; that they coincide is a good sign the decomposition is right.

## Lineage: signal-box, and measuring instead of asserting

Bosun's kernel exists already, in miniature: the **signal-box** demonstrator,
whose thesis is *"illegal states made unrepresentable — measured, not
asserted."* It fixes a tiny **finite** world (a single-line railway passing
loop), writes one oracle (`isLegal`) once against the loosest type, then climbs
a **ladder of state types** — each rung a transferable technique — and at every
rung **exhaustively enumerates** the finite space and **counts** how many
states in each named violation family the rung extinguished, while proving it
still covers every legal state.

Bosun is that ladder applied to a real, **infinite**, painful domain. The rungs
map almost verbatim:

| signal-box rung | Bosun |
|---|---|
| v1 *name your atoms* | `Port` / `AbsPath` / `Host` / … newtypes + smart ctors |
| v2 *derive, don't store* | exposure-vs-executor; edges inferred from dataflow; **local-vs-remote = `host == thisHost`, machine-vs-CDN = an `Executor` property** (precisely the §3.1 Host fix — derived, so it can't contradict) |
| v3 *locking table as a type* | `Executor` / `Exposure` closed sums; `Either ImageRef BuildContext` — the conflicting-state constructor *does not exist* |
| v4 *parse, don't validate* | `validate :: Deployment -> V (Array DeployError) ValidatedDeployment`; opaque tight type, representable = legal by API totality — signal-box's `make :: … -> Either (Array Violation) State`, verbatim |

Two of signal-box's moves transfer, and one **extends**:

- **Coverage — safety never bought with expressiveness.** signal-box proves
  every rung still reaches all its legal states ("the squeeze comes from above
  only"). Bosun's analog: closed-`validate` must extinguish every *illegal*
  deployment while rejecting **no legal one** — a round-trip / coverage
  property (`SCENARIOS.md §G`).
- **Named violation families.** signal-box counts collision / conflicting-greens
  / derailment / green-into-occupied going extinct rung by rung. Bosun's fault
  injectors (§G) target the same shape — PortCollision / DependencyCycle /
  DanglingDependency / UncheckableGate — and confirm each is caught.
- **The extension: finite enumeration → infinite via PBT.** signal-box can
  *count* because its world is finite. Bosun's is infinite, so exhaustive
  enumeration is impossible — and **typed-generator property testing (§G) is
  the infinite-domain analog of signal-box's exhaustive count.** That is how
  "measured, not asserted" survives the jump to a real domain: generate the
  strong types, *measure* that the violation families stay extinct, rather than
  merely claiming it. (A signal-box-style single `isLegal` oracle, written once
  against the loose `Deployment` and never changed, can audit that `validate`
  agrees — the method borrowed directly.)

And the tie is **literal, not only thematic.** signal-box's pure core (no FFI,
no `Effect`, no PRNG) runs *identically across every PureScript backend* as a
conformance matrix. Bosun's pure core — `ingest` / `reconcile` / `validate` /
`plan`, the **Detect** tier — has the same shape and runs on **purescript-go**,
the backend Bosun is the MVP showcase for. The effectful edges (`apply`) are
where Bosun extends past signal-box's purity, exactly along the no-Aff seam.
So Bosun is signal-box's thesis made *useful*, *infinite-domain*, and run
through the Go column.
