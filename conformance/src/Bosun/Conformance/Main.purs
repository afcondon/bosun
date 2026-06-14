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
import Bosun.Exposure (Exposure(..))
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Plan (Status(..), plan)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderPlan, renderReport)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
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

-- | The plan column (BUILD-PLAN Phase 5). A clean three-tier deployment that
-- | validates, against an observed snapshot where the api crashed: the base
-- | pass turns `Failed` into `Restart … Crashed`, and D-E5 propagates a `Stop`
-- | backward along the worker's `BindsTo` edge — all pure, so node and
-- | backend-go must render this byte-identically too.
planReport :: String
planReport = case toEither (validate (reconcile Map.empty planFixture).deployment) of
  Left _ -> "plan fixture failed to validate (should not happen)"
  Right vd ->
    renderPlan (plan vd { desired: vd, recorded: Nothing, observed })
  where
  observed = Map.fromFoldable
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
      , exposure = HostPort (port_ 5432)
      , health = inst.health { readiness = TcpConnect (port_ 5432) }
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "store")
      , localName = "store-api"
      , role = mkRole "api"
      , exposure = HostPort (port_ 3000)
      , health = inst.health { readiness = HttpGet { port: port_ 3000, path: "/health", expectStatus: 200 } }
      , rawDeps = [ { to: "store:db", ordering: Nothing, requirement: Just (Requires OnReady) } ]
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "store")
      , localName = "store-worker"
      , role = mkRole "worker"
      , exposure = NoNetwork
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
      , exposure = HostPort (port_ 3013)
      }
  , inst
      { source = FromCompose
      , localName = "tidal-frontend"
      , host = Just (mkHost "macmini")
      , executor = Container (ContainerSpec { source: Left (ImageRef "tidal-frontend"), internalPort: Nothing, publish: Nothing })
      , exposure = NoNetwork
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-backend"
      , role = mkRole "api"
      , host = Just (mkHost "mbp")
      , exposure = HostPort (port_ 3000)
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-frontend"
      , host = Just (mkHost "mbp")
      , exposure = HostPort (port_ 3001)
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
  , exposure: NoNetwork
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
