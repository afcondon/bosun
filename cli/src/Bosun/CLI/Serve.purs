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
  , runReload
  , statusPort
  , registryUrl
  ) where

import Prelude

import Bosun.Adapters.Registry (ingestRegistry, registryClaims)
import Bosun.CLI.IO (getJsonUrl, postJsonUrl, readJsonFile, readJsonUrl)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderDrift, renderDriftKind, renderReject, renderServePlan)
import Bosun.Serve (DriftKind(..), PortDrift, Redirect, Route, ServePlan, planDrift, serveDiff, servePlan)
import Bosun.Version (version)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Foldable (for_)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Nullable (Nullable, toNullable)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Foreign.Object as FO

-- | What the resident shim binds: proxy `routes` (lazy-spawn + reverse-proxy,
-- | WebSocket-aware), `redirects` (bind + answer 421 → tailnet URL), and a
-- | read-only JSON `/state` endpoint on `statusPort`. `reload` is the SIGHUP
-- | hook: the shim calls it to re-read+re-plan the registry and get back the
-- | typed `ServeDiff` to apply (bind/unbind/rebind).
-- | A rejected service, rendered for /state (Bosun's Chair shows the full
-- | three-way; rejections aren't bound, so they only appear here, not as a
-- | listener). Carries `publicPort` so the Chair can join a refusal to the
-- | registry row that caused it. `Nullable`, not `Maybe`: this record is
-- | JSON.stringify'd by the shim, and a `Maybe` would cross as `{}`/`{value0:…}`.
-- |
-- | REFRESHED BY RELOAD (fixed 2026-08-17). It used to be captured once from the
-- | startup plan, so a row that became unroutable while the router was resident
-- | appeared in NO bucket of /state — invisible rather than refused. That is
-- | half of why itajara @3028 could not be found anywhere.
type RejectInfo = { serviceId :: String, publicPort :: Nullable Int, reason :: String }

-- | One public port where the registry ON DISK and the router's held plan
-- | disagree, flattened for /state. `kind` is the wire token (`driftTag`),
-- | `note` the operator sentence — same convention as `RejectInfo.reason`
-- | crossing as rendered text, because /state's JSON is assembled in the shim
-- | and there is no codec to thread through it.
type DriftInfo = { serviceId :: String, publicPort :: Int, kind :: String, note :: String }

-- | What a reload did, plus the refreshed refusal list (a reload can turn a
-- | route into a refusal, and /state must say so).
type ReloadResult =
  { unbind :: Array Int
  , bindRoutes :: Array Route
  , bindRedirects :: Array Redirect
  , rejected :: Array RejectInfo
  }

type ServeConfig =
  { routes :: Array Route
  , redirects :: Array Redirect
  , rejected :: Array RejectInfo
  , statusPort :: Int
  , source :: String
  -- the registry file, for mtime-staleness; `null` when the source is the live
  -- URL (nothing on disk to stat, so drift is TTL-polled instead).
  , sourceFile :: Nullable String
  , reload :: Effect ReloadResult
  -- a DRY re-read + re-plan + compare against the held plan: what a reload
  -- WOULD change, without changing anything. The shim calls it for /state.
  , drift :: Effect (Array DriftInfo)
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
runServe path = serveFrom ("serve " <> path) path (Just path) (readJsonFile path)

-- | `bosun serve` (no arg) — fetch the LIVE registry from the Marginalia API and
-- | serve it, the drop-in SDI replacement.
runServeLive :: Effect Unit
runServeLive =
  serveFrom ("serve " <> registryUrl <> " (live)") registryUrl Nothing (readJsonUrl registryUrl)

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
serveFrom :: String -> String -> Maybe String -> Effect Json -> Effect Unit
serveFrom label source sourceFile reread = do
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
          <> show statusPort <> ". SIGHUP (or `bosun reload`) to reload. Lazy-spawn on first request. Ctrl-C to stop."
      )
    log ""
    ref <- Ref.new plan
    let
      reload = do
        log "serve: reload — re-reading the registry"
        fresh <- planOf <$> reread
        previous <- Ref.read ref
        Ref.write fresh ref
        let d = serveDiff previous fresh
        pure
          { unbind: d.unbind
          , bindRoutes: d.bindRoutes
          , bindRedirects: d.bindRedirects
          , rejected: rejectInfo fresh
          }
      -- read-only: the held plan is NOT replaced, so /state can report the
      -- disagreement without silently acting on it.
      drift = do
        held <- Ref.read ref
        json <- reread
        pure (map driftInfo (planDrift (registryClaims json) held (planOf json)))
    runEffectFn1 serveImpl
      { routes: plan.routes
      , redirects: plan.redirects
      , rejected: rejectInfo plan
      , statusPort
      , source
      , sourceFile: toNullable sourceFile
      , reload
      , drift
      }

rejectInfo :: ServePlan -> Array RejectInfo
rejectInfo plan = plan.rejected <#> \r ->
  { serviceId: r.serviceId, publicPort: toNullable r.publicPort, reason: renderReject r.reason }

driftInfo :: PortDrift -> DriftInfo
driftInfo d =
  { serviceId: d.serviceId
  , publicPort: d.publicPort
  , kind: driftTag d.kind
  , note: renderDriftKind d.kind
  }

-- The wire token for a drift kind (`/state`'s `drift[].kind`) — the boundary
-- encoding, hand-rolled beside the shim that stringifies it.
driftTag :: DriftKind -> String
driftTag = case _ of
  Unrouted -> "unrouted"
  Altered -> "altered"
  Departed -> "departed"
  Unaccounted -> "unaccounted"

-- ── bosun reload [--port N] ─────────────────────────────────────────────────

-- | Bring a RUNNING router in line with the registry on disk, from the command
-- | line. The mechanism (`POST /control/reload` → `serveDiff`) has existed since
-- | P2; what was missing was a way to invoke it that an operator would find, and
-- | a report of whether it worked. The chair-server calls the same endpoint on
-- | every registry write — this is for the other two cases: the router was down
-- | at write time, or someone edited `fleet.json` by hand.
-- |
-- | Exit is quiet-on-success/loud-on-failure text, not a status code: the router
-- | being absent is the ordinary case on a fresh machine, and it prints what to
-- | do about it.
runReload :: Maybe Int -> Effect Unit
runReload mport = do
  let
    port = fromMaybe statusPort mport
    base = "http://localhost:" <> show port
  log ("bosun " <> version <> " — reload " <> base)
  res <- postJsonUrl (base <> "/control/reload")
  if not res.ok then do
    log ("  ✗ the router on :" <> show port <> " did not answer — " <> res.error)
    log "    Nothing was routed. The registry on disk is still the source of truth;"
    log "    the next `bosun serve` start will admit it. (Check the router is up.)"
  else if not (boolAt "ok" res.body) then
    log ("  ✗ reload failed: " <> stringAt "error" res.body)
  else do
    log
      ( "  ↻ unbound " <> show (A.length (intsAt "unbound" res.body))
          <> ", bound " <> show (A.length (intsAt "boundRoutes" res.body)) <> " proxy + "
          <> show (A.length (intsAt "boundRedirects" res.body)) <> " redirect"
      )
    for_ (intsAt "boundRoutes" res.body) \p -> log ("    + :" <> show p <> " now routed")
    for_ (intsAt "unbound" res.body) \p -> log ("    - :" <> show p <> " unbound")
    -- Read /state back: agreement is the claim worth making, and only the
    -- router can make it.
    st <- getJsonUrl (base <> "/state")
    if not st.ok then log ("  ? could not read /state back — " <> st.error)
    else case driftOf st.body of
      [] -> log "  ✓ the registry and the router agree."
      ds -> do
        log ""
        log (renderDrift ds)

-- ── minimal /state + /control/reload response reading ───────────────────────
-- The router's control surface is hand-rolled JSON in the foreign shim (it has
-- no PureScript codec to share), so read it back with argonaut primitives and
-- total defaults: a malformed field degrades to "nothing to report", never a
-- crash in the tool whose job is to report.

boolAt :: String -> Json -> Boolean
boolAt k j = fromMaybe false (J.toObject j >>= FO.lookup k >>= J.toBoolean)

stringAt :: String -> Json -> String
stringAt k j = fromMaybe "(no detail)" (J.toObject j >>= FO.lookup k >>= J.toString)

intsAt :: String -> Json -> Array Int
intsAt k j = A.mapMaybe asInt (fromMaybe [] (J.toObject j >>= FO.lookup k >>= J.toArray))

asInt :: Json -> Maybe Int
asInt j = J.toNumber j >>= Int.fromNumber

-- The inverse of `driftTag` — the boundary decode, so the CLI can print the
-- same operator sentences (`renderDrift`) the Chair shows.
driftOf :: Json -> Array PortDrift
driftOf j = A.mapMaybe entry (fromMaybe [] (J.toObject j >>= FO.lookup "drift" >>= J.toArray))
  where
  entry d = do
    o <- J.toObject d
    port <- asInt =<< FO.lookup "publicPort" o
    sid <- J.toString =<< FO.lookup "serviceId" o
    kind <- driftKindOf =<< J.toString =<< FO.lookup "kind" o
    pure { publicPort: port, serviceId: sid, kind }

driftKindOf :: String -> Maybe DriftKind
driftKindOf = case _ of
  "unrouted" -> Just Unrouted
  "altered" -> Just Altered
  "departed" -> Just Departed
  "unaccounted" -> Just Unaccounted
  _ -> Nothing
