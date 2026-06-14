-- | The `bosun` CLI. Phase 3A: runs the full pure pipeline — reconcile →
-- | validate → render — over a built-in fixture of the real §7 scenario, so
-- | `bosun check` produces a tangible drift report. Phase 3B swaps the fixture
-- | for the real adapters (compose YAML + registry JSON ingest).
module Bosun.CLI.Main where

import Prelude

import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkHost, mkPort, mkProjectSlug, mkServiceId)
import Bosun.Edge (Gate(..), Requirement(..))
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderReport)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Either (Either(..), either)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Partial.Unsafe (unsafePartial)

main :: Effect Unit
main = do
  log ("bosun " <> version <> " — check (built-in §7 fixture)")
  log ""
  let
    aliases = Map.singleton "tidal-frontend" (mkServiceId "uniform-romeo-romeo-juliet:frontend")
    r = reconcile aliases fixture
    vErrors = either identity (const []) (toEither (validate r.deployment))
  log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)

-- A slice of the real rig: the tilted-radio two-facet divergence, plus a
-- minard tier whose frontend waits on the backend's health while the backend
-- publishes no readiness signal (an UncheckableGate — §7.4's "healthchecks
-- describe liveness but not ordering").
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
