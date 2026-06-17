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

> **k8s / docker / terraform / BEAM, as Jane Street would have built them.**
> One typed core; composition is *algebraic*; enactment is *one* command algebra
> with many interpreters; the same `validate` runs in the control plane and on
> every agent; failure is a *value*, not an exception.

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
--   DryRun   — pure; plan preview + the conformance columns
--   LocalExec— os-exec / docker / launchctl on this host  (the agent)
--   SshRemote— ssh-wrap to a host                          (the bootstrap, today)
--   BeamNative — OTP supervisor / process introspection    (Stage 3)
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
| Agent upgrade / the bootstrap problem | ssh `apply` re-deploys the agent; agent self-update is a deployment like any other | §7 |
| The latency tail itself | §3.3 combinators on both `apply` and `observe` | design |

## 6. The BEAM card

The Erlang column is not just a third conformance target — it is a **distribution
substrate the other columns can't match**. `bosun-core` on purerl + distributed
Erlang gives agents that form an **OTP cluster natively**: node discovery,
monitors, supervision trees, and message passing are the runtime, not a library
we write. The control↔agent mesh could *be* the BEAM node mesh; failover could
ride OTP supervision (`one_for_all`/`rest_for_one`/`one_for_one` — already mapped
to Bosun's requirement gradient in `BEAM-OBSERVER.md`). This is a genuinely
special option no ssh/Go-only design has. Caveats: it pins those agents to the
purerl runtime, and BEAM distribution has its own security model (cookies / TLS
distribution) to take seriously. Treat as the elegant endgame for the hosts that
warrant it, with the Go agent as the universal floor.

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

1. **The consensus boundary — the sharp one.** A join-semilattice / CvRDT (§3.1)
   gives eventually-consistent *state aggregation*. It does **not** give
   *coordination*: "exactly one primary," leader election, a single-writer lock —
   these are CAP-limited consensus problems a CvRDT *cannot* solve under partition.
   So `Alternative` failover (§3.2) is clean for *picking the first healthy
   member*, but "ensure exactly **one** member is *the* primary" is a different,
   harder problem. We sidestep it for **desired** state by making **git the sole
   writer** (one totally-ordered writer ⇒ no split-brain on intent). But *runtime*
   coordination still needs a real primitive — a lease, or a consensus library, or
   — elegantly — the **BEAM's built-in `global` / leader-election** (one more
   reason the Erlang column is special, §6). The claim "the merge is the consensus"
   holds for aggregation and **must not be overextended to coordination.**
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

The discipline: **the algebra earns the right to be simple by deleting accidental
complexity, not by pretending the essential complexity isn't there.** Where we
meet (1)–(5), we solve the *essential* problem — with types, with the smallest
honest primitive (a BEAM lease beats a bespoke Raft) — and we stay suspicious of
any solution that looks like it grew the baroqueness back.
