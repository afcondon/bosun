-- | DESIGN §5 / DECISIONS D-E3, D-E2 — `reconcile`, the facet model.
-- |
-- | Ingestion yields a flat `Array ServiceInstance` in which the same logical
-- | service appears more than once under different names and on different
-- | hosts (§7). `reconcile` groups instances by identity, partitions each
-- | group by **facet key** `(Host, ExecutorMechanism)`, and splits the loose
-- | word "drift" in two (D-E3):
-- |
-- |   * **facet divergence** — a service with more than one facet ("the two
-- |     ways we deploy this"). *Expected; reported informationally.*
-- |   * **conflict** — two sources describing the *same* facet that disagree on
-- |     a facet-local field. *An error* (`CrossSourceDrift`).
-- |
-- | A single-facet service has nothing to conflict with (D-E2: absence of a
-- | facet is never drift). This is the engine of the §7 demo and the reason
-- | Bosun is more than a generator.
-- |
-- | PHASE 3A SCOPE: within-facet conflict is detected on `exposure` (the most
-- | common real divergence — two sources claiming different ports for one
-- | facet); the cross-facet dependency-shape agreement check and the
-- | representative-facet handoff's full fidelity are Phase 3B (alongside the
-- | real adapters). The representative `Deployment` for `validate` takes the
-- | first instance per service.
module Bosun.Reconcile
  ( FacetKey
  , Divergence(..)
  , ArtifactDrift(..)
  , TopologyDrift(..)
  , RouteReq
  , ReconcileResult
  , AliasMap
  , reconcile
  , buildAliases
  , exposureLabel
  ) where

import Prelude

import Bosun.Artifact (Artifact, ArtifactConsensus(..), artifactConsensus, artifactOf)
import Control.Alt ((<|>))
import Bosun.Atoms (Host, RoutePath, ServiceId, mkServiceId, unAbsPath, unDomain, unPort, unProjectSlug, unRoutePath)
import Bosun.Error (DeployError(..))
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ExecutorMechanism, mechanism)
import Bosun.Exposure (Exposure(..))
import Bosun.Reachability (classify)
import Bosun.Health (Probe(..))
import Bosun.Service
  ( Deployment, LooseDep, LooseRoute, LooseService, RawDep, RawRoute
  , ServiceInstance, Source(..), mkDeployment, unRole
  )
import Data.Array as A
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Foldable (foldr)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..), fst, snd, uncurry)

-- | localName (or registry slug) → the canonical `ServiceId` it belongs to.
-- | The cross-source bridge: compose's `tidal-frontend` and the registry's
-- | `uniform-romeo-romeo-juliet:frontend` only group via an alias entry.
type AliasMap = Map String ServiceId

type FacetKey = { host :: Maybe Host, mechanism :: ExecutorMechanism }

data Divergence = Divergence { svc :: ServiceId, facets :: NonEmptyArray FacetKey }

-- | A service whose facets imply DIFFERENT content (docs/ARTIFACTS.md). Unlike a
-- | `Divergence` (different run-FORMS of the same thing — expected, healthy),
-- | this is the architectural drift behind the stale public site: the native
-- | facet and the container facet would serve different bytes. Reported as its
-- | own finding — not a `DeployError` (it does not block minting a
-- | `ValidatedDeployment`; you may still deploy the diverged thing while you fix
-- | it), and not a benign `Divergence`.
data ArtifactDrift = ArtifactDrift { svc :: ServiceId, artifacts :: NonEmptyArray Artifact }

-- | A required reverse-proxy route: a backend reached same-origin at `path`. The
-- | declared route table R (docs/ARTIFACTS.md "the edge is topology") is the
-- | union of these across every facet's `x-bosun.routes`.
type RouteReq = { path :: RoutePath, backend :: ServiceId }

-- | A HOST that runs routed backends but provides NO co-located edge serving
-- | them (the routing-contract gap behind "deploys fine on Docker, breaks on the
-- | MBP"): the website's root-relative links 404 because the executor that
-- | brought the backends up on this host dropped the edge. Like `ArtifactDrift`,
-- | this is a per-target architectural finding, NOT a `DeployError` — a valid
-- | deployment can still be edge-missing on one of its hosts; you may deploy it
-- | while you add the local edge. The CONSERVATISM (mirroring
-- | `artifactConsensus`'s basename rule): the edge is expected *co-located* with
-- | the backends it fronts; a cross-host edge proxying to another host over the
-- | network is legitimate and not flagged (that richer case is deferred).
data TopologyDrift = TopologyDrift { host :: Host, missing :: NonEmptyArray RouteReq }

type ReconcileResult =
  { deployment    :: Deployment            -- representative facets, for validate
  , conflicts     :: Array DeployError      -- within-facet disagreement (CrossSourceDrift)
  , divergences   :: Array Divergence       -- informational: a service's multiple facets
  , artifactDrift :: Array ArtifactDrift    -- facets that would run DIFFERENT content
  , topologyDrift :: Array TopologyDrift     -- hosts running routed backends with no edge
  }

reconcile :: AliasMap -> Array ServiceInstance -> ReconcileResult
reconcile aliases insts =
  { deployment: mkDeployment (A.mapMaybe _.loose groups)
  , conflicts: groups >>= _.conflicts
  , divergences: A.mapMaybe _.divergence groups
  , artifactDrift: A.mapMaybe _.artifactDrift groups
  , topologyDrift: topologyGaps aliases insts
  }
  where
  grouped :: Map ServiceId (Array ServiceInstance)
  grouped = foldr (\si -> Map.insertWith (<>) (identityOf aliases si) [ si ]) Map.empty insts

  groups = map (uncurry reconcileGroup) (Map.toUnfoldable grouped :: Array (Tuple ServiceId (Array ServiceInstance)))

  reconcileGroup
    :: ServiceId
    -> Array ServiceInstance
    -> { conflicts :: Array DeployError, divergence :: Maybe Divergence, artifactDrift :: Maybe ArtifactDrift, loose :: Maybe LooseService }
  reconcileGroup sid is =
    { conflicts: (Map.toUnfoldable byFacet :: Array (Tuple FacetKey (Array ServiceInstance)))
        >>= \(Tuple _ fis) -> withinFacetConflict sid fis
    , divergence: case NEA.fromArray facetKeys of
        Just nea | NEA.length nea > 1 -> Just (Divergence { svc: sid, facets: nea })
        _ -> Nothing
    -- one artifact per facet (its representative instance's executor); if the
    -- facets imply DIFFERENT content, that's the drift (docs/ARTIFACTS.md).
    , artifactDrift: case artifactConsensus facetArtifacts of
        Diverged nea -> Just (ArtifactDrift { svc: sid, artifacts: nea })
        _ -> Nothing
    , loose: map (\rep -> toLoose aliases sid rep is) (A.head is)
    }
    where
    byFacet :: Map FacetKey (Array ServiceInstance)
    byFacet = foldr (\si -> Map.insertWith (<>) (facetKeyOf si) [ si ]) Map.empty is
    facetKeys = map fst (Map.toUnfoldable byFacet :: Array (Tuple FacetKey (Array ServiceInstance)))
    facetArtifacts =
      (Map.toUnfoldable byFacet :: Array (Tuple FacetKey (Array ServiceInstance)))
        # A.mapMaybe (\(Tuple _ fis) -> A.head fis >>= artifactFor)

identityOf :: AliasMap -> ServiceInstance -> ServiceId
identityOf aliases si = case Map.lookup si.localName aliases of
  Just canonical -> canonical
  Nothing -> case si.project of
    Just slug -> mkServiceId (unProjectSlug slug <> ":" <> unRole si.role)
    Nothing -> mkServiceId si.localName

facetKeyOf :: ServiceInstance -> FacetKey
facetKeyOf si = { host: si.host, mechanism: mechanism si.executor }

-- A facet's artifact: the DECLARED `x-bosun.artifact` if present, else derived
-- from the executor (`artifactOf`). Declaration is authoritative — it drops the
-- heuristic's reach limits (docs/ARTIFACTS.md).
artifactFor :: ServiceInstance -> Maybe Artifact
artifactFor si = si.artifact <|> artifactOf si.executor

-- | The per-host edge check (docs/ARTIFACTS.md "the edge is topology, preserve
-- | it locally"). The declared route table R is the union of every facet's
-- | `x-bosun.routes` (backend identity resolved through the alias map). For each
-- | host H, a route whose backend has a facet on H but whose path is served by
-- | NO facet on H is edge-missing on H — the executor that brought the backends
-- | up there dropped the front door, so the route 404s. Hosts with at least one
-- | such route yield a `TopologyDrift`. Host-less instances are skipped (we
-- | cannot name the host to flag — same conservatism as `checkCollisions`).
topologyGaps :: AliasMap -> Array ServiceInstance -> Array TopologyDrift
topologyGaps aliases insts = A.mapMaybe gapFor hosts
  where
  -- R: the declared route table, backend names resolved to identities.
  routeTable :: Array RouteReq
  routeTable = A.nubEq
    (insts >>= \si -> map (\r -> { path: r.path, backend: resolveName aliases r.to }) si.rawRoutes)

  hosts :: Array Host
  hosts = A.nub (A.mapMaybe _.host insts)

  gapFor :: Host -> Maybe TopologyDrift
  gapFor h =
    let
      here = A.filter (\si -> si.host == Just h) insts
      backendsHere = Set.fromFoldable (map (identityOf aliases) here)
      pathsHere = Set.fromFoldable (here >>= \si -> map _.path si.rawRoutes)
      missing = routeTable # A.filter \r ->
        Set.member r.backend backendsHere && not (Set.member r.path pathsHere)
    in TopologyDrift <<< { host: h, missing: _ } <$> NEA.fromArray (A.nubEq missing)

-- Two sources in the SAME facet disagreeing on exposure ⇒ a real conflict.
withinFacetConflict :: ServiceId -> Array ServiceInstance -> Array DeployError
withinFacetConflict sid fis =
  let claims = map (\si -> Tuple si.source (exposureLabel (classify si.reachability))) fis
  in if A.length (A.nub (map snd claims)) > 1
       then [ CrossSourceDrift { svc: sid, field: "exposure", claims } ]
       else []

-- The representative loose node for validate. Host/exposure come from the
-- representative instance `rep` (a single facet — multi-facet collision is
-- Phase 6), but the FACET-LOCAL relationships (selectors, deps, routes,
-- readiness) are UNIONED across all of the service's instances — otherwise a
-- registry-only representative would drop compose's profiles/healthchecks and
-- `validate` would raise false SelectorNotClosed / UncheckableGate.
toLoose :: AliasMap -> ServiceId -> ServiceInstance -> Array ServiceInstance -> LooseService
toLoose aliases sid rep is =
  { id: sid
  , host: rep.host
  , reachability: rep.reachability
  , readiness: fromMaybe NoProbe (A.find (_ /= NoProbe) (map (\si -> si.health.readiness) is))
  -- Restart is FACET-LOCAL (DECISIONS.md D-2's field table): it may differ
  -- freely between facets and must agree within one, so it comes from the
  -- representative instance like host/exposure — never unioned like the
  -- facet-local-but-additive relationships below.
  , restart: rep.restart
  , deps: A.nubEq (is >>= \si -> map (resolveDep aliases) si.rawDeps)
  , routes: A.nubEq (is >>= \si -> map (resolveRoute aliases) si.rawRoutes)
  , selectors: A.nubEq (is >>= _.selectors)
  , launch: { executor: rep.executor, localName: rep.localName, artifact: artifactFor rep }
  }

resolveDep :: AliasMap -> RawDep -> LooseDep
resolveDep aliases d = { to: resolveName aliases d.to, ordering: d.ordering, requirement: d.requirement }

resolveRoute :: AliasMap -> RawRoute -> LooseRoute
resolveRoute aliases r = { to: resolveName aliases r.to, path: r.path }

resolveName :: AliasMap -> String -> ServiceId
resolveName aliases name = fromMaybe (mkServiceId name) (Map.lookup name aliases)

-- | A short, documented label for an `Exposure` (an entry-73 `display`
-- | function — never `show`). Used in drift claims and the report.
exposureLabel :: Exposure -> String
exposureLabel = case _ of
  HostPort p -> "host:" <> show (unPort p)
  InternalPort p -> "internal:" <> show (unPort p)
  ProxyRoute r -> "proxy:" <> unRoutePath r.path
  PublicDomain d -> "domain:" <> unDomain d
  UnixSocket s -> "socket:" <> unAbsPath s
  NoNetwork -> "none"

-- | DEFAULT cross-source alias derivation (moved here from the CLI in A0 so
-- | both the `bosun` CLI and the Chair's analysis backend derive the *same*
-- | default aliases; the Chair then merges user overrides on top — MVP-PLAN
-- | decision #3). Bridges compose ↔ registry by shared directory basename (the
-- | registry row's startCommand cwd vs the compose service's build context):
-- | same directory basename ⇒ same logical service, so the native and
-- | containerised facets group. DECISIONS "alias-map for MVP" — derived rather
-- | than hand-maintained.
buildAliases :: Array ServiceInstance -> AliasMap
buildAliases insts =
  Map.fromFoldable (insts # A.mapMaybe aliasFor)
  where
  canon :: Map String ServiceId
  canon = Map.fromFoldable (insts # A.mapMaybe registryKey)

  registryKey si = case si.source of
    FromRegistry -> (\k -> Tuple k (canonId si)) <$> dirKey si
    _ -> Nothing

  aliasFor si = case si.source of
    FromCompose -> do
      k <- dirKey si
      cid <- Map.lookup k canon
      pure (Tuple si.localName cid)
    _ -> Nothing

canonId :: ServiceInstance -> ServiceId
canonId si = case si.project of
  Just slug -> mkServiceId (unProjectSlug slug <> ":" <> unRole si.role)
  Nothing -> mkServiceId si.localName

dirKey :: ServiceInstance -> Maybe String
dirKey si = case si.executor of
  Process p -> Just (basename (unAbsPath p.cwd))
  Container (ContainerSpec cs) -> case cs.source of
    Right (BuildContext b) -> Just (basename b.context)
    _ -> Nothing
  _ -> Nothing

basename :: String -> String
basename p = fromMaybe p (A.last (A.filter (_ /= "") (String.split (Pattern "/") p)))
