-- | DESIGN §3.7 — the loose ingested node and the tight validated graph.
-- |
-- | `ServiceInstance` is *open* (D-4, CUE open structs): one per (source ×
-- | unit), edges by raw string, `extra` carrying every unmodeled field so
-- | ingest→emit round-trips byte-for-byte. `validate` (Phase 2) unifies each
-- | against a *closed* shape and mints the tight types, whose constructors are
-- | unexported here — a `ServiceRef` is *proof* the id resolves, a `BootOrder`
-- | is the acyclicity certificate. Nothing outside `validate` may forge them.
-- |
-- | NOTE: `Service` (the merged validated node) and `Deployment` (the
-- | post-reconcile, pre-validate graph) are **provisional** — they are the
-- | outputs of `reconcile`/`validate`, designed in Phase 2-3 (the facet model
-- | is DECISIONS D-E3). The shapes here are first cuts that compile.
module Bosun.Service
  ( Source(..)
  , Role, mkRole, unRole
  , ServiceInstance
  , RawDep, RawRoute
  , ServiceRef, unServiceRef
  , BootOrder, unBootOrder
  , ResolvedDep, ResolvedRoute
  , Service
  , Deployment, mkDeployment, deploymentInstances
  , ValidatedDeploymentR, ValidatedDeployment, unValidatedDeployment
  ) where

import Prelude

import Bosun.Atoms (Host, ProjectSlug, RoutePath, ServiceId)
import Bosun.Edge (DepOrdering, Provenance, Requirement)
import Bosun.Executor (Executor)
import Bosun.Exposure (Exposure)
import Bosun.Health (Health, RestartPolicy)
import Bosun.Selector (Selector)
import Data.Argonaut.Core (Json)
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Generic.Rep (class Generic)
import Data.Map (Map)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)

-- | The additive `.deploy` overlay (§1) is *just another source*:
-- | `FromOverlay`.
data Source = FromCompose | FromRegistry | FromPlist | FromSystemd | FromK8s | FromOverlay
derive instance Eq Source
derive instance Ord Source
derive instance Generic Source _
instance Show Source where show = genericShow

-- | Opaque (the recompile test, §10): role names (`api`, `frontend`,
-- | `worker`) arrive as inventory *data*; the core never branches on a role
-- | semantically — it's only an identity discriminator in `(ProjectSlug, Role)`.
newtype Role = Role String
derive newtype instance Eq Role
derive newtype instance Ord Role
derive newtype instance Show Role

mkRole :: String -> Role
mkRole = Role

unRole :: Role -> String
unRole (Role s) = s

-- | An ingested dependency, target still a raw string (resolved by validate).
type RawDep = { to :: String, ordering :: Maybe DepOrdering, requirement :: Maybe Requirement }

-- | An ingested route, backend still a raw string.
type RawRoute = { to :: String, path :: RoutePath }

-- | LOOSE / OPEN: one per (source × unit). `extra` preserves the round-trip.
type ServiceInstance =
  { source    :: Source
  , project   :: Maybe ProjectSlug
  , localName :: String                  -- "tidal-frontend" or "psd3-tilted-radio"
  , role      :: Role
  , host      :: Maybe Host
  , executor  :: Executor
  , exposure  :: Exposure
  , health    :: Health
  , restart   :: RestartPolicy
  , rawDeps   :: Array RawDep
  , rawRoutes :: Array RawRoute
  , selectors :: Array Selector
  , extra     :: Map String Json          -- unmodeled passthrough (CUE freeform)
  }

-- | TIGHT: minted only by `validate`. Constructor unexported — past that
-- | boundary a dangling edge is unrepresentable.
newtype ServiceRef = ServiceRef ServiceId
derive newtype instance Eq ServiceRef
derive newtype instance Ord ServiceRef

unServiceRef :: ServiceRef -> ServiceId
unServiceRef (ServiceRef i) = i

-- | Stages: across stages = ordered; within a stage = independent (the
-- | Go-concurrency seam). Its mere existence ⇒ the dependency graph is acyclic.
newtype BootOrder = BootOrder (Array (NonEmptyArray ServiceRef))

unBootOrder :: BootOrder -> Array (NonEmptyArray ServiceRef)
unBootOrder (BootOrder s) = s

type ResolvedDep =
  { to          :: ServiceRef
  , ordering    :: Maybe DepOrdering
  , requirement :: Maybe Requirement
  , provenance  :: Provenance
  }

type ResolvedRoute = { to :: ServiceRef, path :: RoutePath }

-- | PROVISIONAL (Phase 2-3; facet model D-E3). The reconciled/validated node:
-- | identity resolved, edges resolved to `ServiceRef`.
type Service =
  { id        :: ServiceId
  , project   :: Maybe ProjectSlug
  , role      :: Role
  , executor  :: Executor
  , exposure  :: Exposure
  , health    :: Health
  , restart   :: RestartPolicy
  , deps      :: Array ResolvedDep
  , routes    :: Array ResolvedRoute
  , selectors :: Array Selector
  , extra     :: Map String Json
  }

-- | PROVISIONAL (§4-5). Post-reconcile, pre-validate. `reconcile` (Phase 3)
-- | will group the flat instances by `ServiceId` into logical services; for
-- | now a thin wrapper. `validate` turns this into a `ValidatedDeployment`.
newtype Deployment = Deployment (Array ServiceInstance)

mkDeployment :: Array ServiceInstance -> Deployment
mkDeployment = Deployment

deploymentInstances :: Deployment -> Array ServiceInstance
deploymentInstances (Deployment xs) = xs

type ValidatedDeploymentR =
  { services  :: Map ServiceId Service                   -- edges resolved to ServiceRef
  , bootOrder :: BootOrder                                -- existence ⇒ acyclic
  , routes    :: Map RoutePath ServiceRef                 -- every route backed; no drift
  , selectors :: Map Selector (NonEmptyArray ServiceRef)  -- non-empty; closed under Requires
  }

-- | Constructor unexported — only `validate` (Phase 2) mints one.
newtype ValidatedDeployment = ValidatedDeployment ValidatedDeploymentR

unValidatedDeployment :: ValidatedDeployment -> ValidatedDeploymentR
unValidatedDeployment (ValidatedDeployment r) = r
