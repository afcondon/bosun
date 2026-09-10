-- | Internal home of the tight types and their *minting* constructors.
-- |
-- | The public face is `Bosun.Service`, which re-exports everything here
-- | EXCEPT the tight constructors (`mkServiceRef`, `mkBootOrder`,
-- | `mkValidatedDeployment`). Only trusted core code — `Bosun.Validate` — may
-- | import this module and forge a `ServiceRef`/`BootOrder`/
-- | `ValidatedDeployment`. That is how "a `ServiceRef` is *proof* the id
-- | resolves" and "a `BootOrder`'s existence ⇒ acyclic" are enforced: nothing
-- | outside the validator can construct them.
-- |
-- | PHASE 2 NOTE: `LooseService`/`Service` carry only the *structural* fields
-- | `validate` reasons about (identity, host, exposure, readiness, edges,
-- | selectors). The rich fields (executor/health/restart/`extra`) live on
-- | `ServiceInstance` (the ingest output) and will be threaded back through
-- | the validated node when `reconcile` lands in Phase 3.
module Bosun.Service.Internal where

import Prelude

import Bosun.Artifact (Artifact)
import Bosun.Atoms (Host, ProjectSlug, RoutePath, ServiceId)
import Bosun.Edge (DepOrdering, Requirement)
import Bosun.Executor (Executor)
import Bosun.Reachability (Reachability)
import Bosun.Health (Health, Probe, RestartPolicy)
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

-- | Opaque (the recompile test, §10): role names arrive as inventory *data*;
-- | the core never branches on a role semantically.
newtype Role = Role String
derive newtype instance Eq Role
derive newtype instance Ord Role
derive newtype instance Show Role

mkRole :: String -> Role
mkRole = Role

unRole :: Role -> String
unRole (Role s) = s

-- | An ingested dependency, target still a raw string (resolved by reconcile).
type RawDep = { to :: String, ordering :: Maybe DepOrdering, requirement :: Maybe Requirement }

-- | An ingested route, backend still a raw string.
type RawRoute = { to :: String, path :: RoutePath }

-- | What `apply` needs to *launch* a service (Phase 6): the representative
-- | facet's `Executor` plus its source-local name (the compose service key /
-- | registry projectName) for `docker compose up -d <name>`. The compose
-- | profile is read off `Service.selectors`; the compose file path is supplied
-- | at the CLI edge. Carried on the loose/tight node so the validated graph
-- | knows how to start each proven service.
-- | `artifact` is the WHAT the launch realises (docs/ARTIFACTS.md): the single
-- | content declaration each substrate's run-spec derives from. `reconcile`
-- | fills it (from a declared `x-bosun.artifact`, falling back to `artifactOf`
-- | the representative executor), so `apply` can pull/ship a built artifact
-- | rather than build per host. `Nothing` for executors that name no content.
type LaunchSpec = { executor :: Executor, localName :: String, artifact :: Maybe Artifact }

-- | LOOSE / OPEN (§3.7): the ingest output, one per (source × unit). `extra`
-- | preserves the byte-identical round-trip. Consumed by `reconcile` (Phase 3).
type ServiceInstance =
  { source    :: Source
  , project   :: Maybe ProjectSlug
  , localName :: String
  , role      :: Role
  , host      :: Maybe Host
  , executor  :: Executor
  , artifact  :: Maybe Artifact   -- declared `x-bosun.artifact`, if any (else reconcile derives it)
  , reachability :: Reachability
  , health    :: Health
  , restart   :: RestartPolicy
  , rawDeps   :: Array RawDep
  , rawRoutes :: Array RawRoute
  , selectors :: Array Selector
  , extra     :: Map String Json
  }

-- | A reconciled dependency: identity resolved to a `ServiceId`, but not yet
-- | proven present (that is `validate`'s job).
type LooseDep =
  { to :: ServiceId, ordering :: Maybe DepOrdering, requirement :: Maybe Requirement }

type LooseRoute = { to :: ServiceId, path :: RoutePath }

-- | `validate`'s input node: identity resolved (keyed by `ServiceId`), edges
-- | by `ServiceId` (not yet proven to resolve), readiness hoisted out of
-- | `Health` for the gate check. Not yet acyclic / closed / backed.
type LooseService =
  { id        :: ServiceId
  , host      :: Maybe Host
  , reachability :: Reachability
  , readiness :: Probe
  , restart   :: RestartPolicy
  , deps      :: Array LooseDep
  , routes    :: Array LooseRoute
  , selectors :: Array Selector
  , launch    :: LaunchSpec
  }

-- | Post-reconcile, pre-validate. PROVISIONAL (§4-5): `reconcile` (Phase 3)
-- | produces this; `validate` turns it into a `ValidatedDeployment`.
newtype Deployment = Deployment (Array LooseService)

mkDeployment :: Array LooseService -> Deployment
mkDeployment = Deployment

deploymentServices :: Deployment -> Array LooseService
deploymentServices (Deployment xs) = xs

-- | TIGHT. Constructor minted only by the validator. Past that boundary a
-- | dangling edge is unrepresentable.
newtype ServiceRef = ServiceRef ServiceId
derive newtype instance Eq ServiceRef
derive newtype instance Ord ServiceRef

-- | TRUSTED minter — exported from Internal only, never from `Bosun.Service`.
mkServiceRef :: ServiceId -> ServiceRef
mkServiceRef = ServiceRef

unServiceRef :: ServiceRef -> ServiceId
unServiceRef (ServiceRef i) = i

-- | Stages: across = ordered; within a stage = independent (the Go-concurrency
-- | seam). Its mere existence ⇒ the dependency graph is acyclic.
newtype BootOrder = BootOrder (Array (NonEmptyArray ServiceRef))

-- | TRUSTED minter — Internal only.
mkBootOrder :: Array (NonEmptyArray ServiceRef) -> BootOrder
mkBootOrder = BootOrder

unBootOrder :: BootOrder -> Array (NonEmptyArray ServiceRef)
unBootOrder (BootOrder s) = s

type ResolvedDep =
  { to :: ServiceRef, ordering :: Maybe DepOrdering, requirement :: Maybe Requirement }

type ResolvedRoute = { to :: ServiceRef, path :: RoutePath }

-- | The validated node: edges resolved to `ServiceRef`.
type Service =
  { id        :: ServiceId
  , host      :: Maybe Host
  , reachability :: Reachability
  , readiness :: Probe
  , deps      :: Array ResolvedDep
  , routes    :: Array ResolvedRoute
  , selectors :: Array Selector
  , launch    :: LaunchSpec
  }

type ValidatedDeploymentR =
  { services  :: Map ServiceId Service                   -- referential integrity
  , bootOrder :: BootOrder                                -- existence ⇒ acyclic
  , routes    :: Map RoutePath ServiceRef                 -- every route backed
  , selectors :: Map Selector (NonEmptyArray ServiceRef)  -- non-empty; closed under Requires
  }

newtype ValidatedDeployment = ValidatedDeployment ValidatedDeploymentR

-- | TRUSTED minter — Internal only.
mkValidatedDeployment :: ValidatedDeploymentR -> ValidatedDeployment
mkValidatedDeployment = ValidatedDeployment

unValidatedDeployment :: ValidatedDeployment -> ValidatedDeploymentR
unValidatedDeployment (ValidatedDeployment r) = r
