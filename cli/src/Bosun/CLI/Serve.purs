-- | The resident front of `bosun serve` (BOSUN-SERVE.md §3a — the proxy model).
-- |
-- | This is the one place the no-Aff seam yields: a lazy-spawn reverse proxy is
-- | inherently an event loop (it binds ports and stays resident, spawning
-- | backends on demand), which a straight-line synchronous edge cannot express.
-- | So the event loop is quarantined in ONE foreign shim (`Serve.js`), driven
-- | entirely by the pure `ServePlan` (`Bosun.Serve`): PureScript decides
-- | admission, port-rewrite, and idle policy; the shim does the mechanical
-- | bind / spawn / poll / proxy / reap. P3 swaps this JS shim for a Go one
-- | (`httputil.ReverseProxy`) driven by the *same* plan.
-- |
-- | `serveImpl` takes the admitted `Route`s (all-primitive records, so they
-- | cross to JS with no decoding) and never returns — it is the resident loop.
module Bosun.CLI.Serve
  ( runServe
  ) where

import Prelude

import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.CLI.IO (readJsonFile)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderServePlan)
import Bosun.Serve (Route, servePlan)
import Bosun.Version (version)
import Data.Array as A
import Data.Map as Map
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)

-- The resident reverse-proxy loop. Binds each route's public port and, on first
-- request, spawns the backend (rewritten onto the internal port), waits for it
-- to listen, then proxies. Idle backends are SIGTERMed and respawned on the
-- next request. Does not return.
foreign import serveImpl :: EffectFn1 (Array Route) Unit

-- | `bosun serve <registry.json>` — ingest the registry, reconcile, run
-- | admission control (`servePlan`), print the report, then hand the admitted
-- | routes to the resident shim. A rejected service is reported and simply not
-- | bound; the router still comes up for everything that *is* routable.
runServe :: String -> Effect Unit
runServe registryPath = do
  registryJson <- readJsonFile registryPath
  let
    insts = ingestRegistry registryJson
    r = reconcile Map.empty insts
    plan = servePlan r.deployment
  log ("bosun " <> version <> " — serve " <> registryPath)
  log ""
  log (renderServePlan plan)
  log ""
  if A.null plan.routes then
    log "serve: no routable services — nothing to bind. Exiting."
  else do
    log ("serve: binding " <> show (A.length plan.routes) <> " port(s); lazy-spawn on first request. Ctrl-C to stop.")
    log ""
    runEffectFn1 serveImpl plan.routes
