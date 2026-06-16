-- | purescript-go conformance harness (BUILD-PLAN Phase 4).
-- |
-- | The pure Detect pipeline over a fixed fixture, printed. No I/O beyond the
-- | final `log`, so this compiles on any backend that supports the pure-core
-- | library surface. Run via node AND via backend-go; the output must be
-- | byte-identical (the signal-box conformance pattern). The fixture mirrors
-- | the CLI demo: the §7 tilted-radio two-facet divergence + a minard tier
-- | with an uncheckable gate.
module Bosun.Conformance.Main where

import Prelude

import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkHost, mkPort, mkProjectSlug, mkServiceId)
import Bosun.Edge (Gate(..), Requirement(..))
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Reachability (hostPort, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Apply (applyScript)
import Bosun.Plan (Snapshot, Status(..), plan)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderPlan, renderReport, renderScript)
import Bosun.Service (ServiceInstance, Source(..), ValidatedDeployment, mkRole)
import Bosun.Validate (validate)
import Data.Either (Either(..), either)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Partial.Unsafe (unsafePartial)

main :: Effect Unit
main = do
  let
    aliases = Map.singleton "tidal-frontend" (mkServiceId "uniform-romeo-romeo-juliet:frontend")
    r = reconcile aliases fixture
    vErrors = either identity (const []) (toEither (validate r.deployment))
  log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
  log ""
  log "--- plan over a valid fixture + observed snapshot ---"
  log planReport
  log ""
  log "--- apply script for the same plan (Phase 6B) ---"
  log applyReport

-- | The plan column (BUILD-PLAN Phase 5). A clean three-tier deployment that
-- | validates, against an observed snapshot where the api crashed: the base
-- | pass turns `Failed` into `Restart … Crashed`, and D-E5 propagates a `Stop`
-- | backward along the worker's `BindsTo` edge — all pure, so node and
-- | backend-go must render this byte-identically too.
planReport :: String
planReport = withPlanFixture \vd ->
  renderPlan (plan vd { desired: vd, recorded: Nothing, observed: planObserved })

-- | The apply column (BUILD-PLAN Phase 6B). The *same* plan rendered as the
-- | command script `apply` would run — pure `Plan -> Array StagedCommand`, so
-- | the backend-go binary must emit the byte-identical docker/ssh/process
-- | script the node binary does. This is the headline claim, gated.
applyReport :: String
applyReport = withPlanFixture \vd ->
  renderScript (applyScript vd (plan vd { desired: vd, recorded: Nothing, observed: planObserved }))

withPlanFixture :: (ValidatedDeployment -> String) -> String
withPlanFixture f = case toEither (validate (reconcile Map.empty planFixture).deployment) of
  Left _ -> "plan fixture failed to validate (should not happen)"
  Right vd -> f vd

planObserved :: Snapshot
planObserved = Map.fromFoldable
  [ Tuple (mkServiceId "store:db") Running
  , Tuple (mkServiceId "store:api") Failed
  , Tuple (mkServiceId "store:worker") Running
  ]

planFixture :: Array ServiceInstance
planFixture =
  [ inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "store")
      , localName = "store-db"
      , role = mkRole "db"
      , reachability = hostPort (port_ 5432)
      , executor = Process { cwd: absPath "/srv/store-db", command: "postgres", env: [] }
      , health = inst.health { readiness = TcpConnect (port_ 5432) }
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "store")
      , localName = "store-api"
      , role = mkRole "api"
      , reachability = hostPort (port_ 3000)
      , executor = Process { cwd: absPath "/srv/store-api", command: "node server.js", env: [] }
      , health = inst.health { readiness = HttpGet { port: port_ 3000, path: "/health", expectStatus: 200 } }
      , rawDeps = [ { to: "store:db", ordering: Nothing, requirement: Just (Requires OnReady) } ]
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "store")
      , localName = "store-worker"
      , role = mkRole "worker"
      , reachability = noNetwork
      , executor = Process { cwd: absPath "/srv/store-worker", command: "node worker.js", env: [] }
      , rawDeps = [ { to: "store:api", ordering: Nothing, requirement: Just BindsTo } ]
      }
  ]

fixture :: Array ServiceInstance
fixture =
  [ inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "uniform-romeo-romeo-juliet")
      , localName = "psd3-tilted-radio"
      , host = Just (mkHost "mbp")
      , executor = Process { cwd: absPath "/Users/afc/work/afc-work/purescript-hylograph-showcases/psd3-tilted-radio", command: "npx serve", env: [] }
      , reachability = hostPort (port_ 3013)
      }
  , inst
      { source = FromCompose
      , localName = "tidal-frontend"
      , host = Just (mkHost "macmini")
      , executor = Container (ContainerSpec { source: Left (ImageRef "tidal-frontend"), internalPort: Nothing, publish: Nothing })
      , reachability = noNetwork
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-backend"
      , role = mkRole "api"
      , host = Just (mkHost "mbp")
      , reachability = hostPort (port_ 3000)
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-frontend"
      , host = Just (mkHost "mbp")
      , reachability = hostPort (port_ 3001)
      , rawDeps = [ { to: "minard:api", ordering: Nothing, requirement: Just (Requires OnHealthy) } ]
      }
  ]

inst :: ServiceInstance
inst =
  { source: FromRegistry
  , project: Nothing
  , localName: "svc"
  , role: mkRole "frontend"
  , host: Just (mkHost "mbp")
  , executor: Unmanaged "svc"
  , reachability: noNetwork
  , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))
