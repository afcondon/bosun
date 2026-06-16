-- | DESIGN §4 / §6 — `validate`, the v4 rung (the heart).
-- |
-- | The pure tightening pass: a loose `Deployment` (several sources making
-- | overlapping claims) becomes a tight `ValidatedDeployment` — referential
-- | integrity (every dep/route resolves), a proven-acyclic `BootOrder`,
-- | selector closure, route backing, gate checkability. Past this boundary
-- | `plan`/`apply` are *total*: a cycle, a dangle, a collision *cannot reach
-- | the executor*.
-- |
-- | Errors ACCUMULATE (`V (Array DeployError)`, not `Either`): the brief is
-- | "catch ALL the inconsistencies in one pass." The independent checks each
-- | contribute their findings; only when the error set is empty is a
-- | `ValidatedDeployment` minted (via the trusted `Bosun.Service.Internal`
-- | constructors — this is the one module allowed to forge proofs).
-- |
-- | Covers the structural must-fail corpus B1–B6 (SCENARIOS.md). B7/B8 are
-- | Tier-1 ingestion (Phase 3); B9 (cross-source drift) is `reconcile`'s job
-- | (Phase 3) — it needs more than one source, which `validate` never sees.
module Bosun.Validate (validate) where

import Prelude

import Bosun.Edge (DepOrdering(..), Gate(..), Requirement(..))
import Bosun.Error (DeployError(..))
import Bosun.Reachability (Address(..), BindScope(..), addresses)
import Bosun.Health (Probe(..))
import Bosun.Atoms (Host, Port, ServiceId, unServiceId)
import Bosun.Selector (Selector)
import Bosun.Service.Internal
  ( Deployment, LooseDep, LooseService, Service, ServiceRef, ValidatedDeployment
  , deploymentServices, mkBootOrder, mkServiceRef, mkValidatedDeployment
  )
import Data.Array ((\\))
import Data.Array as A
import Data.Either (Either(..))
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NEA
import Data.Foldable (any, elem, foldr, null)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (V, invalid)

validate :: Deployment -> V (Array DeployError) ValidatedDeployment
validate dep =
  case topo (map _.id svcs) precEdges of
    Left cyc ->
      invalid (localErrs <> maybe [] (\nea -> [ DependencyCycle nea ]) (NEA.fromArray cyc))
    Right stages
      | null localErrs -> pure (assemble stages)
      | otherwise -> invalid localErrs
  where
  svcs :: Array LooseService
  svcs = deploymentServices dep

  ids :: Set ServiceId
  ids = Set.fromFoldable (map _.id svcs)

  -- look up an upstream by id (for gate readiness + selector closure)
  byId :: Map ServiceId LooseService
  byId = Map.fromFoldable (map (\s -> Tuple s.id s) svcs)

  -- The independent, accumulating checks (everything except acyclicity).
  localErrs :: Array DeployError
  localErrs = A.concat
    [ svcs >>= checkDangling ids
    , checkCollisions svcs
    , svcs >>= checkGates byId
    , svcs >>= checkRoutes ids
    , svcs >>= checkSelectors byId
    ]

  -- Precedence edges (earlier, later) among PRESENT targets only — dangling
  -- targets are reported separately and contribute no ordering.
  precEdges :: Array (Tuple ServiceId ServiceId)
  precEdges = A.nub (svcs >>= \s -> s.deps >>= depEdges s.id)

  depEdges :: ServiceId -> LooseDep -> Array (Tuple ServiceId ServiceId)
  depEdges from d
    | not (Set.member d.to ids) = []
    | otherwise = fromOrdering <> fromRequirement
    where
    fromOrdering = case d.ordering of
      Just StartAfter -> [ Tuple d.to from ]   -- `from` starts after `to`
      Just StartBefore -> [ Tuple from d.to ]
      Nothing -> []
    fromRequirement = case d.requirement of
      Just (Requires _) -> [ Tuple d.to from ]
      Just BindsTo -> [ Tuple d.to from ]
      Just Requisite -> [ Tuple d.to from ]
      _ -> []   -- Wants (soft) and PartOf (reverse-only) impose no boot order

  -- Mint the proof. Reached only when localErrs is empty, so every hard edge
  -- resolves; soft (Wants) edges to an absent target are dropped here.
  assemble :: Array (NonEmptyArray ServiceId) -> ValidatedDeployment
  assemble stages = mkValidatedDeployment
    { services: Map.fromFoldable (map (\s -> Tuple s.id (resolveNode s)) svcs)
    , bootOrder: mkBootOrder (map (map mkServiceRef) stages)
    , routes: Map.fromFoldable
        (svcs >>= \s -> map (\r -> Tuple r.path (mkServiceRef r.to)) s.routes)
    , selectors: selectorMap svcs
    }

  resolveNode :: LooseService -> Service
  resolveNode s =
    { id: s.id
    , host: s.host
    , reachability: s.reachability
    , readiness: s.readiness
    , deps: s.deps # A.mapMaybe \d ->
        if Set.member d.to ids
          then Just { to: mkServiceRef d.to, ordering: d.ordering, requirement: d.requirement }
          else Nothing   -- a dropped soft edge
    , routes: map (\r -> { to: mkServiceRef r.to, path: r.path }) s.routes
    , selectors: s.selectors
    , launch: s.launch
    }

-- B2 — DanglingDependency. Edge-kind-aware (E4): a *soft* (`Wants`) edge to an
-- absent target is dropped, not an error; anything else dangling is an error.
checkDangling :: Set ServiceId -> LooseService -> Array DeployError
checkDangling ids s = s.deps # A.mapMaybe \d ->
  if Set.member d.to ids || d.requirement == Just Wants
    then Nothing
    else Just (DanglingDependency s.id (unServiceId d.to))

-- B3 — PortCollision. Group host-published-listener claims by (host, port);
-- >1 distinct service = collision. Different hosts are fine (that is A8's
-- facets). Host-less claims are skipped (we cannot name the colliding host).
--
-- SCOPE-AWARE (ADDRESS-TYPE §8): the old check matched a single `HostPort`
-- per service. Now `reachability` is a SET, so a service contributes a claim
-- for EVERY host-published listener — composition (multiple published ports on
-- one service) is finally checkable. `Internal`/`Loopback` binds do not contend
-- for the host's published port space, so they never collide here.
checkCollisions :: Array LooseService -> Array DeployError
checkCollisions svcs =
  let
    claims :: Array (Tuple (Tuple Host Port) ServiceId)
    claims = svcs >>= \s -> case s.host of
      Nothing -> []
      Just h ->
        A.fromFoldable (addresses s.reachability) # A.mapMaybe \a -> case a of
          Listening { bind, port } | publishedToHost bind -> Just (Tuple (Tuple h port) s.id)
          _ -> Nothing
    grouped :: Map (Tuple Host Port) (Array ServiceId)
    grouped = foldr (\(Tuple k sid) -> Map.insertWith (<>) k [ sid ]) Map.empty claims
  in
    Map.toUnfoldable grouped # A.mapMaybe \(Tuple (Tuple h p) sids) ->
      -- nub so a service that publishes one port via two listeners (e.g.
      -- AllIfaces and a HostIface) does not collide with itself.
      let distinct = A.nub sids in
      if A.length distinct > 1
        then map (PortCollision h p) (NEA.fromArray distinct)
        else Nothing
  where
  publishedToHost :: BindScope -> Boolean
  publishedToHost = case _ of
    AllIfaces -> true
    HostIface _ -> true
    Internal -> false
    Loopback -> false

-- B5 — UncheckableGate. A `Requires On{Ready,Healthy}` edge demands the
-- upstream publish a readiness signal (≠ NoProbe). OnStarted/OnCompleted do not.
checkGates :: Map ServiceId LooseService -> LooseService -> Array DeployError
checkGates byId s = s.deps # A.mapMaybe \d -> case d.requirement of
  Just (Requires g) | g == OnReady || g == OnHealthy ->
    case Map.lookup d.to byId of
      Just up | up.readiness == NoProbe ->
        Just (UncheckableGate { gated: s.id, upstream: up.id, gate: g })
      _ -> Nothing
  _ -> Nothing

-- B6 — RouteWithoutBacking. A route whose backend resolves to nothing.
checkRoutes :: Set ServiceId -> LooseService -> Array DeployError
checkRoutes ids s = s.routes # A.mapMaybe \r ->
  if Set.member r.to ids then Nothing else Just (RouteWithoutBacking r.path)

-- B4 — SelectorNotClosed. A selector must be closed under (hard) requirement:
-- if a member `Requires`/`BindsTo` an upstream, the upstream must share the
-- selector. Only checked against present upstreams (absent = DanglingDependency).
checkSelectors :: Map ServiceId LooseService -> LooseService -> Array DeployError
checkSelectors byId s = s.deps >>= \d -> case d.requirement of
  Just (Requires _) -> closure d
  Just BindsTo -> closure d
  _ -> []
  where
  closure d = case Map.lookup d.to byId of
    Just up -> s.selectors # A.mapMaybe \sel ->
      if elem sel up.selectors
        then Nothing
        else Just (SelectorNotClosed { selector: sel, svc: s.id, missingDep: up.id })
    Nothing -> []

-- B1 — acyclicity by Kahn levels. Returns the boot stages (each non-empty) or,
-- on a cycle, the still-entangled nodes for `DependencyCycle`.
topo
  :: Array ServiceId
  -> Array (Tuple ServiceId ServiceId)
  -> Either (Array ServiceId) (Array (NonEmptyArray ServiceId))
topo nodes edges = go nodes []
  where
  go :: Array ServiceId -> Array (NonEmptyArray ServiceId) -> Either (Array ServiceId) (Array (NonEmptyArray ServiceId))
  go remaining acc
    | null remaining = Right acc
    | otherwise =
        let ready = A.filter (not <<< hasIncoming remaining) remaining
        in case NEA.fromArray ready of
             Nothing -> Left remaining               -- nothing ready ⇒ a cycle
             Just stage -> go (remaining \\ ready) (acc <> [ stage ])

  hasIncoming :: Array ServiceId -> ServiceId -> Boolean
  hasIncoming remaining n =
    any (\(Tuple a b) -> b == n && a `elem` remaining) edges

-- group services by selector membership, keys non-empty by construction
selectorMap :: Array LooseService -> Map Selector (NonEmptyArray ServiceRef)
selectorMap svcs =
  let
    pairs :: Array (Tuple Selector ServiceRef)
    pairs = svcs >>= \s -> map (\sel -> Tuple sel (mkServiceRef s.id)) s.selectors
    grouped :: Map Selector (Array ServiceRef)
    grouped = foldr (\(Tuple sel ref) -> Map.insertWith (<>) sel [ ref ]) Map.empty pairs
  in
    Map.fromFoldable
      (Map.toUnfoldable grouped # A.mapMaybe \(Tuple sel refs) -> map (Tuple sel) (NEA.fromArray refs))
