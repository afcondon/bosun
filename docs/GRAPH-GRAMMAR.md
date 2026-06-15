# Bosun — the deployment-graph visual grammar (Pillar 3)

> **Status: design stage.** This is the design dossier for Pillar 3 of Bosun's
> Chair — the Hylograph deployment-graph view. It is the rendering counterpart
> to `DESIGN.md`: where that document distilled a *typed* model out of the
> panoply of deployment tools, this one distills a *visual* model out of the
> same panoply. It is deliberately pitched **ahead of** the current engine —
> the explicit goal (Andrew, 2026-06-15) is to design a view that can render
> deployments *vastly* more complex than Bosun handles today (multi-host,
> replicas, rollouts, failover, cloud topologies, large graphs), so the view
> scales as the engine grows rather than being rebuilt each time it does.

---

## 0. The reframing — this is not "graphics-ify the tables"

The tables Bosun's Chair shows today (ingestion ladder, route table, boot
stages) are honest v0 scaffolding. The temptation for a "graph view" is to take
*those* tables and draw them as boxes-and-arrows: the service DAG with typed
edges, hosts as swimlanes, boot stages as layers. That is worth doing and it is
the floor of this design (§10) — but it is not the brief.

The brief is the same intellectual move Bosun already made once, applied to
rendering instead of typing. Bosun did not model docker-compose and then bolt
on systemd; it surveyed the **whole panoply** — compose, systemd, launchd, k8s,
Terraform, Procfile — found the *concepts they share and the distinctions the
richest of them draws*, and committed an IR that is the **intersection of what
they mean and the union of what they should forbid** (`DESIGN.md` §2). Every
tool became an adapter projecting onto that one model.

This document asks the parallel question for the picture:

> **What is the smallest set of visual primitives — positions, enclosures,
> edges, channels, glyphs — such that every deployment system is *just a
> binding* of its concepts onto those primitives?**

If we get this right, a docker-compose file, a Kubernetes namespace, a
Terraform plan, and an AWS account region are not four different diagrams. They
are one diagram with different axes populated to different densities. The graph
engine renders the *grammar*; each tool is an adapter that says which marks,
enclosures, edges and channels its concepts light up. That is the analog of
"every tool is an ingest/emit adapter onto the IR."

And it answers the visualization form of the xkcd-927 worry exactly the way
`FOR-DEVOPS.md` answers it for the format: a universal *renderer* gets **more**
useful the more heterogeneous your stack is (more structure to place on one
map), where a universal *diagramming format* would get less. We are building
the typechecker's "go to definition," not standard #15.

### 0.1 The governing conviction — use the plane (Tufte)

The conviction under everything here (Andrew, 2026-06-15): **current deployment
tools, and config files above all, commit Tufte's cardinal error — they fail to
use the resolution of the display.** A `docker-compose.yml` uses a
two-dimensional screen to show one-dimensional text: lines top-to-bottom,
characters left-to-right. The *plane* — the thing a display actually is — is
thrown away. A full page of YAML spends ~2000 glyphs to convey what a treemap
conveys at a glance and still has pixels to spare. This is not an aesthetic
complaint; it is the reason the graph view is the *point*, not a nicety: you
only earn the right to use the plane once the relationships are typed and
reconciled, so **the picture is the payoff of the parse.**

Minard (the code-cartography work) already proved the load-bearing claim
empirically: a *simple-ish two-level treemap* shows very large amounts of
information legibly on a laptop display, readable at both the macro level (the
shape of the whole) and the micro level (the individual cell) — Tufte's
micro/macro reading. We arrive at this design with graph-drawing algorithms,
several tree layouts (treemap, circle-pack, partition), Sankey/Chord/Adjacency,
and the decomposition skeleton all in hand. The data-density bar is therefore
high by default: **every view should justify its use of the plane against what a
treemap of the same data would achieve.** A box-and-arrow diagram that shows
twelve services where Minard shows hundreds has failed the test.

The specific Tufte principles this design leans on, named so they can be
checked: *use the plane* (data density), *micro/macro readings* (§7 semantic
zoom), *layering and separation* (§6 three channels), *the smallest effective
difference* (§4's one-channel-per-phenomenon discipline), and *small multiples*
(the scope/environment lens, §4.6). Chartjunk — decoration that isn't data — is
forbidden by construction: every channel in §4 is bound to a phenomenon in §2,
so there is no ink that doesn't mean something.

---

## 1. Method — distil a visual vocabulary from the panoply, the way the IR was

Bosun's type design has a reproducible method, stated in the memory and the
prior-art survey: *study the tools firsthand, let the richest one set the
vocabulary (systemd for edges), and forbid in the type what the loose formats
let you write.* We reuse that method, with a twist: the "richest tool" for
**structure** is not one tool — it is the cartographic tradition itself
(Minard, Humboldt, the grammar of graphics). The discipline is:

1. **Enumerate the abstract structural phenomena** that recur across the
   panoply (§2). These are graph-theoretic, not tool-specific: containment,
   ordering, requirement-strength, dataflow, multiplicity, redundancy, failure
   domains, scoping, liveness, provenance.
2. **Bind each phenomenon to exactly one visual channel** (§4), so two
   different phenomena never compete for the same ink. (The cardinal sin of
   real infra diagrams is that "arrow" means six unrelated things at once.)
3. **Forbid in the layout what the tools let you draw wrong** — e.g. you must
   not topo-sort a containment hierarchy (it has no order), and you must not
   route a lifecycle edge through the traffic graph. The three-graphs rule
   (`DESIGN.md` §3.6, D-5) is a *layout* law here, not just a type law.
4. **Let the loose picture always render and the tight picture appear on
   proof** — mirroring open-ingest / closed-validate. The messy
   pre-validation graph is always drawable; the proven-acyclic layered graph is
   the *reward* for a deployment that validates.

The rest of this dossier is that method carried out.

---

## 2. The abstract structural phenomena

These are the things that *exist* in deployment configuration, independent of
any tool's spelling of them. Each is a graph-theoretic shape. The point of the
list is that it is **closed enough to design a grammar against** and **open
enough to absorb tools Bosun has never seen.** For each: what it is, the
graph-theoretic shape, and where it shows up.

### 2.1 Containment — and it is a *lattice*, not a tree

Every system nests things. The trap is assuming the nesting is a single tree.
It is not: the same leaf is simultaneously contained by **several
independent hierarchies**, and they cross-cut.

| Hierarchy | compose | k8s | Terraform / AWS | systemd/launchd |
|---|---|---|---|---|
| **Logical / ownership** | project → service → replica | namespace → Deployment → ReplicaSet → Pod → container | module → resource; account → … | target → slice → service |
| **Physical / placement** | host → container | node → pod | region → AZ → subnet → instance → ENI | machine → process (cgroup) |
| **Failure domain** | (host) | zone / region / node | AZ → region → partition | (machine) |
| **Network scope** | compose network | ClusterIP / Service / NetworkPolicy zone | VPC → subnet → security group | (socket namespace) |

A Pod is in a Deployment (logical) **and** on a Node (physical) **and** in an
AZ (failure domain) **and** in a Service's endpoint set (network) — all at once.
Graph-theoretically, "is-contained-by" is a **DAG of containments**, often
presentable as several overlaid trees that share leaves. **This is the single
hardest problem in the whole design and §5 is devoted to it.**

### 2.2 Dependency & ordering — the DAG that earns the boot order

Directed lifecycle edges: "start A after B," "A needs B." This is Bosun's
first-class `DepEdge`, the *only* graph that is topo-sorted, and the source of
`BootOrder`'s proven-acyclic stages. Terraform's entire model **is** this DAG
(`terraform graph` emits it literally; resource references induce edges). k8s
initContainers and readiness gates, compose `depends_on`, systemd
`After=/Requires=` all land here. Shape: a **DAG** (cyclic only in the
pre-validation/loose view, where a cycle is a *finding*, not a render failure).

### 2.3 The requirement gradient — edges have *strength*, not just direction

systemd's hard-won lesson, already in the IR: an edge carries a *requirement*
on a gradient — `Wants` (soft) → `Requires gate` (hard, waits) → `Requisite`
(must pre-exist) → `BindsTo` (crash-coupled) → `PartOf` (reverse-only
lifecycle). This is **not** a second graph; it is an *attribute* of each
dependency edge, and the most under-served thing in every real infra diagram.
"Killing X took down Y at 3am" is a `BindsTo` edge nobody could see. The grammar
must make strength **visible at a glance** (§4.3).

### 2.4 Data / traffic flow — a separate edge family, often weighted

Reverse-proxy routes, Ingress host+path, k8s Service→Pod endpoints,
LB→target-group, DNS, security-group allow-rules, service-mesh virtual
services. Bosun's `RouteEdge` is the v0 member. Shape: a **multigraph**, often
**weighted** (traffic split 90/10 for a canary; LB across N backends), and
crucially **never a lifecycle edge** (D-5). It deserves its own visual channel
and, at scale, a flow/ribbon geometry — which the libs already supply
(`DataViz.Layout.Sankey.*`, cycle-aware and capacity-weighted; §4.4, §9).

### 2.5 Multiplicity — one declaration, N runtime instances

A *quantifier* on a node. `replicas: 3`, compose `deploy.replicas`, Terraform
`count` / `for_each`, an AWS Auto Scaling Group's desired/min/max. The
**declaration** and the **instances it expands to** are different graph nodes at
different levels of detail. The grammar needs a "cardinality" treatment that can
both **collapse** (one node badged ×3) and **explode** (three sibling nodes in
an equivalence hull) — this is a semantic-zoom decision (§6, §9).

### 2.6 Redundancy & failover — the reliability axis Bosun barely models today

This is what Andrew specifically called out and where the current IR is thinnest.
The recurring shapes:

- **Active-active behind a balancer** — a hub node (VIP / LB / Service) fans to
  an *equivalence set* of interchangeable backends. Shape: **star + equivalence
  class**.
- **Active-passive (primary/standby)** — DB replication, keepalived VIP, RDS
  Multi-AZ, Pacemaker. One member is hot, the rest armed-cold; a **replication
  edge** (a *third* lifecycle-adjacent edge family: state flows primary→standby)
  couples them. Shape: **directed pair/chain with a role attribute**.
- **Quorum** — etcd/Raft/ZooKeeper: N peers, tolerate ⌊N/2⌋ failures. Shape:
  **clique or ring with an "N-of-M" annotation**.
- **Anti-affinity** — "spread these across failure domains," "never co-locate
  these two." Shape: a **negative/repulsion constraint** between nodes, plus a
  *grouping by failure domain* they must spread across.
- **Failure domains** — AZ/region/rack/node as *blast-radius* grouping,
  orthogonal to the logical hierarchy (§2.1). Shape: a **partition** used to
  *check* that redundant members don't all sit in one cell.

Redundancy is mostly expressible as **subgraph motifs** (§8) over the existing
node/edge primitives plus two new ingredients: a **role** attribute
(hot/cold/quorum-member) and a **co-location/anti-affinity constraint** between
nodes.

### 2.7 Selection / scoping — the graph is *parameterized*

compose profiles, k8s namespaces + label selectors, systemd targets, Terraform
workspaces, Helm/Kustomize overlays, environments (dev/stage/prod). The same
base config yields *different graphs* under different scopes. Bosun models this
as `Selector`, the "second edge type" (containment-by-membership), explicitly
**never topo-sorted**. Visually it is a **lens/filter** plus a membership
grouping (§4.6).

### 2.8 State & health — the dynamic overlay (desired vs observed)

up/down/degraded/redirect/in-backoff; desired N replicas vs observed M ready;
rollout-in-progress; Terraform drift (config vs reality). Bosun already carries
the three-way `WorldState` (desired / recorded / observed) and a rich `Status`
ADT. This is a **temporal/comparative overlay** on the structural base —
precisely Minard's "casualties over the march." It must be a channel that can be
toggled *on top of* any structural layout, never a separate diagram.

### 2.9 Provenance & drift — the cartographic-source axis (Bosun's signature)

Every node and edge came from *some source* (compose / registry / plist /
systemd / overlay), and sources **disagree**. This is meta-structural: a node
may be one logical service with several **facets** (mbp-native vs
macmini-compose), and a field may **conflict** across sources. This is Bosun's
whole reason for being, and the graph is where it becomes legible: divergence is
a *split glyph*, conflict is a *visual collision*, provenance is a *texture*
(§4.7). No other deployment visualizer does this, because no other tool ingests
many sources at once.

### 2.10 Identity across facets — one logical node, many incarnations

The reconciliation output. One `ServiceId`, several `ServiceInstance` facets.
The graph must be able to show *both* the collapsed logical node (the map you
reason about) and, on demand, the exploded facets (the reconciliation you're
debugging) — another semantic-zoom axis, and the spatial bridge to Pillar 1.

---

## 3. The panoply, re-surveyed for *shape*

`DESIGN.md` §2 tabulated the panoply by *concept → type*. Here is the companion
table the visual grammar is derived from: **concept → graph-theoretic shape →
visual primitive.** This is the Rosetta stone that makes "one engine, every
tool" concrete. (Cloud rows added beyond Bosun's current IR — the future-proof
target.)

| Phenomenon (§2) | Graph shape | Where it appears | Visual primitive (§4) |
|---|---|---|---|
| Unit / service | node | all | **mark** (node) |
| Logical containment | tree | project, namespace, module, target | **enclosure** (primary) or layer |
| Physical placement | tree (cross-cuts logical) | host, node, AZ/subnet/instance | **enclosure** (secondary) / banding |
| Failure domain | partition (cross-cuts both) | AZ, region, rack, zone | **failure-domain banding** |
| Dependency / ordering | **DAG** | depends_on, After=, init, TF refs | **directed edge**, layered |
| Requirement strength | edge attribute | systemd gradient, compose condition | **edge weight / style** |
| Data / traffic | weighted multigraph | routes, Ingress, Service→Pod, LB | **traffic channel** (distinct hue, flow) |
| Multiplicity / replicas | quantifier on node | replicas, count, ASG desired | **cardinality glyph / explode** |
| Active-active | star + equivalence class | LB→targets, Service→Pods | **balancer hub + equivalence hull** |
| Active-passive | directed pair, role attr | DB primary/standby, VIP | **replication edge + hot/cold fill** |
| Quorum | clique / ring + N-of-M | etcd, Raft, ZK | **quorum ring annotation** |
| Anti-affinity | negative constraint | podAntiAffinity, spread groups | **repulsion / forbidden-pair mark** |
| Selection / scope | membership (2nd edge) | profiles, namespaces, workspaces | **lens + membership grouping** |
| Config / secret | reference edge | env, ConfigMap, Secret, TF vars | **reference channel** (faint), secret = locked glyph |
| State / health | overlay | observed status, drift | **status channel** (fill/pulse) |
| Provenance | node/edge texture | which source defined this | **origin hue / border** |
| Drift / conflict | annotation on node | cross-source disagreement | **split glyph / collision mark** |
| Rollout | temporal overlay | rolling/canary/blue-green | **time scrubber + ghost old/new** |

The leftmost column is closed (it is §2). The middle column is graph theory.
Only the rightmost column is design opinion — and it is small. That smallness is
the whole claim: **a dozen visual primitives cover the panoply.**

---

## 4. The visual primitive set (the grammar)

A grammar of graphics decomposes a picture into **data → geometry → aesthetic
channels → layout**. Here is the deployment-topology grammar, each primitive
bound to exactly one phenomenon (§2), and annotated with the Hylograph library
that supplies it (`✓` present, `△` partial, `✗` must be built — see §11).

### 4.1 Marks (nodes)

A node is a **service / resource**, or — at finer detail — a **facet** or a
**replica instance**. The mark carries several independent aesthetic channels,
and the discipline is *one channel per phenomenon*:

- **shape** ← executor mechanism (the `Executor` sum: process / container /
  systemd / launchd / CDN / remote / unmanaged / unix-socket). A container is
  not a CDN page is not an ssh-wrapped remote; the silhouette says which.
- **fill saturation** ← liveness/role: live=saturated, down=ghosted,
  cold-standby=hollow, in-backoff=hatched. (`Status` channel, §2.8/2.6.)
- **border hue / texture** ← provenance (which source), §2.9.
- **size** ← a chosen scalar (replica count, or `loc`-style weight, or "blast
  radius") — *optional*, off by default to avoid lying with area.
- **cardinality badge** ← multiplicity (×3), §2.5.

Libs: marks are plain HATS elements (`elem Circle/Rect …`) bound via `forEach`
over the node array — `✓`. The channels are just attribute closures.

### 4.2 Enclosures (containment)

Containment (§2.1) is drawn as **nested regions**. The library gives us the
hierarchy layouts directly:

- **circle-pack** (`DataViz.Layout.Hierarchy.Pack`) — nested circles, area ∝
  value. Best for "show me the whole estate at once, nesting visible." `✓`
- **treemap** (`…Treemap`, squarify/slice/dice) — space-filling, good for dense
  host/namespace inventories where every pixel counts. `✓`
- **icicle / partition** (`…Partition`) — rectangular or radial (sunburst);
  good when the *depth* of nesting is the story. `✓`
- **group blobs / region hulls** — a soft organic region drawn *around* an
  arbitrary node set that is positioned by some *other* layout (e.g. a region
  around the pods of one Deployment in a force layout). This is the keystone for
  §5, and it **exists**: `Onion.Watercolour` (`watercolourBlob`,
  `watercolourBlobHobbs`, edge-variance variants) turns a boundary polygon into a
  painterly region, and the **`graph-decomposition` demo already renders exactly
  this** — watercolour blobs around graph-decomposed components over a
  force-laid-out Les Misérables graph ("chimera" styles: Extracted / Chord /
  Spine / Orbital). `✓` The one helper not found by name is *convex-hull /
  boundary-polygon from a node set's positions* (the `Polygon` you feed
  `watercolourBlob`); `Onion.Shape` supplies shape *generators*
  (`regularPolygon`, `starShape`, `ellipseBlob`) but not a hull-of-points — so
  either the demo computes boundaries a way worth reusing, or this is one ~30-line
  Graham-scan to add (§11, the only real build item left).

### 4.3 Lifecycle edges (dependency + requirement gradient)

A directed edge in the dependency DAG (§2.2), styled by the requirement
gradient (§2.3). The binding:

| Requirement | stroke | arrowhead | meaning |
|---|---|---|---|
| `Wants` | thin, dashed | open | soft; absence is fine |
| `Requires OnStarted/OnReady/OnHealthy` | solid, weight ∝ gate strength | filled | hard; *waits* |
| `Requisite` | solid + a small "∅-start" tick | filled, hollow tail | must pre-exist; we never start it |
| `BindsTo` | **double / heavy** | filled + crash glyph | crash-coupled (the 3am edge) |
| `PartOf` | solid, **reverse chevron** | reversed | stop/restart propagates backward |

Ordering (`StartAfter`/`StartBefore`) is encoded by **layout direction** (the
layered DAG, §4.8), not by a second arrow — ordering and requirement are
orthogonal axes (a product, per the IR), and conflating them is exactly the
mistake the IR refuses to make. Provenance of the edge (`Declared` vs
`Inferred DataRef`) is a faint vs firm stroke.

Libs: edges are HATS `Line`/`Path` over the link array (`✓`); the gradient is
attribute closures. Curved/bundled routing via `…EdgeBundle` (`△`, radial
only).

### 4.4 Traffic channel (data/routes)

A *separate, toggleable* edge family (§2.4), different hue (say, blue where
lifecycle is graphite), entering nodes on a different port/side, and — at scale
— rendered as **weighted flow ribbons** (traffic split, LB fan-out). This
**exists and is rich**: `DataViz.Layout.Sankey.*` is a full weighted-flow layout
(`Compute`, `Path`, `Types`) with node-value strategies (`bottleneckNodeValue`,
`maxNodeValue` — capacity!), link colouring, alignment, *and* **cycle-aware
back-edge handling** (`detectAndRemoveBackEdges`, `classifyBackEdges`,
`CycleTopology`/`CycleAnalysis`) — so a route graph with a feedback loop lays
out cleanly. `✓` For dense many-to-many traffic (service mesh, full
adjacency) `DataViz.Layout.Chord` gives a chord diagram and
`DataViz.Layout.Adjacency` a labelled matrix. The rule from D-5 is a *hard
layout law*: the traffic channel never participates in the topo-sort and never
shares ink with lifecycle edges.

> **A gift from Sankey:** its layered left-to-right flow with proper back-edge
> detection is *also* a candidate renderer for the **dependency channel** and the
> **boot-order layering** — Sankey "depth" is a topological layer, and its
> back-edge classifier is precisely the loose-graph cycle finding (§13 Q3) for
> free. The traffic and lifecycle channels can share a layout engine while
> keeping separate ink.

### 4.5 Redundancy & failover idioms

Built from marks + edges + hulls + two new attributes (role, anti-affinity).
Catalogued as motifs in §8. The primitives they need:

- **balancer hub** — a distinguished mark (the VIP/LB/Service) with a fan to an
  **equivalence hull** (§4.2) around its interchangeable backends.
- **replication edge** — a third edge hue (state flow), primary→standby, with
  **hot/cold fill** (§4.1) on the members.
- **quorum ring** — a ring/clique drawn among peers + an "N-of-M" badge.
- **failure-domain banding** — background bands/hulls (§4.2) for AZ/region; the
  *check* is whether an equivalence set spans ≥2 bands.
- **anti-affinity mark** — a repulsion constraint in the force sim (push two
  nodes apart) and/or a "⊘ co-locate" annotation on the pair.

### 4.6 Lens (selection / scope)

Scope (§2.7) is an **interaction**, not a permanent mark: a scope chooser
(profile / namespace / workspace / environment) that **fades** out-of-scope
nodes and edges to near-zero opacity rather than removing them — so you *see*
"this profile pulls in these, leaves those dark," which is exactly the
`Selector` "closed under Requires" invariant made visible (a faded dependency of
an in-scope service is the bug). Membership itself can also be drawn as a
light hull (§4.2) when a scope is pinned.

### 4.7 Provenance & drift overlay

- **origin** ← border hue/texture per `Source` (§2.9).
- **facet explode** ← a logical node opens into its facets (§2.10), each facet a
  small mark inside the parent's hull, edges to the facet-key (host × mechanism)
  it diverged on. This is the spatial bridge to Pillar 1's ingestion ladder.
- **conflict** ← a `CrossSourceDrift` becomes a **collision mark** on the node
  (two half-discs in the conflicting sources' hues), with the field name; click
  → the claims (the existing `ConflictView`).
- **divergence** (expected multi-facet) vs **conflict** (error) are drawn
  *differently* — divergence is a quiet split, conflict is a loud collision —
  because the IR distinguishes them (DECISIONS E3) and the picture must too.

### 4.8 Layout (the spatial substrate)

Two layouts, chosen by whether the deployment validates — the visual form of
open-ingest/closed-validate:

- **Loose / always-on — force layout.** Draw the dependency graph from the loose
  `instances[].deps` (raw string targets, may dangle, may cycle). Force-directed
  (`Hylograph.ForceEngine`), because the loose graph is not provably acyclic and
  has no canonical layering. Dangling deps point at a "ghost" placeholder
  (that's the `DanglingDependency` finding, *seen*); cycles are visible loops
  (that's `DependencyCycle`, *seen*). This is the messy truth, and it always
  renders. (`✓`)
- **Tight / on-proof — layered DAG.** When `result` is `Valid`, the
  `bootOrder :: Array (Array String)` *is* a Sugiyama layering, computed and
  certified by the engine. Render it with `Data.Graph.Layout`'s `dagLayout` /
  layered tree (`△` — exists, no edge-crossing minimization yet), one rank per
  boot stage, independent-within-stage nodes side by side (the Go-concurrency
  seam, drawn as such). The tight graph is the *reward* for validating; its
  clean layering is visibly the payoff of MISU.

The transition loose→tight is an **animated relayout** (force settles into
layers) — the most satisfying single moment in the tool, and the literal
picture of "your config became provably correct."

---

## 5. The hard problem — multi-hierarchy containment

§2.1 is the crux. A node lives in several containment hierarchies at once
(logical / physical / failure-domain / network / scope), and you cannot nest it
inside all of them simultaneously without a hairball. Every real cluster
visualizer either picks one hierarchy and hides the rest, or draws a mess. The
Minard tradition has a better answer, and it is the architectural spine of this
view:

> **One hierarchy is *spatial* (the map you stand on); the others are
> *overlays* (hulls, banding, color) over that same map; and which hierarchy is
> spatial is a single swap the user controls.**

Concretely:

- Pick a **primary hierarchy** → it drives the *layout*. If primary = physical,
  nodes are packed/treemapped inside host→node→AZ regions and the logical
  grouping becomes hulls drawn *over* them. If primary = logical, nodes sit in
  namespace→deployment regions and the *physical* placement becomes
  banding/hull overlays. Same nodes, same edges; only the enclosure that is
  "load-bearing" changes.
- The **non-primary hierarchies render as group hulls** (§4.2, the `✗`
  build-item) — soft blobs around whatever node set shares a parent in *that*
  hierarchy, laid out by the primary. This is why hulls-over-arbitrary-layout,
  not just space-filling nesting, is the must-build primitive.
- **Failure domains are special**: they are the hierarchy you most often want as
  a *check overlay* regardless of what's primary — "are my 3 replicas in 3
  different AZs?" is answered by banding the current layout by AZ and seeing
  whether the equivalence hull spans bands. So failure-domain banding is a
  *toggle available in every primary mode.*
- The **swap is animated** (relayout), so you keep your mental place as the map
  re-projects — the same trick as loose→tight (§4.8).

This single interaction — *choose the spatial hierarchy, overlay the rest* —
is what lets one engine render a compose file (where physical ≈ logical ≈ one
host, so it collapses to a plain DAG) **and** a multi-region Kubernetes + cloud
estate (where the four hierarchies genuinely differ and the overlays carry real
information). It is the direct generalization of Minard's "one map, many data
layers" to deployment topology, and it is the reason the view can outrun the
engine: the *grammar* admits four hierarchies even while Bosun's *model* only
populates one or two today.

---

## 6. Three graphs, three channels — the layout law

`DESIGN.md` §3.6 / D-5: Bosun keeps **three edge sets over the same nodes** and
never conflates them — Dependency (the only one topo-sorted), Containment
(`Selector` membership, *never* ordered), Data/traffic (`RouteEdge`). In the IR
this prevents category errors. In the view it becomes a **layering law**:

- each graph is a **toggleable channel** with its own geometry (§4.3 lifecycle,
  §4.4 traffic, §4.2/§4.6 containment-as-enclosure), composed as separate HATS
  layers (`chart = containmentLayer <> trafficLayer <> depLayer <> nodeLayer <>
  overlayLayer`) — exactly the heterogeneous-layer Semigroup the libs encourage;
- **only the dependency channel drives the layout** (force or layered);
  containment is enclosure/banding, traffic is decoration over the dep-derived
  positions. Topo-sorting containment or routing is the category error the
  layout must structurally refuse;
- the channels are independently dimmable, so "show me only what *waits* on
  what" (dependency, gate-weighted) and "show me only traffic" are one toggle
  apart, over the identical node placement. The shared substrate is what makes
  the comparisons honest.

This is also semantic-zoom-friendly: at the furthest zoom, only enclosures +
heaviest edges (`BindsTo`, primary routes) draw; detail channels switch on as
you descend (§9).

### 6.1 The visual pivot table — and not losing the viewer

The right name for what §5 and §6 are doing together (Andrew, 2026-06-15) is a
**visual pivot table**. A pivot table re-aggregates the same cells along a
different dimension — drag a field from rows to columns and the *data* is
unchanged, the *projection* is new. That is exactly this view's two core
interactions: §5 pivots the **spatial** dimension (which containment hierarchy
is load-bearing — logical / physical / failure-domain), and §6 pivots the
**relational** dimension (which edge family you're reading — lifecycle /
traffic / containment). Same nodes throughout; only the question changes.

The whole risk of a pivot lives in one place: **the viewer must not lose their
place across the re-projection.** Drag the field and if every mark teleports,
the user's mental map shatters and they have to re-find "where's my database"
from scratch. The HCI answer is **object constancy** — animate the *same* marks
sliding from old position to new, so the eye tracks "that node is still that
node" *through* the transform (Heer & Robertson's animated-transition result).
It is why every pivot in this design — hierarchy swap (§5), loose→tight
relayout (§4.8), explode/collapse (§7) — is specified as an **animated
relayout of persistent marks**, never a cut to a fresh diagram.

> **This is the trial-and-error frontier.** Everything else in this dossier is
> derivable — the phenomena are graph theory, the channels are Tufte, the
> layouts exist in the libs. But whether a given pivot *reads* — whether
> swapping logical→physical lands as "aha, same estate seen differently" or as
> "everything jumped, where am I" — no theory predicts. It depends on transition
> timing, what stays fixed as the anchor, whether you stagger the motion, how
> much you fade vs move. This must be **built and watched**, iterated by getting
> lost and fixing what lost you. The design's job is to make the pivots *cheap to
> try* (persistent marks + one relayout function per projection), so the UX
> tuning has a fast loop. Expect strong opinions here only once it's on screen —
> that is the correct order.

---

## 7. Multiplicity & semantic zoom — collapse and explode

Real estates have hundreds to thousands of nodes; the grammar must degrade
gracefully, and the libs have **no semantic-zoom module** (`✗`, §11) — it is an
app-level discipline we design here:

- **Level-of-detail by containment depth.** Far out, render only top-level
  enclosures (regions / namespaces / hosts) as aggregate marks badged with
  counts and roll-up status (`k8s sum/count` on the hierarchy gives the
  aggregates, `✓`). Descend → enclosures open, child nodes appear, detail
  channels (traffic, config refs) switch on.
- **Multiplicity collapses by default.** `replicas: 3` is one node ×3, not three
  nodes — until you explode it (or until one replica's status diverges, which
  *auto-explodes* so the unhealthy one is visible). Same mechanism as facet
  explode (§4.7) and the active-active equivalence hull (§8).
- **Elision is never silent.** Anything collapsed or capped (top-N, "+42 more")
  is labelled, per the house rule that a view which hides work reads as "covered
  everything." A count badge is a promise, not a lie.

This is the mechanism by which the view "handles graphs vastly larger than
Bosun handles today": the *grammar* is LOD-native even though today's `/analyze`
returns ~50 services that all fit on one screen.

---

## 8. Redundancy & failover — the motif catalog

Failover is where deployment topology stops being a DAG and starts being a set
of **recognizable patterns**. The grammar renders each as a composition of §4
primitives. None of these requires new *geometry* beyond hulls + the role and
anti-affinity attributes — they are *idioms*, the way "passing loop" is an idiom
in signal-box. (Most are **post-MVP model work** for Bosun; the grammar is
designed so the engine can grow into them.)

1. **Load-balanced pool (active-active).** Balancer hub (mark) → equivalence
   hull around N interchangeable backends; traffic channel fans hub→members
   (weighted if split). Member down → its mark ghosts, hull stays (capacity
   degraded, not lost). *Maps:* k8s Service→Pods, LB→target group, compose
   `replicas` behind a proxy.

2. **Primary / standby (active-passive).** Two+ marks, one hot (saturated) one
   cold (hollow), joined by a **replication edge** (state-flow hue,
   primary→standby). Failover = the hot/cold fill swaps along the edge
   (animatable when status changes). *Maps:* RDS Multi-AZ, keepalived VIP,
   Postgres streaming replication, Pacemaker.

3. **Quorum cluster.** N peer marks in a **ring**, "N-of-M healthy" badge that
   goes amber at exactly ⌊N/2⌋+1 and red below. *Maps:* etcd, Raft, ZooKeeper,
   Consul.

4. **Spread / anti-affinity.** An equivalence set whose members carry a mutual
   **repulsion constraint** (force sim pushes them apart) and a **failure-domain
   banding** overlay (§5); the *check* — and the visual alarm — is two members
   landing in the same band. *Maps:* `podAntiAffinity`, AWS spread placement
   groups, "one replica per rack."

5. **Autoscaling group.** A multiplicity node (§2.5) with a *range* badge
   (min/desired/max, e.g. `2◂3▸10`); observed-vs-desired drift (§2.8) shown as a
   partial fill. *Maps:* ASG, HPA, k8s Deployment replica drift.

6. **Blue-green / canary (a rollout — temporal).** Two equivalence hulls
   (old/new) sharing a balancer hub; traffic weights shift old→new over a **time
   scrubber** (§9); old hull ghosts as it scales to zero. *Maps:* k8s rolling
   update, `create_before_destroy`, Argo Rollouts.

7. **Single point of failure (the *absence* of redundancy).** The dual of the
   motifs above: where redundancy *should* be and isn't. Graph theory hands this
   to us — `Data.Graph`'s **biconnected-component decomposition** (used by the
   `graph-decomposition` demo, with an `isBridge` flag already computed) finds
   **bridges** (an edge whose removal disconnects the graph) and **cut-vertices**
   (a node whose loss partitions everything downstream). In a deployment graph a
   bridge/cut-vertex *is* a SPOF: "everything depends on this one Postgres with no
   standby." Draw cut-vertices with an alarm halo and bridges in alarm-red — the
   tool tells you where you are one failure from an outage, computed, not
   remembered. *This is a redundancy finding Bosun's current IR can't even
   express, surfaced purely from the dependency graph's shape.*

Each motif is detectable from structure (a hub with a fan; a pair with a
replication edge; a labelled peer set; a bridge in the block-cut tree) — so a
future pass can *recognize* motifs and offer the right idiom automatically, the
way a good map legend names what you're looking at.

**Graph decomposition is also a layout and navigation tool, not only a
finding.** The biconnected-component / block-cut-tree decomposition partitions
any deployment graph into tightly-coupled blocks (cycles, cliques — the
mutually-entangled subsystems) joined by bridges (the clean seams). The
`graph-decomposition` demo renders these as "chimera" styles — **Spine**
(block-cut tree as a skeleton, the natural LOD overview, §7/§9), **Orbital**
(blocks as bodies whose form matches their internal structure), **Chord** (a
dense block drawn as a chord diagram), **Extracted** (blocks side by side). Each
block is a ready-made node set to wrap in a watercolour region (§4.2) — so
decomposition supplies *natural* region boundaries for the §5 overlays without
the user having to declare grouping. The skeleton is the map's index; the blocks
are its provinces.

---

## 9. Scaling beyond Bosun today — the future-proof surface

The brief is explicitly to design for deployments **more complex than Bosun
currently models.** The grammar reaches them because each is *another binding
onto an axis already in §2*, not a new diagram:

- **Multi-host / multi-region / cloud** → more containment hierarchies (§5);
  regions/AZs are just deeper enclosure + failure-domain banding. AWS/GCP/Azure
  resource graphs are the dependency DAG (§2.2) with cloud-shaped marks (§4.1)
  and reference edges (§4.4 config channel) for IAM/security-group/IAM-role
  relations.
- **Rollouts** → the temporal overlay (§2.8) with a **time scrubber**; the
  structural base is fixed, traffic weights and hot/cold fills animate. (Bosun's
  `Rollout` is post-MVP per the panoply table; the view is ready for it.)
- **Secrets / config** → the faint **reference channel** (§4.4) with a locked
  glyph for `SecretRef` (presence tracked, value never shown — matches the IR's
  "presence tracked; value never read"). Unbound references (`UnboundReference`)
  are a dangling reference edge — same visual idiom as a dangling dep.
- **Large graphs** → semantic zoom + LOD + multiplicity collapse (§7), plus two
  library-backed escapes when node-link gets too dense: the **block-cut-tree
  skeleton** (§8, decomposition) as the zoomed-out index, and the
  **adjacency-matrix** view (`DataViz.Layout.Adjacency`, labelled cells +
  `shortenName`) as the no-overlap rendering of a dense dependency or traffic
  graph — the standard "matrix when the hairball wins" move, already a lib
  primitive.
- **Terraform plan/apply & drift** → the three-way `WorldState` *is* a diff
  view: desired vs recorded vs observed rendered as ghost/solid/badge over one
  layout; `terraform plan`'s "+ create / ~ change / − destroy" is a status
  channel (§2.8) we already have the ADT for.

None of these needs a new engine. Each needs the model to grow a field or two
(§10) and the grammar to bind it to an axis that already exists. **That is the
test of whether this grammar is right: a deployment system Bosun has never heard
of should be drawable by stating which marks/enclosures/edges/channels its
concepts light up — no new code in the renderer.**

---

## 10. Landing on the wire — what we render today, what the model must grow

The handoff fact (memory): **the data is already on the wire.** `/analyze`
returns an `AnalyzeResult` (`Bosun.View.analyzeResultCodec`) carrying
`instances` (loose; each with `deps`, `routes`, `host`, `executor.mechanism`,
`selectors`, `exposure`), `reconcile` (`services`/`divergences`/`conflicts`/
`aliases`), and `result = Valid ValidatedView { services, bootOrder, routes } |
Invalid [errors]`. **So the Graph tab is a new *render* of the same response —
no backend change for v0.** The mapping:

| Grammar element | Wire field today |
|---|---|
| nodes (logical) | `reconcile.services` (canonical ids) |
| nodes (loose) | `instances[]` (per source×unit) |
| node shape | `instances[].executor.mechanism` |
| node provenance | `instances[].source` |
| dependency edges (loose) | `instances[].deps` (`to`, `ordering`, `requirement`) |
| requirement gradient | `deps[].requirement` label → §4.3 style |
| traffic edges | `instances[].routes` / `ValidatedView.routes` |
| containment (host) | `instances[].host` / `SvcView.host` |
| selectors / scope lens | `instances[].selectors` / `SvcView.selectors` |
| layered DAG (tight) | `ValidatedView.bootOrder :: Array (Array String)` |
| facets / divergence | `reconcile.divergences` |
| conflict collision | `reconcile.conflicts` (`ConflictView`) |
| status overlay | the cockpit `/state` (pillar 0), joined by id |

**What the grammar wants that the wire does *not* carry yet** — and these are
the model-growth items, listed so the engine can grow *toward* the view rather
than the view being recapped each time:

- **multiplicity** — `replicas` / `count` / ASG range on a node (§2.5). Today
  every node is ×1.
- **role / failover** — hot/cold/quorum-member + replication edges (§2.6). Not
  modelled at all today; this is the biggest IR gap and the most valuable
  post-MVP addition.
- **richer containment** — `host` is one string; physical (node/AZ/region) and
  network (VPC/subnet) hierarchies (§2.1, §5) need structured fields.
- **anti-affinity / co-location constraints** (§2.6).
- **rollout / temporal state** (§2.8) — `Rollout` is already flagged post-MVP.
- **config/secret references as edges** — `ConfigRef`/`ConfigSupplier` exist in
  the IR (DESIGN §3.5) but aren't in the view wire yet.

Recommendation: render everything the wire has *now* (it's a rich graph
already — loose deps, the requirement gradient, routes, hosts, facets,
conflicts, the boot-order layering), and add the §2.5–2.8 fields to `View.purs`
**as optional** so the grammar's richer modes light up incrementally without
ever breaking the codec contract.

---

## 11. Building it on Hylograph — what to reuse, what to build

Per the handoff and `CodeExplorer/CLAUDE.md`, build on
`../../purescript-hylograph-libs` (graph / layout / simulation / selection),
follow the **simulation rules**, and live in the `chair` package sharing
`bosun-core`'s view types.

The library survey came back far richer than first assumed — almost every
geometry this grammar needs already exists. The corrected picture:

**Reuse (present, `✓`/`△`):**

- `Hylograph.ForceEngine` — the loose force layout (§4.8). One sim per view;
  stop+recreate on view switch; **store and call the unsubscribe**; **no D3
  enter/update/exit**; **stable HATS tree** (initial structure must match the
  `Completed` tree — same `forEach` keys/types/nesting). Reference impl:
  the simulation demo's `ForcePlayground/Component.purs`.
- `Data.Graph.Layout` (`dagLayout` / layered tree) — the tight boot-order
  layering (`△`; no crossing-minimization, acceptable for v0).
- `Data.Graph` **decomposition** (`biconnectedComponents`, block-cut tree,
  `isBridge`) — SPOF/cut-vertex detection (§8 motif 7) *and* natural region
  grouping + the Spine/Orbital/Chord/Extracted "chimera" renderings (§8). Worked
  reference: the whole `graph-decomposition` demo.
- `DataViz.Layout.Sankey.*` — weighted flow ribbons, cycle-aware, with capacity
  node-value strategies (§4.4); doubles as a layered DAG renderer.
- `DataViz.Layout.Chord` + `DataViz.Layout.Adjacency` — dense traffic/mesh and
  the matrix escape for large graphs (§4.4, §9).
- `DataViz.Layout.Hierarchy.{Pack,Treemap,Partition,Tree,Cluster}` — containment
  enclosures (§4.2); `sum`/`count` for LOD aggregates (§7). Plus the gallery's
  **Swimlane / Stacked / Waffle / BinPack** layouts — directly useful for
  hosts-as-lanes, boot-stage lanes, and replica/capacity counts.
- `Onion.Watercolour` (+ `Onion.Shape`, `Onion.Plotter`) — the group-region
  blobs that are the §5 keystone. **Greenfield: nobody has used this layer in
  earnest yet** (Andrew, 2026-06-15) — Bosun's Chair will be its first real
  consumer, and the lib is expected to evolve in parallel with the view. That is
  a feature, not a risk: it means the hull/region primitive can be shaped to
  exactly what the multi-hierarchy overlays need rather than retrofitted.
- HATS layers (`Semigroup`) — the three-channels composition (§6).

**Build / co-develop (small, in dependency order):**

1. **Boundary polygon from a node set's positions** — the one helper not found
   by name (the `Polygon` fed to `watercolourBlob`). Either reuse whatever the
   `graph-decomposition` demo does to bound its components, or add a ~30-line
   convex-hull (Graham scan) / padded-bounds helper. This is the only genuine
   missing geometry, and it lands in `hylograph-onion`/`-layout` as a shared
   primitive. Everything else in §5/§8 composes from existing pieces.
2. **Requirement-gradient edge styling** — small, but it's the load-bearing
   "why did X take down Y" channel (§4.3). Pure attribute logic over edges.
3. **Semantic-zoom / LOD controller** — collapse/explode by containment depth +
   multiplicity (§7). App-level state machine (no library primitive needed; the
   hierarchy `sum`/`count` aggregates and the decomposition skeleton feed it).
4. **Swappable-spatial-hierarchy relayout** — the §5 interaction: pick primary
   hierarchy → relayout → others become blobs; animated. Pure orchestration over
   (1) + the chosen layout.

The shift from "build five geometries" to "build one helper + three app-level
controllers" is the dividend of the library being this mature. The grammar is
mostly an *assembly* of existing Hylograph layouts, not new rendering code.

**Architecture stays honest with the rest of Bosun:** the Graph tab is a *pure
projection* of `AnalyzeResult` → positioned marks/edges/hulls, plus the status
join from `/state`. No new server authority (it reads the same two endpoints the
Chair already reads). It is the **spatial index** over the other pillars: click
a node → its facets (Pillar 1), its `.deploy` overlay (Pillar 2),
spawn/stop/reload (Pillar 0). One model, four views, none re-deriving it.

---

## 12. Phasing

- **v0 — the honest graph of the wire we have.** Loose force layout of
  `instances[].deps` (dangling = ghost, cycle = visible loop); node shape by
  mechanism, border by source; the requirement-gradient edge styling (§4.3);
  traffic channel from `routes`; host as the one containment overlay (needs the
  hull build-item #1). On `Valid`, animate into the boot-order layered DAG.
  Conflicts as collision marks; status joined from `/state`. **This alone
  outruns every table the Chair shows today and proves the grammar.**
- **v1 — containment & scope.** The swappable-spatial-hierarchy interaction
  (§5) over host (+ any structured placement the model grows); the scope lens
  (§4.6); facet explode (§4.7) as the bridge to Pillar 1.
- **v2 — scale.** Semantic zoom / LOD / multiplicity collapse (§7) for large
  graphs.
- **v3 — reliability.** The failover motif catalog (§8) as the model grows role
  / replication / anti-affinity (§10); failure-domain banding.
- **v4 — time.** Rollout scrubber + drift diff view (§9).

Each phase is a *binding of more axes*, never a rewrite — which is the whole
point of designing the grammar ahead of the engine.

---

## 13. Open questions

1. **Region rendering — how much to lean on watercolour.** The keystone is no
   longer "build a hull" but "what *shape* should a region be," since
   `Onion.Watercolour` gives us painterly blobs and `Onion.Shape` gives clean
   geometric ones. Watercolour reads beautifully for *organic community* regions
   (a decomposition block, §8) but its randomness may be wrong for *crisp
   semantic* boundaries (an AZ, a namespace) where the user needs to trust the
   edge. Likely answer: clean shapes for the load-bearing failure-domain/scope
   overlays, watercolour for the softer "these nodes cluster" regions — and since
   the onion layer is greenfield (§11), tune it to that distinction as we build.
   Sub-question kept: the boundary-polygon helper (§11 #1) — reuse the
   decomposition demo's, or add Graham-scan?
2. **Default spatial hierarchy.** When physical ≈ logical (the homelab/compose
   common case) they collapse and it doesn't matter. When they differ, what's
   the *default* primary — logical (what you reason about) or physical (where
   failures bite)? (Lean: logical default, one-key swap to physical, because the
   user usually arrives with a logical mental model.)
3. **Loose-graph cycle rendering.** A dependency cycle in the loose view is a
   finding, not a crash. We now have *two* library mechanisms that find it for
   us — Sankey's `detectAndRemoveBackEdges`/`classifyBackEdges` (§4.4) and the
   biconnected decomposition's blocks (a cycle is a non-trivial block, §8). So
   the question is presentation, not detection: pin the cycle's block and draw
   the offending back-edge in alarm-red, or render the cyclic block as a
   decomposition "ring" (the Chord chimera style)? (Lean: pin + alarm-red
   back-edge in the main view, with the ring as a drill-in — the cycle should be
   *the* eye-catching thing, since it's why the deployment won't validate.)
4. **How much motif *recognition* vs motif *annotation*.** Should the engine try
   to *detect* "this is a quorum cluster" from structure and auto-apply the
   idiom (§8), or only render motifs the model *declares*? (Lean: declare first
   — recognition is a lovely later pass but risks mislabelling; a wrong legend
   is worse than none.)
5. **Where multiplicity auto-explodes.** Status divergence among replicas should
   auto-explode the collapsed node (§7) — but in a 1000-replica ASG that's a
   wall. Cap + "N unhealthy of M" badge with drill-in? (Lean: yes — never
   explode beyond a screenful; the badge is the promise, drill-in is the detail.)
6. **Does the tight/loose split want a *third* state?** Today: loose (always) →
   tight (on `Valid`). But a deployment can be *valid-but-drifted* (validates,
   yet observed ≠ desired). Is drift a third layout mode, or just the status
   overlay on the tight layout? (Lean: overlay — drift is dynamic, the layout is
   structural; don't relayout for runtime state.)
