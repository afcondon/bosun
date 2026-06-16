# Placement & Redundancy — handoff brief for the engine

Status: **PROPOSED** (viz prototype landed on branch `force-ghosts`; core
promotion pending). Companion to `ADDRESS-TYPE.md`, same shape and intent: the
viz side proved the concept with a cheap carrier; this brief asks the engine to
promote it to a first-class, total core type.

## Why

Bosun's fifth and (with redundancy) sixth primitive in the design grammar
(`docs/GRAPH-GRAMMAR.md` §2.1, §8, §14, Appendix A): **placement is a
failure-domain path**, and **redundancy is an explicit group with a mode**.
Together they make co-location and SPOF *expressible* — the whole point of the
co-location work. Today the viz reads a placement path; nothing in the core
models it, and redundancy is not modelled at all.

## What the viz prototype does today (the thing to replace)

- Compose adapter parses `x-bosun.place: [coarse, …, fine]` and stashes it as a
  `"/"`-joined string in `ServiceInstance.extra["place"]`
  (`adapters/.../Compose.purs`: `xbosunPlace`, `placeExtra`, `placeHost`).
- `Bosun.View.placePath` reads `extra["place"]`, splits on `/`, and falls back to
  `[host]` so single-host fixtures keep one level.
- `ServiceInstanceView` carries `place :: Array String` (coarse→fine), encoded in
  `serviceInstanceViewCodec`.

This works end-to-end (see `fixtures/topologies/colocation`) but is stringly and
escape-hatched. Replace with a real type.

## Proposed core type

```purescript
-- coarse→fine failure-domain path: e.g. Placement [Domain "mini-1", Domain "data-a"]
newtype Placement = Placement (Array Domain)
newtype Domain = Domain String   -- a named failure domain at one level (machine/zone/region/host)

-- co-location = a shared prefix; the deepest shared level is the blast radius two
-- nodes share. The empty Placement means "unplaced".
sharedDepth :: Placement -> Placement -> Int
colocatedAt :: Int -> Placement -> Placement -> Boolean   -- share the level-`k` ancestor
finest :: Placement -> Maybe Domain                       -- = the old `host`
```

Add `place :: Placement` to the core `ServiceInstance` (alongside `host`, which
becomes derivable as `finest place`; keep or retire `host` at the engine's
discretion — the View can project `host = unDomain <$> finest si.place`).

Redundancy, as a sibling concept (§2.6, §8):

```purescript
newtype RedundancyGroup = RedundancyGroup
  { name :: String, mode :: RedundancyMode, members :: Array ServiceId }
data RedundancyMode = ActiveActive | ActivePassive | Quorum Int   -- Quorum n = tolerate n failures
```

Surface: `x-bosun.redundancy-group: { name, mode }` on each member (explicit, not
inferred from naming — consistent with the project's explicit-over-magic rule).
Real systems project onto it: k8s Deployment replicas → ActiveActive; RDS
Multi-AZ → ActivePassive; etcd/Raft → Quorum.

## What it unlocks (the analyses that should live in core, total)

- **Illusory redundancy (placement SPOF):** for each `RedundancyGroup` with ≥2
  members, if `sharedDepth` of any member pair > 0, the group shares a failure
  domain below the root → finding. (§8.4 anti-affinity check.)
- **Structural SPOF:** cut-vertices / bridges of the dependency graph via
  `Data.Graph.Decomposition` (`articulationPoints`, `bridges`) — needs no
  placement, computable from the dep graph alone (§8.7). Likely a View/analysis
  concern, but the engine may want it as a first-class finding.
- **Blast radius:** transitive dependents of everything in a chosen domain.

## MISU / make-illegal-states-unrepresentable notes

- `Placement` as `Array Domain` admits the empty path (unplaced) deliberately —
  do **not** force a non-empty. "Unplaced" is a real state (registry-only
  services, the loose view).
- A `RedundancyGroup` with <2 members is degenerate but legal (a group of one is
  "no redundancy"); the SPOF finding is about ≥2 sharing a domain, so a singleton
  simply never triggers it. Consider whether the type should forbid 0 members.
- Mode `Quorum n` with `n` ≥ member count is a misconfiguration worth a finding.

## Falsification — how we'll know the type is wrong

- If a real surface needs *overlapping* placement (a node in two failure-domain
  paths at once), the `Array Domain` tree assumption breaks and placement must
  become a set of paths. (Grammar §14.1 argues this is the *general* case;
  `Array Domain` is the tractable common case. Watch for the first fixture that
  needs more.)
- If `host` turns out to carry meaning distinct from `finest place` anywhere in
  reconcile/validate, retiring it was wrong — keep both.

## Viz contract (what the engine must keep stable for the Chair)

`ServiceInstanceView.place :: Array String`, coarse→fine, encoded as today. The
Chair's graph reads only this projection — promote the core freely as long as the
projection still produces the path.
