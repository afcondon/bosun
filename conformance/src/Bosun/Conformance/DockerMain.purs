-- | The Docker-on-Go capability harness (docs/EXECUTORS.md mode 2, Go column).
-- |
-- | "Can the Go BINARY be a resident Docker observer?" A deliberately I/O-free
-- | harness: it hardcodes a tiny two-container deployment on the MacMini, builds
-- | the resident Docker substrate with the pure core + `dockerResident`, and
-- | mounts it via `runResident`. Because the deployment is hardcoded (no
-- | yaml/json/argv file reads), the foreign surface beyond the pure-core/Console
-- | set is exactly:
-- |
-- |   · `Bosun.CLI.Exec.execLineImpl`        — ssh `docker inspect` (os-exec)
-- |   · `Bosun.CLI.Resident.residentImpl`    — the /state + /control HTTP shim
-- |   · `Data.Argonaut.Parser._jsonParser`   — parse the ps JSON output
-- |
-- | …each with a hand-written Go twin (conformance/go/), copied into the build
-- | by scripts/go-docker.sh. Compiles + runs on node too (its existing `.js`
-- | foreigns), so the script runs BOTH columns and diffs their `/state` — the
-- | observe→parse→render pipeline must be byte-identical, the node≡Go discipline.
-- |
-- | Read-only: observe (`docker inspect`) is the only effect the script
-- | fires; `up`/`down` deploy verbs are held for an explicit go (the script only
-- | POSTs an UNKNOWN verb, to exercise the control callback round-trip with zero
-- | deploy effect).
module Bosun.Conformance.DockerMain where

import Prelude

import Bosun.Atoms (mkHost)
import Bosun.CLI.Docker (dockerResident)
import Bosun.CLI.Resident (runResident)
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Reachability (noNetwork)
import Bosun.Reconcile (reconcile)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Bosun.Target (defaultTargets)
import Bosun.Validate (validate)
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)

main :: Effect Unit
main = do
  let r = reconcile Map.empty fixture
  case toEither (validate r.deployment) of
    Left _ -> log "docker (Go column): fixture failed to validate (should not happen)"
    -- :3995 — clear of supervise (3996), docker's default (3997) and SDI (3998).
    Right vd -> do
      res <- dockerResident defaultTargets (Just 3995) vd
      runResident res

-- Two real MacMini compose services (the ps output keys them by `Service`,
-- which is the launch `localName`), so observe returns live container state.
fixture :: Array ServiceInstance
fixture = [ container "edge", container "website" ]

container :: String -> ServiceInstance
container name =
  { source: FromCompose
  , project: Nothing
  , localName: name
  , role: mkRole "container"
  , host: Just (mkHost "macmini")
  , executor: Container (ContainerSpec { source: Left (ImageRef name), internalPort: Nothing, publish: Nothing })
  , artifact: Nothing
  , reachability: noNetwork
  , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }
