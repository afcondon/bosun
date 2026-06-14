# Bosun — Design

> *Bosun* — a typed **deployment-configuration reconciler** (a bosun keeps a
> ship's whole rig in working order). Two hats: (1) the MVP-gating showcase
> for the PureScript→Go backend; (2) a standalone ShapedSteer-family
> proof-of-concept — a deployment is a typed DAG.

Status: design. No code on disk yet. This document is the type design we
build from.

---

## 1. Thesis

A deployment is a **typed directed graph**. Nodes are services; edges are
typed dependencies; a small set of executors bring nodes to life; a small
set of views render the graph. This is the ShapedSteer vision applied to
one of the domains the vision explicitly names (Infrastructure &
Deployment, alongside Terraform plan/apply and k8s reconciliation).

The ambitious move — and the thing that makes Bosun worth building rather
than another compose-wrapper — is that **the typed graph is a lingua
franca**. Every real deployment tool is a *projection* of the same handful
of concepts:

> *a unit of work, brought up by some mechanism, reachable in some way,
> that depends on other units in some way, is healthy by some signal,
> restarts by some policy, and belongs to some selectable group.*

docker-compose, systemd, Kubernetes, Terraform, Nomad, launchd, a Procfile,
supervisord, the Marginalia port registry, the SDI lazy-spawn router — each
names these things differently and each forbids a *different* slice of the
illegal-state space. None forbids all of it. Bosun's core IR is the
**intersection of what they mean and the union of what they should
forbid**, and each tool becomes an **adapter** that *parses into* the IR
(ingest) and/or *renders out of* it (emit).

```
  ┌─ compose.yml ─┐                                    ┌→ compose.yml
  ├─ launchd .plist┤                                    ├→ launchd .plist
  ├─ systemd unit ─┼─ ingest ─→  Typed Deployment  ─ emit ─┼→ systemd unit
  ├─ marginalia DB ┤  (adapters)      Graph        (adapters)├→ Caddyfile / nginx
  ├─ SDI registry ─┤                    │                    ├→ Sankey / status-grid
  └─ k8s manifests ┘              reconcile + validate        └→ boot-timeline
                                         │
                                  plan → apply (reconcile reality)
```

This is **"parse, don't validate" at two altitudes**:

1. **Ingestion.** A messy source string/YAML/XML becomes a precise typed
   value. The polymorphic `startCommand` string becomes an `Executor` sum —
   after which a service *cannot* be both compose-managed and
   launchd-managed, because that state has no representation.
2. **Reconciliation + validation.** A loose `Deployment` (several sources
   making overlapping, possibly-contradictory claims) becomes a tight
   `ValidatedDeployment` (one resolved graph, a proven-acyclic `BootOrder`,
   no dangling edges) — after which `plan` and `apply` are **total**: a
   dependency cycle, a dangling dep, a port collision *literally cannot
   reach the executor.*

The payoff lands hardest when you point it at a real, drifted system. We
have one (§7).

This two-altitude parsing is one face of a single governing discipline —
*keep all uncertainty at the edges, keep the interior total* (Alexis King,
"Parse, Don't Validate"). That discipline, the **two** edges it implies
(configuration *and* observation), and the per-boundary invariant ledger that
guards against "shotgun parsing" are set out in **`PRINCIPLES.md`**, which
governs everything below.

---

## 2. The panoply — one concept, many dialects

The core types are derived from this table, not from compose alone. Each
column is an adapter; each row is a type. The rightmost column is what
Bosun's IR commits to.

| Concept | compose | systemd | Kubernetes | Terraform | launchd | Procfile / 12-factor | **Bosun IR** |
|---|---|---|---|---|---|---|---|
| Unit | `service` | `.service` unit | Pod / Deployment | `resource` | LaunchAgent | process / dyno | `Service` |
| Launch mechanism | image / build | `ExecStart=` | container image | provider API | `ProgramArguments` | command | `Executor` (sum) |
| Reachability | `ports:` / internal | socket / port | Service / Ingress | — | — | `$PORT` bind | `Exposure` (sum) |
| Dependency | `depends_on` | `After=/Requires=/Wants=/BindsTo=` | initContainers / readiness gates | implicit refs + `depends_on` | — (flat) | — (flat) | `Edge { kind }` |
| Readiness gate | `condition: service_healthy` | `Type=notify` (sd_notify) | readinessProbe | — | — | — | `Gate` + `Probe` |
| Liveness | `healthcheck` | `WatchdogSec=` | livenessProbe | — | `KeepAlive` | — | `Health.liveness` |
| Startup grace | `start_period` | `TimeoutStartSec=` | startupProbe | — | `ThrottleInterval` | — | `Health.startup` |
| Restart policy | `restart:` | `Restart=` + `RestartSec` | `restartPolicy` | `create_before_destroy` | `KeepAlive` dict | (platform) | `RestartPolicy` |
| Grouping / selection | `profiles:` | `.target` + `WantedBy=` | namespace + labels / overlays | workspace | — | Foreman formation | `Selector` (2nd edge type) |
| Config / env | `environment` / `env_file` | `Environment=` / `EnvironmentFile=` | ConfigMap / Secret | variables | `EnvironmentVariables` | env (12-factor III) | `ConfigSource` |
| Reverse-proxy route | (external) | (external) | Ingress host+path | — | — | router add-on | `Edge RoutesTo { path }` |
| Plan / apply | `up`/`down` (imperative) | `daemon-reload` + start | declarative + controllers | **plan/apply (diff)** | `bootstrap`/`kickstart` | — | `plan`/`apply` (diff) |
| Drift / reconcile | — | — | controller loop | `refresh` | — | — | à-la-carte rebuilder |
| Rollout strategy | recreate | — | rolling / canary | `create_before_destroy` | — | — | `Rollout` (post-MVP) |

Three observations drive the design:

- **systemd has the richest dependency vocabulary.** It cleanly separates
  *ordering* (`After=`) from *requirement* (`Requires=`) from *soft want*
  (`Wants=`) from *co-life* (`BindsTo=`/`PartOf=`). compose collapses all of
  this into one `depends_on` with a `condition:` rider. Bosun adopts
  systemd's distinctions as `EdgeKind` — they are real, and flattening them
  is a source of 3am surprises ("why did killing X take down Y?").
- **The readiness/liveness/startup split is universal and is where the MISU
  bites.** k8s, compose, and systemd all distinguish *"is it alive"* from
  *"is it ready for dependents"* from *"is it still booting, be patient."*
  An ordering edge that **waits** on an upstream (`condition: service_healthy`,
  a readiness gate) is only meaningful if the upstream **publishes a
  readiness signal**. Gating on a service with no readiness probe is a
  guaranteed hang or a blind race — and every tool lets you write it. Bosun
  makes it `UncheckableGate`.
- **The reverse-proxy route is an *edge*, not a property.** nginx/traefik/
  Ingress route tables are where "the comment said `/sankey` but nothing
  serves it" lives. Modelling the route as `Edge RoutesTo { path }` from the
  proxy node to the backend node makes that drift a typed error
  (`RouteWithoutBacking` / `ServiceExpectsRouteButNone`).

---

## 3. Core types

Idiomatic PureScript per `/purescript-style`: newtypes for domain concepts,
ADTs for closed alternatives, smart constructors for refinements, `V`
(validation applicative) for error *accumulation* — we want **all** the
inconsistencies in one pass, not first-fail. Codec values (not class
instances) for the JSON/YAML boundary. Sketch, not final.

### 3.1 Atoms (refined newtypes)

```purescript
newtype Port        = Port Int            -- mkPort :: Int -> Maybe Port  (1..65535)
newtype AbsPath     = AbsPath String      -- mkAbsPath :: String -> Maybe AbsPath  (leading '/')
newtype Domain      = Domain String       -- hylograph.net
newtype RoutePath   = RoutePath String    -- "/code", "/ee/api"
newtype EnvVar      = EnvVar String
newtype ProjectSlug = ProjectSlug String  -- stable NATO id from Marginalia, survives renames
newtype ServiceId   = ServiceId String    -- Bosun's stable logical identity (see §5 reconcile)

data Host = Mbp | MacMini | Cloudflare | AndrewOnly | NamedHost String
```

`Port` and `AbsPath` are the front line of MISU. `mkAbsPath "node router.mjs"`
returns `Nothing` — which is *exactly* how the real SDI registry row gets
flagged (§7): it has no `cd /abs` anchor, so no absolute cwd can be parsed
from it, the very footgun `SDI-COMPATIBILITY.md` warns about.

### 3.2 `Executor` — the polymorphic launch mechanism, as a sum

This is the heart of "parse the `startCommand`." Mutual exclusion by
construction: a service is launched **exactly one way**.

```purescript
data Executor
  = Process     { cwd :: AbsPath, command :: String, env :: Array (Tuple EnvVar String) }
  | Container   ContainerSpec
  | SystemdUnit { unit :: String, scope :: SystemdScope }      -- System | User
  | LaunchdJob  { label :: String, keepAlive :: KeepAlive, throttleSec :: Maybe Int }
  | StaticCDN   { provider :: CDNProvider, domain :: Domain }  -- Cloudflare Pages, etc.
  | Remote      { via :: RemoteVia, inner :: Executor }        -- ssh wrapper; recursive
  | Unmanaged   String   -- prose-only registry rows: "Runs as net.hylograph.* LaunchAgent"

data ContainerSpec = ContainerSpec
  { source       :: Either ImageRef BuildContext   -- image XOR build — both-at-once unrepresentable
  , internalPort :: Maybe Port
  , publish      :: Maybe Port                      -- host:container; Nothing = internal only
  }
```

- `Either ImageRef BuildContext` forbids compose's `image:`+`build:`-both
  footgun at the type level.
- `Remote` is recursive (`ssh host -- <inner>`), so the real
  `ssh andrew@andrews-mac-mini launchctl kickstart …` row parses to
  `Remote { via: Ssh …, inner: LaunchdJob … }` rather than collapsing to an
  opaque string.
- `Unmanaged` is the honest home for registry rows that are *documentation,
  not instructions* — SDI already treats `NULL`/prose `startCommand`s as
  non-actionable; the type says so.

### 3.3 `Exposure` — how it's reached, as a sum

```purescript
data Exposure
  = HostPort     Port                                      -- published to host  (3000:3000)
  | InternalPort Port                                      -- cluster/network-internal; siblings reach it
  | ProxyRoute   { proxy :: ServiceId, path :: RoutePath } -- behind edge/ingress; the route is an EDGE too
  | PublicDomain Domain                                    -- CDN / ingress host
  | UnixSocket   AbsPath                                   -- ~/.es9/control.sock, ~/.fh2/control.sock
  | NoNetwork                                              -- worker / one-shot
```

Note `UnixSocket` — the music rig's daemons (es9-daemon, fh2 daemon) are
real services reached by socket, not port. A model that assumed "service ⇒
TCP port" couldn't even *describe* half of Andrew's infrastructure. Breadth
earns its keep immediately.

### 3.4 Edges — typed dependencies (systemd's taxonomy, corrected)

> **Revised per prior art (D-1, D-2, D-5, D-6 in `PRIOR-ART.md`).** systemd's
> hard-won lesson is that **ordering and requirement are orthogonal** — a real
> edge usually *combines* them (the canonical `Wants=`+`After=` pair), so an
> edge is a **product**, not a flat sum. And the requirement axis is a
> *gradient*, not one `Requires`/`BoundTo` pair.

```purescript
-- An edge in the DEPENDENCY graph. Ordering ⟂ requirement — both optional,
-- and a real edge commonly asserts both.
type DepEdge =
  { from        :: ServiceId
  , to          :: ServiceId
  , ordering    :: Maybe Ordering
  , requirement :: Maybe Requirement
  , provenance  :: Provenance         -- inferred from dataflow, or hand-declared
  }

data Ordering = StartAfter | StartBefore           -- systemd After= / Before=

data Requirement
  = Wants                  -- best-effort; absent is OK         (systemd Wants=)
  | Requires Gate          -- hard; wait per the gate           (systemd Requires= + condition)
  | Requisite              -- must ALREADY be active; never auto-start (an external dep)
  | BindsTo                -- Requires + crash-coupling: I stop if it stops unexpectedly
  | PartOf                 -- reverse-only: its stop/restart propagates to me; its start does not

data Gate = OnStarted | OnReady | OnHealthy | OnCompleted   -- compose condition:* ; k8s gates

data Provenance = Declared | Inferred DataRef              -- Pulumi: most edges inferred from dataflow
data DataRef = ViaPort Port | ViaSocket AbsPath | ViaEnv EnvVar
```

- **Requirement gradient** (systemd): `Wants` (soft) → `Requires gate`
  (hard, waits) → `Requisite` (must pre-exist, never started by us — the
  honest model for an unmanaged external DB) → `BindsTo` (also dies on the
  upstream's *unexpected* stop) → `PartOf` (reverse-only lifecycle). Our v1's
  single `BoundTo` collapsed three genuinely different operational semantics.
- `Requires gate` is the only requirement that *waits*; `OnReady`/`OnHealthy`
  impose a readiness obligation on the upstream (§3.5) → the `UncheckableGate`
  check.
- **Provenance** (Pulumi): an edge derivable from one service referencing
  another's port/socket/env is `Inferred`; only genuinely external ordering
  is `Declared`. `validate` can warn on a `Declared` edge that duplicates an
  `Inferred` one.

**The reverse-proxy route is NOT a lifecycle edge** — it's a *data/traffic*
edge, and it lives in a separate graph (§3.6, D-5):

```purescript
type RouteEdge = { proxy :: ServiceId, backend :: ServiceId, path :: RoutePath }
```

A `RouteEdge` does not *by itself* imply ordering or requirement — but it
almost always co-occurs with an `Inferred (Requires OnReady)` dep edge
(a proxy should start after, and wait on, what it routes to). We derive that
companion dep edge rather than overloading one edge with both meanings.

### 3.5 Health — the readiness/liveness/startup split

```purescript
data Probe
  = HttpGet     { port :: Port, path :: String, expectStatus :: Int }
  | TcpConnect  Port
  | ExecCmd     (Array String)   -- compose test:[CMD,…]; k8s exec
  | ProcessAlive                 -- launchd KeepAlive; supervisord autorestart
  | SocketReady AbsPath
  | NotifyReady                  -- systemd Type=notify sd_notify READY=1
  | NoProbe

type Health =
  { liveness  :: Probe                                  -- restart trigger
  , readiness :: Probe                                  -- gates dependents; ≠ NoProbe to satisfy On{Ready,Healthy}
  , startup   :: Maybe { probe :: Probe, graceSec :: Int }  -- compose start_period; k8s startupProbe
  }

-- Enriched per D-E11: a base mode + portable extra conditions (launchd's
-- KeepAlive dict is richer than a flat enum). Backoff knobs alongside.
type RestartPolicy =
  { base       :: BaseRestart
  , conditions :: Array RestartCondition          -- empty = unconditional
  , backoff    :: { minSec :: Int, maxRetries :: Maybe Int }
  }
data BaseRestart = Never | OnFailure | Always | UnlessStopped
data RestartCondition
  = WhilePathExists AbsPath   -- launchd PathState (runtime); ≠ systemd ConditionPathExists (start-time)
  | WhileNetworkUp            -- launchd NetworkState
  | OnlyIfCrashed             -- launchd Crashed ; ≈ systemd Restart=on-abnormal
-- unmodeled KeepAlive keys ride in `extra` and are reported on lossy emit (DECISIONS.md D-E11)

-- Config references vs suppliers (D-E8): resolve ${VAR:-default} at validate.
data ConfigRef      = ConfigRef EnvVar (Maybe String)         -- referenced var + optional default
data ConfigSupplier = InlineEnv (Array (Tuple EnvVar String)) -- compose environment: / systemd Environment=
                    | EnvFile AbsPath                          -- compose env_file / systemd EnvironmentFile=
                    | ConfigMapRef String                      -- k8s
                    | SecretRef String                         -- presence tracked; value never read
```

The `backoff` knobs encode the real "launchd `ThrottleInterval` makes a
restarting service look dead for ~40s" gotcha — Bosun's `Status` can report
`InBackoff` rather than `Down`. A `ConfigRef` unsatisfied by any in-scope
`ConfigSupplier` and lacking a default is an `UnboundReference` at `validate`
(this subsumes the SDI "literal port must appear in the command" rule).

### 3.6 Selectors — the second edge type (Containment)

```purescript
data Selector
  = Profile     String   -- compose profiles:  ("core","minard","tidal","full",…)
  | Namespace   String   -- k8s
  | SystemdTarget String -- multi-user.target
  | Workspace   String   -- terraform
```

Selectors are the vision's *second edge type* over the same nodes —
membership, not dependency. The universal invariant: **a selector must be
closed under `Requires`** (if `minard-frontend` is in profile `minard` and
`Requires` `minard-backend`, then `minard-backend` must be in `minard`).
That single rule catches the compose "frontend-in-profile-without-backend"
bug, the kustomize "Deployment without its ConfigMap" bug, and the systemd
"target Wants a unit whose After-dep isn't pulled in" bug — *one type, three
tools' worth of footguns.*

> **THREE SEPARATE GRAPHS (D-5, Pulumi).** Bosun maintains three edge sets
> over the same nodes, and they must never be conflated:
> 1. **Dependency** (`DepEdge`) — ordering + requirement. *This is the only
>    graph that drives `BootOrder`; it is the only one we topo-sort.*
> 2. **Containment** (`Selector` membership) — organizational; **never
>    topo-sorted.** Topo-sorting containment is a category error that every
>    profile/namespace system invites.
> 3. **Data/traffic** (`RouteEdge`) — reverse-proxy routes; informs the route
>    table and an *inferred* companion dep edge, but is not itself ordering.

### 3.7 The loose ingested node, and the tight validated graph

```purescript
data Source = FromCompose | FromRegistry | FromPlist | FromSystemd | FromK8s

-- LOOSE / OPEN (D-4, CUE open structs): one per (source × unit). Edges point
-- at raw string names; `extra` carries every source field we don't model, so
-- ingest→emit can round-trip byte-for-byte (the differential test) WITHOUT the
-- IR pretending to understand `networks`/`volumes`/`deploy.resources`/labels.
type ServiceInstance =
  { source    :: Source
  , project   :: Maybe ProjectSlug
  , localName :: String                 -- "tidal-frontend" or "psd3-tilted-radio"
  , role      :: Role
  , host      :: Maybe Host
  , executor  :: Executor
  , exposure  :: Exposure
  , health    :: Health
  , restart   :: RestartPolicy
  , rawDeps   :: Array { to :: String, ordering :: Maybe Ordering, requirement :: Maybe Requirement }
  , rawRoutes :: Array { to :: String, path :: RoutePath }
  , selectors :: Array Selector
  , extra     :: Map String Json         -- unmodeled passthrough (CUE freeform); preserves round-trip
  }

-- TIGHT: minted only by `validate`. A ServiceRef is *proof* the id resolves.
newtype ServiceRef = ServiceRef ServiceId

newtype BootOrder = BootOrder (Array (NonEmptyArray ServiceRef))
  -- stages: across stages = ordered; within a stage = independent (the Go-concurrency seam)

newtype ValidatedDeployment = ValidatedDeployment
  { services  :: Map ServiceId Service                      -- edges resolved to ServiceRef
  , bootOrder :: BootOrder                                   -- existence ⇒ acyclic
  , routes    :: Map RoutePath ServiceRef                    -- every route backed; no drift
  , selectors :: Map Selector (NonEmptyArray ServiceRef)     -- non-empty; closed under Requires
  }
```

`ServiceRef` is constructible **only inside `validate`**, after the target
is proven present. Past that boundary a dangling edge is unrepresentable —
`plan` never has to handle "what if this points nowhere." `BootOrder`'s mere
existence is the acyclicity certificate.

**Open-ingest, closed-validate (D-4, the resolution of E9).** The loose
`ServiceInstance` is an *open* struct — `extra` keeps unmodeled fields so
emit can round-trip them byte-for-byte. `validate` unifies each instance
against a *closed* `#Service` shape; a field still sitting in `extra` that
`validate` was told to expect-empty becomes a reported `UnmodeledField`
(neither silently dropped nor silently kept). This is exactly CUE's
open-`{...}` / `close()` toggle, and it dissolves the lingua-franca-vs-
fidelity tension: fidelity lives in `extra` through the open phase; rigor is
imposed at the closed phase.

**Decoders model `Absent | Present a`, never silent default-fill (D-10,
Dhall's `omitNull`).** "field absent" and "field present-but-empty" can mean
opposite things (k8s `labelSelector`: absent ⇒ matches nothing; empty ⇒
matches everything); a decoder that defaults an absent field can invert
deployment semantics.

---

## 4. The pipeline

```purescript
ingest    :: Sources -> V Errors (Array ServiceInstance)   -- per-adapter parse; accumulate
reconcile :: Array ServiceInstance -> V Errors Deployment  -- group by identity; merge; drift-check
validate  :: Deployment -> V Errors ValidatedDeployment    -- tighten; topo-sort; close selectors; bind routes
plan      :: ValidatedDeployment -> WorldState -> Plan     -- TOTAL: desired − observed = changeset
apply     :: Plan -> Capabilities -> Result                -- the executor; Go owns concurrency
```

- `V Errors` (from `purescript-validation`) everywhere up to `validate`,
  because the brief is *"catch **all** the inconsistencies"* — accumulate,
  don't short-circuit. Collapse to `Either` only at the CLI boundary.
- **`reconcile` is a lattice meet, not last-write-wins (D-3, CUE).** Merging
  two sources' claims about one field is the semilattice *meet*: agreement
  unifies, disagreement yields an explicit `Conflict` value (CUE's bottom),
  *surfaced* — never silently resolved by priority. Because meet is
  commutative/associative/idempotent, **cross-source drift falls out for
  free**: drift is precisely non-idempotent re-meet. The merge is
  **type-directed** (D-11, NixOS): each field's type carries its strategy —
  a port `Conflict`s on disagreement, labels union, lists-of-records merge
  *by identity key* (never by position). We adopt NixOS's *taxonomy of
  strategies* but CUE's *report-don't-resolve* default, because Bosun's
  headline is drift detection.
- **Three-way state, not two (D-7, Terraform).** `plan` diffs three typed
  values, not two:
  ```purescript
  type WorldState =
    { desired  :: ValidatedDeployment   -- what the spec says
    , recorded :: Maybe Snapshot         -- last-known (Bosun's state file)
    , observed :: Snapshot               -- what sync probes see NOW
    }
  data Status = Running | Starting | InBackoff | Failed | Down | CompletedOk
              | Unknown Reason   -- probe couldn't tell; explicit, not coerced to Down (PRINCIPLES.md)
  type Snapshot = Map ServiceId Status
  ```
  Diffing only desired-vs-observed can't distinguish *"I changed the config"*
  (→ apply) from *"reality drifted underneath me"* (→ adopt/import) — they
  warrant different actions. `Status` is a rich enum, not a boolean:
  `InBackoff` is the "launchd `ThrottleInterval` looks dead for ~40s" gotcha
  (don't double-restart it); `CompletedOk` is success for an `OnCompleted`
  gate, not "down."
- **The rebuilder is verifying-traces (D-8, Build à la Carte).** A service's
  "value" is *running & ready*; the planner emits a `Change` only for the
  *stale* — and "stale" is decided by **hashing inputs+outputs**, not a dirty
  bit, because deployment reality drifts *out of band*. This is precisely
  `terraform plan` / a k8s reconcile pass.
- **The dependency graph stays applicative (D-9).** Boot order is derived
  from statically-known edges, so "proven-acyclic `BootOrder`" is a *real
  theorem*. Any edge whose existence depends on *observed runtime state*
  (a route to a discovered upstream) is the monadic case — quarantined in an
  explicitly-typed escape hatch, never allowed to pollute the static
  acyclicity guarantee.

```purescript
data Change = Start ServiceRef | Restart ServiceRef Reason | NoOp ServiceRef | Stop ServiceRef
newtype Plan = Plan (Array { stage :: Int, change :: Change })   -- carries BootOrder stages
```

`Plan` is a reviewable *typed ADT*, never an imperative one-pass reconcile.
`apply` consumes the staged plan: **within a stage**, changes are independent
and run concurrently (Go `errgroup`); **across stages**, ordered with
readiness gates between them. That is the one place real concurrency is
needed — and the one place we hand to Go (§6). The planner also reads
`BindsTo`/`PartOf` edges to propagate `Stop`/`Restart` *backward* (reverse of
boot order), as a transitive closure that terminates by acyclicity — the
algorithm is pinned in `DECISIONS.md` D-E5.

---

## 5. Reconciliation — the hard, interesting part

Ingestion yields a flat `Array ServiceInstance` in which *the same logical
service appears more than once under different names* (§7). Reconciliation
groups instances into logical `Service`s and checks the facets agree.

**Identity.** `ServiceId` is derived from the stable, rename-surviving
signal — `(ProjectSlug, Role)` when a Marginalia project is known, falling
back to a normalized name. The compose `tidal-frontend` and the registry
`psd3-tilted-radio` both resolve to the same `ServiceId` because both carry
project `psd3-tilted-radio` and role `frontend`.

**Facets (resolved in `DECISIONS.md` D-E3/E2).** One logical `Service` may
have several **deployment facets** — *(mbp, native, SDI-spawned)* and
*(macmini, container, behind edge)* are two legitimate ways to deploy the same
thing. The fields sort into three tiers:

- **Identity** `(ProjectSlug, Role)` — the grouping key; cannot differ.
- **Facet key** `(Host, ExecutorMechanism)` — *legitimately* differs across
  facets; it is *what a facet is*.
- **Facet-local** (port/exposure, restart, env, probe wiring) — differs freely
  *between* facets; must agree *within* a facet.
- **Must-agree across facets** — the **dependency shape** + service contract.

So "drift" splits in two: **facet divergence** (two facets differing on
facet-local fields — *expected, reported informationally*) vs **conflict**
(two sources describing the *same* facet that disagree, or contradictory
dependency shapes across facets — `CrossSourceDrift`, an *error*).

`reconcile` partitions each `ServiceId`'s instances by facet key, unifies
(lattice meet) *within* each facet, and meets the must-agree projection
*across* facets. A single-facet service has nothing to conflict with —
**absence of a facet is never drift** (opt into `expectedFacets :: Maybe (Set
FacetKey)` to assert coverage). This is the engine of the §7 demo and the
reason Bosun is more than a generator: it correctly tells *expected two-way
deployment* apart from *silent divergence*.

---

## 6. MISU — the two tiers, made concrete

Andrew's framing: *"there are often many more states than there are legal or
useful configurations."* The representable-state space of YAML+env is vast;
the legal one is small; the bad states surface only at deploy time. Bosun
shrinks the representable space to fit the legal one, in two tiers.

### Tier 1 — forbidden by construction (no representation)

| Illegal state | Forbidden by | Real tool that *allows* it |
|---|---|---|
| Launched two ways at once | `Executor` is a sum | (none enforces single mechanism across tools) |
| `image:` and `build:` both set | `Either ImageRef BuildContext` | docker-compose |
| Relative / missing cwd for a native exec | `AbsPath` smart ctor | SDI registry rows |
| Port outside 1..65535 | `Port` smart ctor | every YAML |
| A dependency edge pointing nowhere (past validate) | `ServiceRef` minted-present | compose, systemd, k8s |
| A dependency cycle (past validate) | `BootOrder` existence ⇒ acyclic | compose `depends_on`, systemd |
| Health probe on a `NoNetwork` service | `Health` lives inside port/socket-bearing `Exposure` variants | compose, k8s |

> **D-12 — Tier-1 in PureScript: no native GADTs, but the workarounds are
> easy and one *improves* on the prior art.** PureScript lacks GADTs, but the
> compile-time guarantees Propellor gets from GADTs + type-level MetaTypes are
> reachable here, on **two distinct paths that converge on
> `ValidatedDeployment`:**
>
> - **Ingestion path (YAML → loose → `validate`)** is necessarily *runtime*-
>   checked — data parsed at runtime can't carry compile-time tags — so here
>   Tier-1 comes from **smart constructors** (`mkPort`, `mkAbsPath`),
>   **phantom-typed proofs** (`ServiceRef` mintable only by `validate`),
>   **sums for mutual exclusion** (`Executor`, `Exposure`), **`Either` for
>   XOR** (`image`/`build`). This is the multi-source/drift path.
> - **Authoring path (a hand-written PureScript `.deploy` EDSL)** is where the
>   *type-level* guarantees live, Propellor-grade. The GADT workarounds:
>   - **Row types ARE type-level sets** — and this *fixes Propellor's own
>     stated wart* (Joey wanted a set but had an order-sensitive type-level
>     *list*). A service phantom-indexed by a row,
>     `Service (reachable :: Unit, hasReadiness :: Unit)`, with
>     `Row.Cons`/`Row.Union`/`Row.Lacks` constraints, models the metatype set
>     *natively*.
>   - **`type-equality`/Leibniz + final-tagless** for genuine GADT-style
>     refinement where a constructor must carry a proof.
>   Then the EDSL combinators enforce compatibility at compile time:
>   `routeTo` typechecks only if the backend's row has `reachable`;
>   `requiresReady`/`requiresHealthy` only if the upstream has `hasReadiness`
>   (so `UncheckableGate` becomes a *type error*, not a validate-time one);
>   `bindsTo`/`partOf` only between lifecycle-managed endpoints (never a
>   `StaticCDN` you don't control).
>
> So the `.deploy` DSL (the §10 "write vs reconcile-out-of-sources" question)
> answers itself: **authored** deployments are illegal-by-non-compilation;
> **ingested** ones are illegal-by-`validate`; both land in the same proven
> type. And the type-level layer erases cleanly for the Go backend (CoreFn
> input is already type-erased).
>
> **VERIFIED (spike, `purs` 0.15.15) — see `spike/`.** A zero-dependency
> spike confirms the rows-as-sets encoding: `routeTo`/`requiresReady`/`bindsTo`
> compile against compatible endpoints and are *rejected* against incompatible
> ones (route to a `NoNetwork` worker, gate on a probe-less upstream, co-life
> with a CDN), and `Lacks` makes double-adding a capability a type error —
> genuine set semantics, the property Propellor's type-level *list* couldn't
> give. Custom diagnostics via `Prim.TypeError` are a deferred polish.

### Tier 2 — caught by `validate` (representable loosely, absent from `ValidatedDeployment`)

These remain expressible in the loose `Deployment` (you can *write* them),
but `validate` refuses to mint a `ValidatedDeployment` containing them, so
they can never reach `plan`/`apply`. This is the `DeployError` ADT — **the
enumerated list of ways your deploy breaks at 3am**, each grounded in a tool
that ships the footgun:

```purescript
data DeployError
  = PortCollision           Host Port (NonEmptyArray ServiceId)
  | DanglingDependency      ServiceId String                        -- depends_on a ghost
  | DependencyCycle         (NonEmptyArray ServiceId)
  | EmptySelector           Selector
  | SelectorNotClosed       { selector :: Selector, svc :: ServiceId, missingDep :: ServiceId }
  | UncheckableGate         { gated :: ServiceId, upstream :: ServiceId, gate :: Gate }  -- On{Ready,Healthy} but readiness=NoProbe
  | RouteWithoutBacking     RoutePath                               -- comment says /sankey, nothing serves it
  | ServiceExpectsRouteButNone ServiceId
  | CrossSourceDrift        { svc :: ServiceId, field :: String, claims :: Array (Tuple Source String) }
  | UnboundReference        { svc :: ServiceId, var :: EnvVar }     -- ${VAR} no default, no supplier
  | SdiContractViolation    { svc :: ServiceId, why :: SdiViolation }  -- §7
  | UnparseableExecutor     { source :: Source, raw :: String }
```

The slogan writes itself: **"the dozen ways your deploy breaks at 3am — and
the half of them the compiler won't let you write."** That is the headline
showcase, and it's the distilled MISU before/after to fold into the polyglot
reference material.

---

## 7. The grounding case — Andrew's real, drifted system

Bosun's first target is not a toy. Pointed at the actual sources, the types
catch *real* bugs that exist *today*:

1. **Name/port/host/mechanism drift, registry ↔ compose.** The same
   logical services live in both sources under different identities:

   | Logical service | Marginalia registry | docker-compose |
   |---|---|---|
   | Tilted Radio frontend | `psd3-tilted-radio` @ **3013**, native/mbp, SDI | `tidal-frontend`, **no host port**, edge/macmini, profile `tidal,full` |
   | Minard API | `minard` api @ **3000** native | `minard-backend` **3000:3000**, profile `minard,full` |
   | EE API | `hypo-punter ee-api` @ **3020** | `ee-backend` **3020:3020** |

   Reconciliation (§5) groups them and reports the intended facet divergence
   vs the accidental drift.

2. **The SDI footgun, caught mechanically.** The registry's own SDI row is
   `node router.mjs` (port 3998) with **no `cd /abs`** — `mkAbsPath` returns
   `Nothing`, so the row can't even parse to a spawnable `Process`. That's
   `SdiContractViolation`, encoding the rule its own compatibility doc warns
   about (and the §2 rule "the literal port must appear in the command so
   SDI's rewrite has somewhere to land" → `UnboundReference`-adjacent).

3. **Stale, dead config.** The commented-out `anscombe` service points at
   `../visualisation libraries/…` — a directory name (with a space!) renamed
   long ago. Either model it or delete it; the type system won't let it rot
   silently.

4. **Under-specified dependency DAG.** compose declares only `edge →
   website`. `tidal-frontend` never says it `Requires` `tidal-backend`;
   `minard-frontend` never says it needs `minard-backend`. The healthchecks
   describe liveness but not *ordering*. Bosun forces the edges to be
   declared and then proves the DAG acyclic.

5. **Routes in a comment.** The edge route table (`/code → minard`, `/ee →
   ee`, `/sankey → …`) lives only in a compose header comment and the
   Scuppered-Ligature nginx config. Modelling routes as `RoutesTo` edges
   makes `/sankey`-without-a-backing (or a service expecting routing with no
   inbound route) a typed error.

**The atomic demo** (the vision's "minimal demo that proves the paradigm"):
ingest registry + compose + plists → reconcile (surface the drift above) →
`validate` → render the dependency DAG (Hylograph) + a status grid → `plan`
shows what would start → `apply` boots the polyglot showcases via os-exec in
`BootOrder` → emit a `docker-compose.yml` byte-identical to the hand-written
one. *One typed spec, every view and every target derived from it.*

---

## 8. The no-Aff seam

The PureScript→Go backend has no Aff yet, and Aff is explicitly post-MVP.
Bosun is architected so the MVP never needs it. The split is clean and
*principled*, not a workaround:

- **PureScript owns the pure core + synchronous I/O:** `ingest`,
  `reconcile`, `validate`, `plan`, all rendering, and synchronous probes
  (one HTTP GET, one TCP connect, one `launchctl list`). All of this is
  pure functions over data plus straight-line sync effects — the proven
  backend-go path (Map/Set, ADTs, record update, Generic, topo-sort = a TCO
  loop).
- **Go owns concurrency, and only concurrency:** `apply` runs each
  `BootOrder` stage as an `errgroup` (parallel within stage, ordered across,
  readiness gates between). This is Go's sweet spot and the reason a Go
  target is the *right* target for this tool, not an arbitrary showcase.

### Staging

1. **emit + validate + plan** — fully synchronous, differential-testable
   against the Phase-1 oracle. **This is the MVP showcase.**
2. **reconcile via os-exec** — sequential `apply`; still no concurrency.
3. **SDI-style lazy-spawn router** — concurrent; deliberately the stage that
   hits the `_lazy`/`_force` thunk thread-safety roadblock (fix:
   force-warm before serving, or a `sync.Once`/mutex per thunk). A *post-MVP*
   chapter, and a real one — it's the next thing the backend has to learn.

---

## 9. Scope

**MVP (gates backend-go's MVP):**
- adapters: ingest compose + Marginalia registry + launchd plists; emit
  compose.
- `reconcile` with cross-source drift detection.
- `validate` → `ValidatedDeployment` with the full `DeployError` set.
- views: dependency DAG (Hylograph) + status grid.
- `plan` (sync). `apply` sequential via os-exec for the polyglot showcases.
- differential test: emitted compose byte-identical to hand-written.

**Post-MVP / breadth (where the panoply pays off):**
- adapters: systemd, k8s manifests, Procfile, Terraform-state ingest.
- `apply` concurrency (Go errgroup) + the SDI lazy-spawn router (Stage 3).
- `Rollout` strategies (rolling / blue-green / canary).
- continuous reconcile loop (controller-style), not one-shot.
- secrets/config providers beyond plain env.

---

## 10. Open questions

- **Identity when no Marginalia project exists.** Name normalization is
  fragile; is a small hand-maintained alias map (`tidal-frontend ↔
  psd3-tilted-radio`) acceptable for MVP, or should reconciliation be
  interactive (propose-merge, human-confirm — itself a ShapedSteer
  executor)?
- **How much of the edge config to ingest.** Routes-as-comments vs parsing
  the actual Scuppered-Ligature nginx/lua. MVP: model routes in the Bosun
  spec, *emit* the edge config; don't ingest it yet.
- **`Role` openness.** Closed ADT (safe, must-extend) vs `WellKnown | Other
  String` (won't foreclose). Leaning open with a known-set.
- **One spec file vs derive-from-sources.** Is the Bosun `.deploy` DSL a
  thing you *write*, or only ever *reconciled out of* existing sources? The
  ambitious answer is both: ingest to bootstrap, then the typed spec becomes
  the source of truth and the old files become emit targets.
