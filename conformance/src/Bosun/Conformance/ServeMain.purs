-- | BUILD-PLAN Phase 7 (P3, Go column) — "can the Go BINARY be the router?"
-- |
-- | The resident-server counterpart to ApplyMain. It hardcodes a tiny routable
-- | fixture, runs the *pure* core (`reconcile -> servePlan`) to the admitted
-- | `Route`s, prints the admission report, then hands the routes to a single
-- | foreign `serveImpl` — the resident reverse proxy. Because the fixture is
-- | hardcoded, the ONLY foreign beyond the pure-core/Console surface is
-- | `serveImpl`, so the backend-go transpile needs exactly one new Go shim
-- | (`conformance/go/bosun_serve_foreign.go`), the Go twin of
-- | `Bosun.CLI.Serve`'s JS shim.
-- |
-- | NOTE on concurrency: `servePlan` is evaluated ONCE here, at startup, so the
-- | route data the resident loop serves is already forced — the per-request
-- | goroutines do pure-Go networking, not PureScript thunk-forcing. The
-- | thread-safety the sync.Once runtime fix buys (RaceSpike) matters for the
-- | general case where a handler re-enters the core; this harness keeps the hot
-- | path pure Go and proves the resident proxy itself, under `-race`.
-- |
-- | Distinct port/dir (8775 / /tmp/bosun-serve-go) from the node CLI demo
-- | (8190) and the apply harness (8773/8774), so a Go-routed backend is
-- | unambiguously this binary's.
module Bosun.Conformance.ServeMain where

import Prelude

import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkHost, mkPort, mkProjectSlug)
import Bosun.Executor (Executor(..))
import Bosun.Reachability (hostPort)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderServePlan)
import Bosun.Serve (Route, servePlan)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Partial.Unsafe (unsafePartial)

-- The resident reverse-proxy edge, declared HERE so its Go shim is
-- `Bosun_Conformance_ServeMain_serveImpl` — one self-contained foreign. It does
-- not return (the router lives until the process is killed).
foreign import serveImpl :: EffectFn1 (Array Route) Unit

main :: Effect Unit
main = do
  let
    r = reconcile Map.empty helloFixture
    p = servePlan r.deployment
  log "serve (Go column):"
  log (renderServePlan p)
  log ("serve (Go column): binding " <> show (Array.length p.routes) <> " port(s); lazy-spawn on first request.")
  runEffectFn1 serveImpl p.routes

helloFixture :: Array ServiceInstance
helloFixture = [ server "serve-go-site" "site" 8775 ]

-- A plain (NOT backgrounded) Process command: serve MANAGES the child's
-- lifetime (it holds the handle to reap on idle), so unlike apply it does not
-- daemonize. `servePlan` rewrites 8775 -> 28775 (public + 20000).
server :: String -> String -> Int -> ServiceInstance
server name role port =
  { source: FromRegistry
  , project: Just (mkProjectSlug "servego")
  , localName: name
  , role: mkRole role
  , host: Just (mkHost "mbp")
  , executor: Process
      { cwd: absPath "/tmp/bosun-serve-go"
      , command: "python3 -m http.server " <> show port
      , env: []
      }
  , artifact: Nothing
  , reachability: hostPort (port_ port)
  , health: { liveness: NoProbe, readiness: TcpConnect (port_ port), startup: Nothing }
  , restart: { base: Always, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))
