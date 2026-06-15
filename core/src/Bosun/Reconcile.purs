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
  , ReconcileResult
  , AliasMap
  , reconcile
  , buildAliases
  , exposureLabel
  ) where

import Prelude

import Bosun.Atoms (Host, ServiceId, mkServiceId, unAbsPath, unDomain, unPort, unProjectSlug, unRoutePath)
import Bosun.Error (DeployError(..))
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ExecutorMechanism, mechanism)
import Bosun.Exposure (Exposure(..))
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
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..), fst, snd, uncurry)

-- | localName (or registry slug) → the canonical `ServiceId` it belongs to.
-- | The cross-source bridge: compose's `tidal-frontend` and the registry's
-- | `uniform-romeo-romeo-juliet:frontend` only group via an alias entry.
type AliasMap = Map String ServiceId

type FacetKey = { host :: Maybe Host, mechanism :: ExecutorMechanism }

data Divergence = Divergence { svc :: ServiceId, facets :: NonEmptyArray FacetKey }

type ReconcileResult =
  { deployment  :: Deployment            -- representative facets, for validate
  , conflicts   :: Array DeployError      -- within-facet disagreement (CrossSourceDrift)
  , divergences :: Array Divergence       -- informational: a service's multiple facets
  }

reconcile :: AliasMap -> Array ServiceInstance -> ReconcileResult
reconcile aliases insts =
  { deployment: mkDeployment (A.mapMaybe _.loose groups)
  , conflicts: groups >>= _.conflicts
  , divergences: A.mapMaybe _.divergence groups
  }
  where
  grouped :: Map ServiceId (Array ServiceInstance)
  grouped = foldr (\si -> Map.insertWith (<>) (identityOf aliases si) [ si ]) Map.empty insts

  groups = map (uncurry reconcileGroup) (Map.toUnfoldable grouped :: Array (Tuple ServiceId (Array ServiceInstance)))

  reconcileGroup
    :: ServiceId
    -> Array ServiceInstance
    -> { conflicts :: Array DeployError, divergence :: Maybe Divergence, loose :: Maybe LooseService }
  reconcileGroup sid is =
    { conflicts: (Map.toUnfoldable byFacet :: Array (Tuple FacetKey (Array ServiceInstance)))
        >>= \(Tuple _ fis) -> withinFacetConflict sid fis
    , divergence: case NEA.fromArray facetKeys of
        Just nea | NEA.length nea > 1 -> Just (Divergence { svc: sid, facets: nea })
        _ -> Nothing
    , loose: map (\rep -> toLoose aliases sid rep is) (A.head is)
    }
    where
    byFacet :: Map FacetKey (Array ServiceInstance)
    byFacet = foldr (\si -> Map.insertWith (<>) (facetKeyOf si) [ si ]) Map.empty is
    facetKeys = map fst (Map.toUnfoldable byFacet :: Array (Tuple FacetKey (Array ServiceInstance)))

identityOf :: AliasMap -> ServiceInstance -> ServiceId
identityOf aliases si = case Map.lookup si.localName aliases of
  Just canonical -> canonical
  Nothing -> case si.project of
    Just slug -> mkServiceId (unProjectSlug slug <> ":" <> unRole si.role)
    Nothing -> mkServiceId si.localName

facetKeyOf :: ServiceInstance -> FacetKey
facetKeyOf si = { host: si.host, mechanism: mechanism si.executor }

-- Two sources in the SAME facet disagreeing on exposure ⇒ a real conflict.
withinFacetConflict :: ServiceId -> Array ServiceInstance -> Array DeployError
withinFacetConflict sid fis =
  let claims = map (\si -> Tuple si.source (exposureLabel si.exposure)) fis
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
  , exposure: rep.exposure
  , readiness: fromMaybe NoProbe (A.find (_ /= NoProbe) (map (\si -> si.health.readiness) is))
  , deps: A.nubEq (is >>= \si -> map (resolveDep aliases) si.rawDeps)
  , routes: A.nubEq (is >>= \si -> map (resolveRoute aliases) si.rawRoutes)
  , selectors: A.nubEq (is >>= _.selectors)
  , launch: { executor: rep.executor, localName: rep.localName }
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
