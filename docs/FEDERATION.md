# Bosun — Federation & scale

Status: **DESIGN / thinking** (2026-06-17, Andrew + engine session). The
architecture for *remote and multi-host* enactment — how Bosun starts and keeps
things running on machines other than the one it's invoked from — and how that
generalises, without becoming baroque, to genuine Enterprise / hyperscale.

Companion to `PRINCIPLES.md` (the two edges, all-uncertainty-at-the-edges),
`DESIGN.md` / `DECISIONS.md` (the typed core, `reconcile = lattice meet`),
`BEAM-OBSERVER.md` and `CONTROL-SURFACE.md` (the resident surfaces), and the
`ROADMAP.md` Stage-2 `supervise` work, which is the first rung of this ladder.

## 0. The brief

Design for **"The Tail at Scale"** (Dean & Barroso, CACM 2013) — the regime
where you fan out to thousands of nodes and the *slowest* of N becomes the common
case — **and prove that target can be serviced by something that is NOT baroque.**
k8s + Helm + Terraform + Kustomize + operators is the cautionary tale: a pile of
non-composing, stringly-typed subsystems, each dimension of scale bolted on
separately. The thesis here:

> **The engineering taste of k8s / docker / terraform / BEAM, as Jane Street
> would have brought it.** One typed core; composition is *algebraic*; enactment
> is *one* command algebra with many interpreters; the same `validate` runs in the
> control plane and on every agent; failure is a *value*, not an exception.

**What this is — and what it is NOT.** It is **not "an FP version of k8s."** That
framing would smuggle in k8s's *ontology* (Pods, Services, the container-and-
cloud-microservices worldview) and its *scope* (orchestrating web services in a
datacenter). Bosun is a **generic substrate for distributed process management**:
*any* process, *any* executor (container, launchd/systemd, a raw `nohup`'d
process, a BEAM-internal child), *any* host, *any* runtime. k8s's domain —
containers at cloud scale — is **one specialisation** of that substrate; the
eurorack live-coding rig (es9-daemon, link-spike, purerl-tidal), the homelab, the
dev-service router (the SDI replacement), and BEAM-internal voices are others.

This is the place for cold-eyed realism: **a general hostility to k8s's
*accidental* complexity does not preclude stealing its best *ideas* — it would be
stupid to do otherwise.** k8s solved real problems and some of its techniques are
excellent (level-triggered reconcile, a tiny consensus kernel under a big
eventually-consistent layer, leases for leader election — see §11). We steal the
**techniques**, not the **ontology**, and we apply them to the *general* problem,
not k8s's slice of it.

The discipline this doc imposes on itself: **confront every extra dimension of
Enterprise scale now, in the type design, even though the homelab implementation
is small** — so that when (if) we tackle real scale there is no hidden tech debt.
We must *feel* the pain points (multi-region, replication, failover, rollout,
partition, RBAC, secrets, drift, the latency tail) against the types, and show
each has a principled handle, before claiming the design scales.

We deliberately do **not** pay for scale we don't have. The point is that the
*same* algebra serves two hosts or two thousand; you turn a dial, you don't
re-architect.

## 1. Two topologies (and a k8s clarification)

**Agentless / push** (what `apply` does today): the control node holds the plan
and `ssh`'s into each host to run its native tools (`docker compose up`,
`launchctl`, …). Ansible's model.

**Agent / federated** (the target): every host runs a long-lived Bosun daemon
that owns *its slice* of the typed model, enacts **locally** (no remote shell),
and reports state. A control plane — or a peer mesh, or signed git — holds
desired state.

A clarification that *validates the federated instinct*: the "ssh in and run
`kubectl`" most people remember from k8s is the **human access path** (ssh to a
bastion, then `kubectl` talks to the API server). k8s's actual orchestration is
**agent-based** — every node runs a `kubelet` that pulls its pod-specs from the
control plane and enacts them locally. Nobody ssh's anywhere to start a
container. Federated Bosun is the k8s-*native* model, minus the baroqueness.

## 2. Security: a typed capability beats a shell

The worry "isn't a federated agent a bigger attack surface than ssh?" inverts
under scrutiny.

- **ssh is the broadest capability there is**: "run *any* command as this user on
  this host." A compromised control node ⇒ arbitrary remote code execution
  everywhere; you concentrate god-mode on one box. Forced-commands and restricted
  users narrow it, but the primitive is "arbitrary execution."
- **A federated agent grants only what its *protocol* admits.** If the agent
  accepts only a **validated (and signed) `Deployment`** and reconciles its
  host's slice — never arbitrary shell — then a compromised control plane can
  only ask agents to "run services that typecheck against the model." The blast
  radius is bounded by the agent's *vocabulary*, not by `/bin/sh`.

This is the thesis again: **the typed deployment IS the wire protocol**, and an
agent that refuses anything that doesn't `validate` (or isn't signed) is *typed
admission control at the edge*. The residual cost is authenticating the
control↔agent channel — and the homelab already runs on a **Tailnet**, which
hands us per-node WireGuard identity, encryption, ACLs, and NAT traversal for
free. "Federated Bosun over Tailscale" inherits the hard network-trust parts; at
larger scale the same role is played by mTLS + a node-identity CA.

Net: **federated, done right, is *more* secure than ssh** — a narrow typed
capability instead of a remote shell. ssh remains, but only as bootstrap (§7).

## 3. The algebraic core — the anti-baroque weapon

k8s is baroque because it has no unifying algebra, so every dimension is a
bespoke controller. Bosun's bet is that a small number of standard structures
make scale *more of the same fold*. This section is the heart of the doc.

### 3.1 Reconciliation is a bounded join-semilattice — and that one fact scales it

`reconcile` is already specified as a **lattice meet with explicit `Conflict`**
(D-3, CUE-style: report, don't silently resolve). Read algebraically:

```purescript
-- merge is commutative, associative, idempotent — a bounded semilattice,
-- into a conflict-surfacing carrier (Validation/These), NOT a naive lattice.
(<>) :: Deployment -> Deployment -> V (Set Conflict) Deployment
```

Those three laws are *exactly* the load-bearing ones at scale:

- **Associative + commutative ⇒ free sharding & re-merge.** Merging 2 config
  sources, 2 facets of a service, or 2 000 agents' state reports is the *same*
  fold. You may partition the work across machines and re-combine in any order.
- **Idempotent ⇒ re-apply is safe.** Convergence is just "re-meet until fixed
  point"; a duplicated or replayed report changes nothing.
- **The CRDT laws ARE the semilattice laws.** A state-based CRDT (CvRDT) is
  precisely a join-semilattice with a monotone merge. So the *same* operation
  that unifies your two local config sources is what makes a **distributed,
  partition-tolerant, eventually-consistent world-state** — agents gossip their
  observed slices, the join reconciles them, no central consensus engine
  required. **You do not build a separate consensus system; the merge IS the
  consensus.**

The honest twist vs. textbook CRDTs: CRDTs *auto-resolve* (LWW, etc.); Bosun
*surfaces `Conflict` as a value* and refuses to invent a resolution. That is the
typed-honesty version — eventual consistency where it's safe, a reported conflict
where agreement is genuinely absent (cf. the facet model D-E3: facet-divergence
is fine, dependency-shape disagreement is an error).

### 3.2 Failover is `Alternative`

A replicated/failover cluster is a set of service instances combined with the
choice operator:

```purescript
cluster :: Service          -- the live one
cluster = primary <|> standbyA <|> standbyB     -- first healthy wins
-- empty  =  no instance up  =  outage
```

The orchestrator's failover job is exactly: **maintain the invariant that the
`<|>`-fold is not `empty`** (≥1 healthy member). Rolling failover is
re-associating the `<|>`. Anti-affinity is a *typed constraint on the branches*
(the `<|>` alternatives must inhabit distinct failure domains — §5). A replica
set is naturally `NonEmpty Service` under a choice that prefers
healthy-and-nearest. This is the FP reframe Andrew teased, and it is not a
metaphor: `<|>` with a health predicate is the failover policy.

Hedging and "tied requests" (the Tail-at-Scale latency tools) are the *same*
operator with a clock: `primary <|> (after 20ms *> standbyA)` — issue the backup
only if the primary is slow, take the first to answer, cancel the rest.

### 3.3 Fan-out is Traversable over a *pluggable* Applicative

Applying a deployment to N hosts, or gathering state from N agents, is a
traversal:

```purescript
apply   :: Deployment -> f (Map Host Result)        -- traverse hosts
observe :: Set Host    -> f WorldState               -- traverse + semilattice-merge (§3.1)
```

The Applicative `f` is the **scale knob**, and the "Tail at Scale" techniques
become *choices of Applicative*, not rewrites:

| `f`            | behaviour                                  | Tail-at-Scale tool        |
|----------------|--------------------------------------------|---------------------------|
| `Identity`     | sequential                                 | (baseline)                |
| `Parallel`     | concurrent fan-out                         | basic scatter/gather      |
| `Hedged`       | re-issue stragglers past a deadline        | hedged requests           |
| `Tied`         | issue to k, cancel losers                  | tied requests             |
| `Quorum k n`   | succeed on k-of-n; "good enough" world view| partial / good-enough     |

Same program, swap the Applicative, get tail-tolerance. This is the move k8s
cannot make because its fan-out is hand-rolled per controller.

### 3.4 One command algebra, many interpreters

The agent's effectful vocabulary is a *small typed algebra* — start, stop, probe,
report — and `apply`/`observe` are programs *in* it. Enactment is a choice of
**interpreter**:

```purescript
class Monad m <= MonadDeploy m where
  enact  :: StagedCommand -> m Result
  probe  :: Probe         -> m Status
-- interpreters:
--   DryRun     — pure; plan preview + the conformance columns
--   LocalExec  — os-exec / docker / launchctl on this host  (the agent)
--   SshRemote  — ssh-wrap to a host                          (the bootstrap, today)
--   BeamNative — OTP supervisor / process introspection      (Stage 3, §6)
--   ProviderApi— reconcile a managed target via its API      (CDN/DNS/…, §7a — the Terraform leg)
```

This is the **no-Aff seam generalised**: one pure program, interpreted into ssh
*or* a local agent *or* the BEAM, with **zero per-environment code duplication** —
the structural reason Bosun doesn't fork into the dozen-tools mess. (Note: the
node-vs-Go *conformance columns* are already two interpreters of one pure program;
this just names the pattern and extends it across runtimes and transports.)

Final-tagless (`MonadDeploy`) is the pragmatic encoding in PureScript; a `Free`
`Command` ADT is the reified alternative. Either keeps **time and I/O at the
edge** (§3.6).

### 3.5 Desired state is a signed, mergeable value (GitOps, not a mutable store)

Desired state lives in **signed git**, not a central mutable database. Each agent
**pulls, validates, and reconciles its slice**. Why this is the principled choice:

- No central mutable store to compromise or to be a SPOF (cf. etcd's operational
  weight); the audit trail is git history; rollback is `git revert`.
- Validation happens **at every agent** — the typed admission control of §2 is
  distributed, not a control-plane bottleneck.
- The desired state is itself a **mergeable value** (§3.1), so multiple authors /
  overlays / per-team fragments compose by the same meet.

The control plane (if any) becomes a *cache and a view*, not the source of truth —
which is exactly how you avoid the k8s API-server-as-bottleneck shape.

### 3.6 Where time lives

`GRAPH-GRAMMAR §14` already found that the extra dimension over a static topology
is **time**. At scale the orchestrator is irreducibly temporal: rollouts, drift,
failover, hedging, backoff. The design keeps the **core timeless** — `plan` is a
pure function of `desired × observed`, `reconcile` is a fold — and admits time
*only at the resident `supervise` loop's edge*, i.e. inside the interpreter
(§3.4). The algebra stays pure; the clock stays at the seam. That separation is
what lets the same `plan` be unit-tested, dry-run, conformance-diffed, AND run
live under a 1.5 s watch loop.

## 4. Architecture

```
   signed git (desired state, mergeable §3.1)
        │  pull
        ▼
  ┌───────────── per host ─────────────┐        ┌──────── per host ───────┐
  │ bosun supervise  (the AGENT)        │  …N…   │ bosun supervise          │
  │  observe → plan → enact  (loop §3.6)│        │  (its own slice)         │
  │  MonadDeploy = LocalExec (§3.4)     │        │                          │
  │  exposes /state + /control (CONTROL)│        │  exposes /state+/control │
  └───────────────┬─────────────────────┘        └────────────┬────────────┘
                  │  state report (CRDT join §3.1)             │
                  └───────────────► control plane / Chair ◄────┘
                         (a CACHE + a VIEW, not the source of truth)
            all channels over Tailscale (identity+crypto §2);
            BEAM column optionally over distributed-Erlang (§6)
```

The agent **is** `bosun supervise` (Stage 2) with `MonadDeploy = LocalExec`. The
north interface is the Chair's existing `/state` + `/control` surface — already a
control-plane API shape (see `CONTROL-SURFACE.md`, `HANDOFF-CHAIR.md`). The Go
binary is the **ideal agent**: one static native file, drop it on any host, no
runtime to install (the file-driven Go `apply` we built is the seed of this).

## 5. The Enterprise dimensions — confronted now (no hidden debt)

Each row is a pain point of real scale and its *typed/algebraic handle*. The
claim is not "all built" — it's "each has a principled home in the existing
model, so none becomes a bolted-on subsystem later."

| Dimension | Handle | Status |
|---|---|---|
| Multi-host | facet key `(Host, Mechanism)` | **modelled** (D-E3) |
| Placement / failure domains / AZ spread | `Placement` + anti-affinity as a constraint on `<|>` branches; "interrogate, don't place" | partial (`PLACEMENT-TYPE.md`, GRAPH-GRAMMAR §14) |
| Replication & failover | the cluster as `<|>`; invariant: fold ≠ `empty` | **design** (§3.2) |
| Rollout (canary / blue-green / rolling) | a typed strategy *over* the replica set; canary = a probed `<|>` branch promoted on health | open |
| Desired-state distribution & consistency | signed git + semilattice merge (§3.1, §3.5) | design |
| World-state at scale | CRDT join of agent reports; `Quorum` view (§3.1, §3.3) | design |
| Convergence tail / stragglers | `Hedged`/`Tied` Applicative; idempotent re-meet; per-stage deadlines | design (§3.3) |
| Drift & continuous reconcile | the `supervise` loop, per agent | Stage 2 |
| Identity / RBAC | per-node cert (Tailscale/mTLS); "who may author desired state" = git signing | design |
| Secrets | presence-tracked refs, value never read | **modelled** (D-E8) |
| Partition tolerance | agent keeps reconciling its last-known *signed* desired state; fail-safe, no split-brain writes (git is the only writer) | design |
| Multi-tenancy / others' machines | trust boundary = which signing keys an agent honours | open |
| Managed targets (CDN / DNS / object store) | `StaticCDN` executor + `Published Domain` + `CompletedOk`; agentless, reconciled via a `ProviderApi` interpreter (§7a) | **types present**, enactment stubbed |
| Agent upgrade / the bootstrap problem | ssh `apply` re-deploys the agent; agent self-update is a deployment like any other | §7 |
| The latency tail itself | §3.3 combinators on both `apply` and `observe` | design |

## 6. The BEAM — two distinct roles, don't conflate them

There are **two** entirely separate ways the BEAM shows up. They were blurred in
an earlier draft; keeping them apart matters, because one is the concrete
near-term goal and the other is speculative upside, and **the first does not
require the second.**

### 6A. BEAM as a thing Bosun *looks into* (the original goal — Stage 3)

The motivating want: **see and manage the sub-processes *inside* a BEAM app**,
rather than treating it as one opaque box. purerl-tidal runs a per-voice OTP
supervision tree; today Bosun sees it as a single leaf node. The goal is to see
*inside* — voices appearing/vanishing as you live-code, click-to-restart a voice.
This is ROADMAP **Stage 3** / `BEAM-OBSERVER.md`, with two flavours:

- **A1 — self-report.** purerl-tidal emits its supervision tree as JSON over its
  existing WS verb surface; Bosun ingests it as just another *observe source*; the
  node deepens from a leaf into a sub-supervisor. **Bosun stays on node/Go — it
  never runs on the BEAM.** A small change in the *purerl-tidal* repo; nothing
  else needed. **This is the concrete, cheap, near-term target.**
- **A2 — native introspection.** `which_children` / `process_info` directly,
  control via `supervisor:restart_child`. Generic, no self-report — but needs a
  Bosun *foothold* on the BEAM (edge FFI), i.e. a sliver of 6B.

Here the BEAM is the **observed subject**, not Bosun's runtime.

### 6B. BEAM as *Bosun's own runtime* (the bigger leverage — optional endgame)

`bosun-core` compiled via purerl so the **agents themselves** are BEAM nodes and
inherit distributed Erlang: node discovery, monitors, supervision trees, message
passing as the *runtime*, not a library we write. The control↔agent mesh could
*be* the BEAM node mesh; failover could ride OTP supervision (`one_for_all` /
`rest_for_one` / `one_for_one` — already mapped to Bosun's requirement gradient in
`BEAM-OBSERVER.md`). A genuinely special option no ssh/Go-only design has.

**The narrowest, highest-value slice of 6B is the consensus primitive** (§11.1):
the BEAM's built-in `global` / leader-election is exactly the small coordination
kernel the semilattice can't provide — and you can adopt *just that sliver*
(a coordination foothold) without recompiling all of Bosun to the BEAM.

Caveats: 6B pins those agents to the purerl runtime, and BEAM distribution has its
own security model (cookies / TLS distribution) to take seriously. Treat 6B as the
elegant endgame for the hosts that warrant it, with the **Go agent as the
universal floor** and **6A (A1) as the thing to build first.**

## 7. The bootstrap ladder — ssh doesn't go away, it goes *first*

You don't choose agentless *or* federated forever; they compose:

1. **Agentless ssh `apply`** is the **floor and the bootstrap.** It needs nothing
   on the remote, so it is how you deploy the *first* thing to a fresh host —
   **including the Bosun agent itself** (`apply` over ssh installs and starts
   `bosun supervise`; the agent deploys the agent) — and the fallback for hosts
   you don't want to run an agent on.
2. **Federated agents** are the **steady state** for hosts you own: pull, validate,
   reconcile, report, all over Tailscale.
3. ssh's broad capability is therefore used *once*, at bootstrap; afterward you can
   retire the key and run purely federated, minimising the window in which the
   powerful credential matters.

Because enactment lives behind the no-Aff seam (§3.4) and the core is
host-agnostic, **you start agentless and add agents with no re-architecture** —
the same pure core, a swapped interpreter. That is the "don't pay for scale you
don't have, don't foreclose it" guarantee, made structural.

### 7a. Managed targets — the executor class that *can't* be federated (and the Terraform leg)

Not every deployable thing is a process on a host you own. A **static site on
Cloudflare Pages or GitHub Pages** is the sharp example, and it belongs squarely
in Bosun's remit — which is itself the strongest confirmation of the "generic
substrate, not FP-k8s" framing (§0): a Pages site has *no process, no port, no
host you can shell into*, yet it is the **same shape** — publish = `apply`, the
live URL = its address, an HTTP/content-hash check = its health, the build
artifact = its dependency. k8s would never include a GitHub Pages site; a generic
substrate for distributed process management naturally does. And it is *live infra*
already (`cloudflare-sites` pushes hylograph.net / blog / polyglot to Pages).

**The model already anticipates it** — only the enactment is stubbed:

- `Executor` already has `StaticCDN { provider :: CDNProvider, domain :: Domain }`
  (so Cloudflare-Pages vs GitHub-Pages is already a modelled distinction); today
  `apply` renders it `Manual "static-CDN publish (not automated)"`.
- `Reachability` already has `Published Domain` (`publicDomain`, openness
  `InternetWide`).
- `Status` already has `CompletedOk` — "a one-shot succeeded, not down."

So wiring it is *enactment, not architecture*: `wrangler pages deploy` /
a `gh-pages` push, behind the `StaticCDN` executor.

What makes it a **distinct class**, worth naming, is two honest differences:

1. **It's a managed target with no agent foothold.** You cannot run `bosun
   supervise` on Cloudflare's edge, so a `StaticCDN` service is *inherently*
   agentless/push (§1, §7): reconciled **via the provider's API**, from an agent
   *elsewhere* that holds the publish credential. This is the clean case that some
   executors *can't* be federated — and that's fine; they are reconciled through
   an API, not run on a host you own. (Contrast the ssh bootstrap, which is
   agentless-but-temporary; managed targets are agentless-*permanently*.)
2. **It's not a daemon.** "Up?" is `CompletedOk` **plus content-matches-desired**
   (hash the artifact against the live deploy — CDNs expose the deployed
   commit/hash via API, so it's genuinely observable), not "is a pid alive."
   Teardown isn't "stop a process" — it's *unpublish*, or better, **roll back to a
   previous deployment** (Pages keeps deployment history; rollback is a first-class
   CDN verb that maps cleanly onto `plan`).

**The horizon this opens — the Terraform leg.** Once you admit "reconcile a
resource via a provider's API," you've admitted Terraform's entire domain. A
`ProviderApi` interpreter (just one more `MonadDeploy` interpreter, §3.4, alongside
LocalExec / Ssh / BeamNative) gets you Pages — and then **DNS records, R2 buckets,
KV namespaces are the *same pattern*** (declare desired, observe actual via the
API, plan the diff, apply). So static sites are the gateway by which the *one
typed model* spans the **docker *and* terraform** legs of the
"k8s/docker/terraform/BEAM" framing — without a second tool, because it's the same
`reconcile → plan → apply` over a different executor and a different interpreter.

## 8. Frontier (where Andrew suspects this ends up)

- **Monoidal joins of docker configs** — §3.1, taken all the way: per-team config
  fragments, environment overlays, and host facets all compose by one meet; the
  build is a fold, incrementally recomputable.
- **`Alternative` instances for failover clusters** — §3.2 as a real typeclass
  instance, with hedging/tied/quorum as the lawful Applicatives of §3.3.
- A **`Rollout` as a comonadic walk** over the replica set (the view-from-here +
  `extend`), or a free strategy interpreted by the same `MonadDeploy`.
- The **whole thing dog-fooded**: Bosun supervising the Hylograph rig, the
  live-coding rig (Atlantis), and itself — a federation small enough to fit in a
  homelab and honest enough to scale.

## 9. Near-term, without foreclosing any of this

- Stage-1 MacMini deploy stays the right next act, now understood as the
  **bootstrap rung** (§7) — ssh `apply` of a containerised slice; nothing wasted.
- Stage-2 `supervise` is the agent's first incarnation (single host); the
  `MonadDeploy` interpreter split (§3.4) is the refactor that makes it so.
- The algebra (§3) is the thing to get *right on paper* before it's load-bearing:
  pin `reconcile`'s semilattice laws (already most of the way via D-3), and
  prototype the `Alternative` cluster + one non-trivial Applicative (`Hedged`)
  against the PBT harness, since "measured not asserted" is how this codebase
  earns its claims.

## 10. Questions

**Resolved (AC + engine, 2026-06-17): the topology.** Source of truth is **signed
git**; an **agent on every host**; the **Chair is a read-only aggregating view**,
not a control plane. No central mutable store. This is the §3.5 / §4 picture,
now a decision rather than a lean.

Still open:

- Identity & signing: Tailscale ACLs + git commit signing for the homelab; what's
  the larger-scale story (an org CA, SPIFFE-like IDs)?
- Conflict semantics across hosts at scale: when do divergent observed states get
  a `Conflict` vs. a tolerated facet-divergence? (Generalises D-E3 to the temporal
  case.)
- Does `Hedged`/`Tied` need real concurrency (Go/BEAM) or can a sync, deadline-
  driven approximation live in the no-Aff core? (Probably the former — and it's a
  good reason the *agent* is the Go/BEAM binary, not node.)

## 11. Essential vs. accidental complexity — what we'll still hit

The algebra (§3) is aimed squarely at k8s's *accidental* complexity: YAML
templating, the non-composing tool sprawl (Helm + Kustomize + Terraform +
operators), stringly-typed labels, per-resource controller duplication, a central
mutable store. Those we expect to *delete*. But some of k8s's complexity is
**essential — the problem domain's tax, not the tool's** — and intellectual
honesty (and "no hidden tech debt") means naming it now, so that when we hit it we
recognise it as the domain charging us, not as our design failing, and we pay it
with the same typed taste rather than reaching for k8s's accidental machinery.

The ones we should expect to meet:

1. **The consensus boundary — the sharp one, and there's a theorem behind it.**
   You can't *prevent* a partition; the only real design choices are what each
   side does *during* it and how you reconcile *on reconnection*. And whether that
   reconnection is clean is a **type property of the thing being merged** — stated
   precisely by the **CALM theorem** (Hellerstein): *a computation needs no
   coordination iff it is **monotone**.*
   - **Monotone / semilattice state** (desired config, observed-state aggregation,
     "the set of replicas that exist"): both sides stay available and writable
     through the partition, and reconnection is *just the merge* — associative,
     commutative, idempotent, so order of reconnection doesn't matter. **No
     coordination, ever.** This is Bosun's `reconcile` (§3.1); the partition is a
     non-problem here.
   - **Non-monotone decisions** (a choice that *invalidates other possibilities* —
     "this is *the* primary," "this unique action fired exactly once"): a merge
     can't fix it, because two partitioned sides may have made *conflicting
     irreversible* decisions. CAP bites; you must pick C or A.

   So `Alternative` failover (§3.2) is clean for *picking the first healthy
   member*, but "ensure exactly **one** member is *the* primary" is non-monotone
   and genuinely harder. We sidestep it for **desired** state by making **git the
   sole writer** (one totally-ordered writer ⇒ no split-brain on intent). But
   *runtime* coordination still needs a real primitive — a lease, a consensus
   library, or — elegantly — the **BEAM's built-in `global` / leader-election**
   (§6B). **The discipline: push everything you can into the monotone layer; spend
   consensus only on the irreducibly-singular decisions, and keep that surface as
   tiny as possible.** "The merge is the consensus" holds for *aggregation* and
   **must not be overextended to coordination.**
2. **Scheduling / bin-packing.** Auto-placing services across hosts under resource
   constraints is genuinely NP-hard; k8s's scheduler is complex because the problem
   is. Today our facets assign `Host` *explicitly* (hand-placed) — fine and honest
   at homelab scale, but the moment placement becomes automatic we inherit exactly
   this. The handle is to keep it a separable, typed optimisation over the model,
   not smeared through reconciliation.
3. **Resources, QoS, eviction.** Limits, noisy-neighbour, OOM/eviction — unmodelled
   today; essential at density. A `Resources` facet is a clean addition when needed.
4. **Rollout availability budgets.** "How many replicas may be down at once"
   (k8s PodDisruptionBudget) is a real constraint the `Alternative` cluster needs
   layered on — failover picks a healthy member; the *budget* governs how
   aggressively a rollout may remove members.
5. **Version skew.** You cannot upgrade N agents atomically; control-plane↔agent
   and agent↔agent version skew is essential at scale. The additive-only `/state`
   contract (D-S1) is the right instinct's seed; the general answer is schema
   evolution we design for, not against.

### 11a. What in k8s is *actually* coordination (and the rest isn't)

The pay-off of the CALM lens: most of k8s's "many nearly-the-same concepts" turn
out **not** to be coordination at all, which tells us exactly what's worth
stealing and what's just k8s's ontology.

- **Pod** — the scheduling / co-location unit. Essential complexity, but from
  *scheduling* (§11.2), not consensus.
- **ReplicaSet / Deployment / StatefulSet / DaemonSet** — the near-duplicates that
  feel redundant. They're not coordination; they're different *identity / lifecycle
  policies* over "a set of replicas": ReplicaSet = N interchangeable; Deployment =
  + rollout (§11.4); **DaemonSet = one per node** (literally our "agent on every
  host"); **StatefulSet = stable identity + ordered startup** — and *that* one
  brushes coordination, because stable identities are how you bootstrap a quorum's
  members. In Bosun terms these are the `Alternative` cluster (§3.2) + an identity
  policy + a rollout strategy — not new machinery.
- **Service / Endpoints / kube-proxy** — service discovery + load-balancing: the
  *read side* of `<|>` ("route to a healthy member"), the data plane. Not consensus.
- **etcd** — *this* is where k8s actually does consensus (Raft). One component.
- **Lease** — leader election, built on etcd's compare-and-swap, so exactly one
  controller-manager / scheduler is active. This is the minimal coordination
  primitive — k8s's version of "the smallest honest primitive."

And the deep one: **k8s controllers are level-triggered reconcile loops** —
idempotent, re-observe-actual-state-and-re-converge-to-desired, *not* edge-
triggered on an event stream. That is *precisely* "reconcile on reconnection,"
and *precisely* our semilattice fold (§3.1) — level-triggered is **why** a
controller survives a partition: it never needed to have seen every event, just
the current actual state.

**The punchline: k8s's own architecture is already "a tiny consensus kernel
(etcd + Lease) under a big eventually-consistent, level-triggered reconcile
layer (the controllers)."** That is the *same shape* this doc proposes — which is
reassuring, not embarrassing. Our improvements over it are exactly two: (a) the AP
reconcile layer is **one typed algebraic `meet`** instead of dozens of bespoke
stringly-typed controllers; and (b) we can choose a **far lighter consensus
primitive** for the kernel — a BEAM `global` lease — instead of standing up and
operating an etcd cluster. Steal the *shape* and the *techniques* (level-triggered
reconcile, the small-kernel/big-AP split, leases); leave the *ontology*.

The discipline: **the algebra earns the right to be simple by deleting accidental
complexity, not by pretending the essential complexity isn't there.** Where we
meet (1)–(5), we solve the *essential* problem — with types, with the smallest
honest primitive (a BEAM lease beats a bespoke Raft) — and we stay suspicious of
any solution that looks like it grew the baroqueness back.
