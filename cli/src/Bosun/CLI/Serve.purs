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
  , runServeLive
  , runServePlan
  , registryUrl
  ) where

import Prelude

import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.CLI.IO (readJsonFile, readJsonUrl)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderReject, renderServePlan)
import Bosun.Serve (Redirect, Route, ServeDiff, ServePlan, serveDiff, servePlan)
import Bosun.Version (version)
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Map as Map
import Data.Maybe (Maybe, maybe)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Uncurried (EffectFn1, runEffectFn1)

-- | What the resident shim binds: proxy `routes` (lazy-spawn + reverse-proxy,
-- | WebSocket-aware), `redirects` (bind + answer 421 → tailnet URL), and a
-- | read-only JSON `/state` endpoint on `statusPort`. `reload` is the SIGHUP
-- | hook: the shim calls it to re-read+re-plan the registry and get back the
-- | typed `ServeDiff` to apply (bind/unbind/rebind).
-- | A rejected service, rendered for /state (Bosun's Chair shows the full
-- | three-way; rejections aren't bound, so they only appear here, not as a
-- | listener). Static from the initial plan — a reload refreshes routes/redirects.
type RejectInfo = { serviceId :: String, reason :: String }

type ServeConfig =
  { routes     :: Array Route
  , redirects  :: Array Redirect
  , rejected   :: Array RejectInfo
  , statusPort :: Int
  , reload     :: Effect ServeDiff
  }

-- The resident loop. Binds every public port and, on first request to a proxy
-- route, spawns the backend (rewritten onto the internal port), waits for it to
-- listen, then proxies (HTTP + WebSocket upgrade). Idle backends are SIGTERMed
-- and respawned on the next request. On SIGHUP it calls `reload` and applies the
-- diff. Does not return.
foreign import serveImpl :: EffectFn1 ServeConfig Unit

-- | The read-only JSON status endpoint, off the public-port range and clear of
-- | SDI's own :3998.
statusPort :: Int
statusPort = 3997

-- | The live Marginalia registry endpoint — the same `/api/ports` SDI reads.
registryUrl :: String
registryUrl = "http://andrews-mac-mini:3100/api/ports"

-- | `bosun serve <registry.json>` — ingest a registry dump from a file.
runServe :: String -> Effect Unit
runServe path = serveFrom ("serve " <> path) (readJsonFile path)

-- | `bosun serve` (no arg) — fetch the LIVE registry from the Marginalia API and
-- | serve it, the drop-in SDI replacement.
runServeLive :: Effect Unit
runServeLive = serveFrom ("serve " <> registryUrl <> " (live)") (readJsonUrl registryUrl)

-- | `bosun serve --plan [registry]` — print the admission report and exit
-- | (non-resident). The report-only view: inspect what serve WOULD bind / 421 /
-- | reject without holding any ports. Deterministic output (just the report),
-- | which the adversarial corpus golden-diffs.
runServePlan :: Maybe String -> Effect Unit
runServePlan src = do
  json <- maybe (readJsonUrl registryUrl) readJsonFile src
  log (renderServePlan (planOf json))

planOf :: Json -> ServePlan
planOf json = servePlan (reconcile Map.empty (ingestRegistry json)).deployment

-- | ingest → reconcile → admission control (`servePlan`) → print the report →
-- | hand the plan to the resident shim. `reread` is the (repeatable) source read,
-- | so SIGHUP can re-run it; the shim's `reload` diffs the fresh plan against the
-- | last one (held in a `Ref`) and applies the change. Rejected services are
-- | reported and not bound; the router still comes up for everything routable or
-- | redirectable.
serveFrom :: String -> Effect Json -> Effect Unit
serveFrom label reread = do
  plan <- planOf <$> reread
  log ("bosun " <> version <> " — " <> label)
  log ""
  log (renderServePlan plan)
  log ""
  if A.null plan.routes && A.null plan.redirects then
    log "serve: nothing to bind (no routable or redirectable services). Exiting."
  else do
    log
      ( "serve: binding " <> show (A.length plan.routes) <> " proxy + "
          <> show (A.length plan.redirects) <> " redirect port(s); /state on :"
          <> show statusPort <> ". SIGHUP to reload. Lazy-spawn on first request. Ctrl-C to stop."
      )
    log ""
    ref <- Ref.new plan
    let
      reload = do
        log "serve: SIGHUP — re-reading the registry"
        fresh <- planOf <$> reread
        previous <- Ref.read ref
        Ref.write fresh ref
        pure (serveDiff previous fresh)
      rejected = plan.rejected <#> \r -> { serviceId: r.serviceId, reason: renderReject r.reason }
    runEffectFn1 serveImpl { routes: plan.routes, redirects: plan.redirects, rejected, statusPort, reload }
