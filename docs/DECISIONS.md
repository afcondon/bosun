# Bosun — Decisions

Resolutions to the open questions raised in `SCENARIOS.md §E`. ADR-style:
each records the context, the decision, the concrete type change, and the
consequences. Type deltas are folded into `DESIGN.md`.

---

## D-E3 — Facet key vs must-agree fields

**Context.** One logical service can have several *deployment facets*
(`psd3-tilted-radio` runs both mbp-native @3013 and macmini-container behind
the edge). Reconciliation groups source instances by identity, then must
decide which fields are *allowed* to differ across facets and which
disagreements are *bugs*.

**Decision.** Three tiers:

| Tier | Fields | Rule |
|---|---|---|
| **Identity** (the grouping key) | `(ProjectSlug, Role)` | cannot differ — it's how instances are grouped into one `ServiceId` |
| **Facet key** (defines a facet) | `(Host, ExecutorMechanism)` | *legitimately* differs across facets — "the two ways we deploy this" |
| **Facet-local** | exposure/port, restart, env, exact probe wiring | may differ freely *between* facets; must agree *within* a facet |
| **Must-agree across facets** | the **dependency shape** (the set of `(target, requirement-kind)` edges) + the service contract | disagreement = `CrossSourceDrift` (a real conflict) |

This splits the loose word "drift" into two outcomes:
- **Facet divergence** — two facets differing on facet-local fields (port,
  name, exposure). *Expected; reported informationally,* not an error.
- **Conflict** — two sources describing the *same* facet that disagree on a
  facet-local field, **or** any cross-facet disagreement on the dependency
  shape. *An error* (`CrossSourceDrift`).

**Type.** `reconcile` partitions each `ServiceId`'s instances by facet key,
unifies (D-3 lattice meet) *within* each facet (conflicts there = errors),
and meets the must-agree projection *across* facets.

**Consequences.** `DESIGN.md §7`'s description of the registry↔compose
divergence as "drift" is sharpened: it is **facet divergence** (two facets),
surfaced to the human as "this service has two deployments, here's how they
differ" — *not* an error. The reconciler's real error-hunting is for
within-facet conflicts and contradictory dependency shapes.

---

## D-E2 — Single-facet is not drift

**Context.** A service present in only one source (mbp-only dev service, no
compose counterpart). Is "missing from the other source" drift?

**Decision.** **No.** Absence of a facet is never an error by default — a
single-facet service simply has one facet and nothing to conflict with.
Reconciliation never requires a service to appear in N sources.

Optionally, a deployment may declare an **`expectedFacets`** policy per
service (e.g. "this must have a `(macmini, container)` facet"); *then* a
missing expected facet is a reported error. Opt-in, not default.

**Type.** `expectedFacets :: Maybe (Set FacetKey)` on a service; `Nothing`
(the default) ⇒ never complain about absence.

**Consequences.** Follows directly from D-E3's facet model. Keeps the common
case quiet; lets the careful case assert coverage.

---

## D-E5 — Stop/restart propagation along `BindsTo` / `PartOf`

**Context.** `plan` must compute `Stop`/`Restart` changes, not just `Start`.
`BindsTo` (crash-coupling) and `PartOf` (reverse lifecycle) propagate
*backwards* along dependency edges; the algorithm and its termination need
pinning.

**Decision.** Dependency edges point `A → B` ("A depends on B"). **Start**
propagates *forward* (B before A, the boot order). **Stop/restart** propagates
*backward* — from the depended-upon to its dependents — over exactly two edge
kinds:

- For each `Stop(X)` or observed `X = Failed`: every `Y` with `Y BindsTo X`
  gets `Stop(Y)`.
- For each `Stop(X)`: every `Y` with `Y PartOf X` gets `Stop(Y)`; for each
  `Restart(X)`: every `Y` with `Y PartOf X` gets `Restart(Y)`.

Take the **transitive closure** over reverse `BindsTo`/`PartOf` edges. The
dependency graph is proven acyclic (the `BootOrder` certificate), so the
closure **terminates**. `Requires`/`Wants` do **not** propagate stop (only
`BindsTo`/`PartOf` couple lifecycle backwards — systemd's exact semantics).

**Ordering of stops** = the *reverse* of `BootOrder` stages: stop dependents
before the things they depend on.

**Type.** A pure closure step in plan construction:
`propagateStop :: ValidatedDeployment -> Set ServiceRef -> Set (ServiceRef × Change)`,
folded into `plan` before the staged `Plan` is emitted.

**Consequences.** `Stop` is a first-class part of `Plan`, computed
deterministically; killing a service correctly tears down what was bound to
it, and only that.

---

## D-E7 — Probe ports are the service's own listening port

**Context.** A compose service behind the edge has **no host port** but a
healthcheck hitting `http://localhost:<internalPort>/` inside the container
(`SCENARIOS.md C1`). May a `Probe`'s port be a non-host-exposed port?

**Decision.** **Yes.** A `Probe` addresses the service's *own listening
port* — host-published or internal — because health checks run from a vantage
that can reach it (inside the container, or on the host). The type does **not**
constrain `Probe` ports against `Exposure`. (Health *is* nested inside
port/socket-bearing exposure variants, so a `NoNetwork` service can't carry an
HTTP probe — that part stays a Tier-1 constraint.)

**Type.** No new constraint; documented invariant. `Probe.port` is free of
`Exposure`'s host-publication.

**Consequences.** Closes C1; avoids an over-constraint that would have made
the (very common) internal-service-with-healthcheck pattern unrepresentable.

---

## D-E8 — `ConfigSource` with supplier tracking

**Context.** `${VAR:-default}` (compose) resolves to bound / defaulted /
unbound. Only *unbound with no default and no supplier* should be
`UnboundReference`. Requires modelling who supplies a binding.

**Decision.** Separate a config *reference* from a config *supplier*; resolve
references against suppliers in scope at `validate`.

**Type.**
```purescript
data ConfigRef = ConfigRef EnvVar (Maybe String)   -- referenced var + optional inline default
data ConfigSupplier
  = InlineEnv (Array (Tuple EnvVar String))         -- compose environment: ; systemd Environment=
  | EnvFile AbsPath                                  -- compose env_file ; systemd EnvironmentFile=
  | ConfigMapRef String                              -- k8s
  | SecretRef String                                 -- k8s / Vault — PRESENCE tracked, value never read
```
`validate`: a `ConfigRef var mDefault` is satisfied iff some in-scope supplier
binds `var`, or `mDefault` is `Just`. Otherwise → `UnboundReference`. We track
the *name binding* and the *presence* of secrets; we never read secret values
(consistent with FOR-DEVOPS "ignore: secrets backends").

**Consequences.** Resolves C6. Also subsumes the SDI rule as a special case:
the public port must appear literally in the `startCommand` so SDI's rewrite
can land — i.e. the port is "supplied" by the command text, and its absence is
the same shape of error (`SdiContractViolation`).

---

## D-E11 — Conditional launchd `KeepAlive` vs `RestartPolicy`

**Context.** launchd `KeepAlive` can be a dict (`SuccessfulExit`,
`NetworkState`, `PathState`, `OtherJobEnabled`, `Crashed`) — strictly richer
than a `Never|OnFailure|Always|UnlessStopped` enum. Enrich, or accept loss?

**Decision.** **Enrich with the portable subset; report the rest as lossy.**
A restart policy is a base mode plus a set of additional conditions:

**Type.**
```purescript
type RestartPolicy =
  { base       :: BaseRestart            -- Never | OnFailure | Always | UnlessStopped
  , conditions :: Array RestartCondition  -- empty = unconditional
  }
data RestartCondition
  = WhilePathExists AbsPath   -- launchd PathState (RUNTIME keep-alive while path exists)
  | WhileNetworkUp            -- launchd NetworkState
  | OnlyIfCrashed             -- launchd Crashed ; ≈ systemd Restart=on-abnormal
  -- unmodeled KeepAlive dict keys ride in `extra` (D-4) and are reported on lossy emit
```

**Caution (honest cross-tool detail).** `WhilePathExists` is launchd's
*runtime* semantics (keep alive *while* the path exists); systemd's nearest is
`ConditionPathExists`, a *start-time* gate — **not the same thing**. So
`WhilePathExists` maps cleanly only to launchd; emitting it to systemd is a
*reported* lossy translation, not a silent one (E10's fidelity matrix). This
is exactly the kind of cross-tool semantic mismatch the lingua-franca claim
must handle by *reporting*, never by pretending.

**Consequences.** Resolves D3/E11 for the common, portable conditions; anything
exotic survives round-trip via `extra` and is never silently dropped.

---

## D-R1 — Retiring `Exposure`: opportunistic per-consumer pruning, not a big-bang pass

**Context.** `ADDRESS-TYPE.md` (adopted 2026-06-16) introduced
`Reachability` (a `Set Address` with explicit `BindScope`) as the stored
reachability model and kept the old `Exposure` sum alive as the derived
projection `classify :: Reachability -> Exposure`. That was deliberate: it let
every existing consumer keep compiling by reading `classify s.reachability`,
and kept the Detect golden + the backend-go differential byte-identical. The
open question (`ADDRESS-TYPE.md §10.3`): should we *finish the job* and delete
`Exposure`, leaving only the richer type?

**Decision.** **Yes — `Exposure` is a migration scaffold, not a permanent part
of the model — but retire it the way it was introduced: opportunistically,
per-consumer, never as a dedicated "rip out Exposure" pass.** Pruning a consumer
is justified only when `classify` is *in its way* (it needs structure `classify`
threw away), not for purity. The end state is not "`Reachability` replaces
`Exposure` 1:1": `Exposure` always conflated *where* (host vs internal) with
*what kind* (port vs socket vs proxy). The clean decomposition is
**`Reachability` = the data, `Openness` = the ordered security/ramp spine** —
once consumers read those two directly, the `Exposure` sum has no job left.

**Sequencing (cheapest- and safest-first):**

| Step | Consumer(s) | Cost | When |
|---|---|---|---|
| 1 | `Serve.admit`, `Observe.effectiveProbe` | **golden-neutral** — neither feeds the Detect conformance (`admit` is under `ServeMain`; `effectiveProbe` is CLI-only) | any time; strictly better (admit can choose among listeners + reject a loopback-bound port as unpublishable; observe probes the most-exposed port of a composite) |
| 2 | `exposureLabel` / the report → set-aware (`reachabilityLabel`) | **changes the Detect golden + conformance expectation** — must be a deliberate, reviewed golden regen; may surface *new* within-facet drift (two facets that `classify` collapsed to one label may now legitimately differ) | gate on "first real composite fixture exists" — until then `classify`'s collapse is a harmless lie (no fixture has a composite) |
| 3 | `View` wire (`exposure :: String`) | coordinate — the wire growing a `reachability` field is the **Pillar-3 / Chair session's** call (`ADDRESS-TYPE.md §8`); flipping `View` off `classify` unilaterally risks colliding with their work | whenever the badge needs the full `Address` |
| 4 | delete the `Exposure` type | one-line removal once no live consumer matches its constructors (optionally keep as a test/convenience export) | after 1–3 |

**Type.** No change lands with this ADR — it records the *plan*. End state:
`classify`/`Exposure` removed from the live path; `Openness` (already derived)
becomes the explicit spine for security checks and the viz colour-ramp;
`reachabilityLabel :: Reachability -> String` replaces `exposureLabel` and is
composite-aware.

**Consequences.** The migration stays low-risk *mechanically* — backend-go
already transpiles the richer type byte-identically (proven: 34 Go files,
`Set` + derived `Ord` over record-carrying constructors), so the type system
and the Go column will not fight the prune. The **only** step that touches an
irreversible contract is step 2's golden regen — that is the real decision point
and it is small. A standing follow-up rides along: the collision check currently
treats `Loopback`/`Internal` binds as non-contending (preserving the old
`InternalPort` behaviour), which is technically imprecise on a single host; the
richer type makes a future `bind-scope-overlap` refinement possible (see
`ADDRESS-TYPE.md §11`).

---

## D-S1 — The `/state` contract evolves additive-only; never a required field

**Context.** Bosun's `/state` endpoint is consumed by Bosun's Chair, which polls
it and decodes with an argonaut record decoder. Stage 2 (`supervise`,
`ROADMAP.md`) adds per-route runtime fields (`supervised`, `restarts`,
`lastTransitionAt`, `desired`) so self-healing restarts are observable across the
Chair's 1.5 s poll. Question raised in the engine↔Chair round 2
(`HANDOFF-CHAIR.md`): should any new field be *required* in the shared decoder?

**Decision.** **No — `/state` fields are added additive/optional, never
required.** The consumer set spans versions and modes: plain `serve` (no
supervisor) emits none of the Stage 2 fields, and older `serve`/`supervise`
binaries emit a subset. A required field would fail decode against exactly those
producers — re-breaking the `serve`↔`supervise` contract *parity* from the
opposite direction (the guarantee in `ROADMAP.md` Stage 2 / `HANDOFF-CHAIR.md`
round 2 is that the Chair lights up against either mode unchanged). So the Chair adds each field as `Maybe`
with graceful-absence rendering; the producer emits it only when meaningful. The
floor of the contract stays `{routes,redirects,rejected}` with
`RouteStatus{serviceId,publicPort,internalPort,up,pid}`.

**Consequences.** `/state` can grow indefinitely without a flag-day: any field
that some producer can't supply is simply absent, and every consumer must
tolerate absence. The cost is that the decoder can never *enforce* a field's
presence — semantic "is this a supervised producer?" must be inferred from a
value (e.g. `supervised == true`) rather than from the field's existence. Cheap
and correct given heterogeneous producers. (Failover's future `role`/`active`
fields ride the same rule.)

---

## Still open (deferred, not blocking)

- **E10** — the full EdgeKind × tool *fidelity matrix* (which requirement
  kinds survive/collapse/drop per target). The richer `Requirement` gradient
  (D-2) means we now know *what* to tabulate; building the table is a
  per-adapter task at implementation time.
- The reconciliation **identity fallback** when no `ProjectSlug` exists
  (`DESIGN.md §10`): a hand-maintained alias map vs interactive
  propose-merge. Leaning alias-map for MVP; revisit if it gets unwieldy.
