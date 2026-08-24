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
  , runWhere
  , statusPort
  , registryUrl
  ) where

import Prelude

import Bosun.Adapters.Registry (ingestRegistry, registryClaims, registryHints)
import Bosun.CLI.IO (getJsonUrl, postJsonUrl, readJsonFile, readJsonUrl)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderDrift, renderDriftKind, renderReject, renderServePlan)
import Bosun.Health (Probe(..))
import Bosun.Protocol (Locator, whereResultCodec)
import Bosun.Serve (Broker, DriftKind(..), PortDrift, Redirect, Route, ServePlan, brokerStopVerdict, planDrift, serveDiff, servePlanWith, stopVerdictTag)
import Bosun.Version (version)
import Bosun.Atoms (unAbsPath, unPort)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as J
import Data.Codec.Argonaut as CA
import Data.Array as A
import Data.Foldable (for_)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Either (Either(..))
import Data.Function.Uncurried (Fn1, Fn2, mkFn1, mkFn2)
import Data.Nullable (Nullable, toMaybe, toNullable)
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

-- | A BROKERED service, flattened for the shim. `Nullable`, not `Maybe`, for the
-- | same reason as `RejectInfo`: the shim reads these fields directly and puts
-- | several of them into JSON it stringifies itself.
-- |
-- | The `probe*` trio is `Bosun.Health.Probe` flattened to a tag plus its one
-- | argument — the shim must not carry a sum type, but it must know WHICH check
-- | to make, because `probe: "none"` is a real answer (nothing was checked) and
-- | not a failed one.
type BrokerInfo =
  { serviceId :: String
  , publicPort :: Nullable Int
  , cwd :: String
  , launchCommand :: String
  , transport :: String
  , host :: Nullable String
  , port :: Nullable Int
  , path :: Nullable String
  , url :: Nullable String
  , probe :: String
  , probePort :: Nullable Int
  , probePath :: Nullable String
  -- What `/control/stop` may do to THIS broker, given the router's own child
  -- handle and a probe just made: `Bosun.Serve.brokerStopVerdict`, closed over
  -- this row's real `Probe`. It rides on the record rather than on `ServeConfig`
  -- so the decision keeps the typed probe instead of a tag round-trip — the
  -- shim has only tags to hand back, and reconstructing a `Probe` from one
  -- would be inventing a fact to satisfy a signature.
  --
  -- Passed IN for the same reason `whereJson` is: this is a DECISION, and
  -- decisions live in the core beside the admission rules, not as an if-chain
  -- at the edge where nothing can test them.
  , stopVerdict :: Fn2 Boolean Boolean String
  }

-- | The `/where` answer, flattened the same way. The shim fills in the three
-- | fields only it can know (`ready`, `started`, `detail`) and hands the record
-- | back through `whereJson` to be encoded — so the JSON on the wire is produced
-- | by `Bosun.Protocol.whereResultCodec` and not by a second, drifting,
-- | hand-rolled object literal in the shim.
type WhereInfo =
  { service :: String
  , mediation :: String
  , ready :: Boolean
  , started :: Boolean
  , probe :: String
  , detail :: String
  , transport :: String
  , host :: Nullable String
  , port :: Nullable Int
  , path :: Nullable String
  , url :: Nullable String
  }

-- | What a reload did, plus the refreshed refusal list (a reload can turn a
-- | route into a refusal, and /state must say so).
-- |
-- | `brokers` is the WHOLE brokered list, not a delta. A brokered service with
-- | no public port owns no listener, so there is nothing for a port-keyed diff
-- | to say about it (`Bosun.Serve.ServeDiff`); the shim replaces its table
-- | wholesale and only the `bindBrokers` subset is actually re-listened.
type ReloadResult =
  { unbind :: Array Int
  , bindRoutes :: Array Route
  , bindBrokers :: Array BrokerInfo
  , brokers :: Array BrokerInfo
  , bindRedirects :: Array Redirect
  , rejected :: Array RejectInfo
  }

type ServeConfig =
  { routes :: Array Route
  , brokers :: Array BrokerInfo
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
  -- the `/where` encoder, passed IN rather than hand-rolled in the shim: the
  -- wire shape is a codec value in `Bosun.Protocol`, shared with every consumer
  -- that decodes it, and this is how the shim reaches it.
  , whereJson :: Fn1 WhereInfo Json
  }

-- The resident loop. Binds every public port and, on first request to a proxy
-- route, spawns the backend (rewritten onto the internal port), waits for it to
-- listen, then proxies (HTTP + WebSocket upgrade). Idle backends are SIGTERMed
-- and respawned on the next request. On SIGHUP it calls `reload` and applies the
-- diff. Does not return.
foreign import serveImpl :: EffectFn1 ServeConfig Unit

-- | The read-only JSON status endpoint, off the public-port range and clear of
-- | SDI's own :3998. A constant, not an option: it is the address the Chair,
-- | chair-server and `bosun reload` all know without being told.
statusPort :: Int
statusPort = 3997

-- | `statusPort`, unless `BOSUN_SERVE_STATUS_PORT` says otherwise. The override
-- | exists so a SCRATCH router can be stood up beside the live one — a router
-- | whose whole job is holding ports is otherwise untestable without taking the
-- | real one down. Both the resident loop and `bosun reload` read it, so a test
-- | reloads the router it started.
foreign import resolveStatusPort :: Effect Int

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

-- The registry is read TWICE on purpose: once through the IR (`ingestRegistry`
-- → reconcile → the deployment `servePlanWith` judges) and once raw, for the
-- per-row router hints (`registryHints`) that are instructions to the router
-- rather than facts about the service. Same shape, and the same reason, as
-- `registryClaims` in the drift check.
planOf :: Json -> ServePlan
planOf json = servePlanWith (registryHints json) (reconcile Map.empty (ingestRegistry json)).deployment

-- | ingest → reconcile → admission control (`servePlan`) → print the report →
-- | hand the plan to the resident shim. `reread` is the (repeatable) source read,
-- | so SIGHUP can re-run it; the shim's `reload` diffs the fresh plan against the
-- | last one (held in a `Ref`) and applies the change. Rejected services are
-- | reported and not bound; the router still comes up for everything routable or
-- | redirectable.
serveFrom :: String -> String -> Maybe String -> Effect Json -> Effect Unit
serveFrom label source sourceFile reread = do
  plan <- planOf <$> reread
  status <- resolveStatusPort
  log ("bosun " <> version <> " — " <> label)
  log ""
  log (renderServePlan plan)
  log ""
  if A.null plan.routes && A.null plan.redirects then
    log "serve: nothing to bind (no routable or redirectable services). Exiting."
  else do
    log
      ( "serve: binding " <> show (A.length plan.routes) <> " proxy + "
          <> show (A.length plan.brokered) <> " broker + "
          <> show (A.length plan.redirects) <> " redirect port(s); /state + /where on :"
          <> show status <> ". SIGHUP (or `bosun reload`) to reload. Lazy-spawn on first request. Ctrl-C to stop."
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
          , bindBrokers: map brokerInfo d.bindBrokers
          , brokers: map brokerInfo fresh.brokered
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
      , brokers: map brokerInfo plan.brokered
      , redirects: plan.redirects
      , rejected: rejectInfo plan
      , statusPort: status
      , source
      , sourceFile: toNullable sourceFile
      , reload
      , drift
      , whereJson: mkFn1 encodeWhere
      }

rejectInfo :: ServePlan -> Array RejectInfo
rejectInfo plan = plan.rejected <#> \r ->
  { serviceId: r.serviceId, publicPort: toNullable r.publicPort, reason: renderReject r.reason }

-- | Flatten a `Broker` for the shim: `Maybe` → `Nullable`, and the readiness
-- | `Probe` → a tag plus its argument. The shim decides nothing here; it is
-- | handed the check to make, not the information to choose one from.
brokerInfo :: Broker -> BrokerInfo
brokerInfo b =
  { serviceId: b.serviceId
  , publicPort: toNullable b.publicPort
  , cwd: b.cwd
  , launchCommand: b.launchCommand
  , transport: b.at.transport
  , host: toNullable b.at.host
  , port: toNullable b.at.port
  , path: toNullable b.at.path
  , url: toNullable b.at.url
  , probe: probeTag b.probe
  , probePort: toNullable (probeTcpPort b.probe)
  , probePath: toNullable (probeSocketPath b.probe)
  , stopVerdict: mkFn2 \hasChild alive -> stopVerdictTag (brokerStopVerdict hasChild alive b.probe)
  }

-- The wire tags for the probes `serve` can actually make. Everything else
-- (`HttpGet`, `ExecCmd`, `ProcessAlive`) is a probe the router has no machinery
-- for, and reporting it as `none` — "not checked" — is the honest reading, not
-- a silent downgrade to "down". Same rule as `Bosun.CLI.Observe`.
probeTag :: Probe -> String
probeTag = case _ of
  TcpConnect _ -> "tcp"
  SocketReady _ -> "socket"
  _ -> "none"

probeTcpPort :: Probe -> Maybe Int
probeTcpPort = case _ of
  TcpConnect p -> Just (unPort p)
  _ -> Nothing

probeSocketPath :: Probe -> Maybe String
probeSocketPath = case _ of
  SocketReady p -> Just (unAbsPath p)
  _ -> Nothing

-- | The `/where` encoder the shim calls. The point is that there is exactly ONE
-- | definition of this JSON — `Bosun.Protocol.whereResultCodec` — and both the
-- | producer (here, through the shim) and every decoder read it.
encodeWhere :: WhereInfo -> Json
encodeWhere w = CA.encode whereResultCodec
  { service: w.service
  , mediation: w.mediation
  , ready: w.ready
  , started: w.started
  , probe: w.probe
  , detail: w.detail
  , at:
      { transport: w.transport
      , host: toMaybe w.host
      , port: toMaybe w.port
      , path: toMaybe w.path
      , url: toMaybe w.url
      }
  }

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
  fallback <- resolveStatusPort
  let
    port = fromMaybe fallback mport
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
    let brokers = stringsAt "brokers" res.body
    log
      ( "  ↻ unbound " <> show (A.length (intsAt "unbound" res.body))
          <> ", bound " <> show (A.length (intsAt "boundRoutes" res.body)) <> " proxy + "
          <> show (A.length (intsAt "boundRedirects" res.body)) <> " redirect"
          -- Counted separately and by NAME, because a broker usually binds
          -- nothing: reported through the port lists alone, a reload that
          -- ensured every daemon on the rig printed as "bound 0" (2026-08-23).
          <> ", ensuring " <> show (A.length brokers) <> " broker"
          <> (if A.length brokers == 1 then "" else "s")
      )
    for_ (intsAt "boundRoutes" res.body) \p -> log ("    + :" <> show p <> " now routed")
    for_ (stringsAt "boundBrokers" res.body) \s -> log ("    + " <> s <> " — 307 port rebound")
    for_ (intsAt "unbound" res.body) \p -> log ("    - :" <> show p <> " unbound")
    -- Read /state back: agreement is the claim worth making, and only the
    -- router can make it.
    st <- getJsonUrl (base <> "/state")
    if not st.ok then log ("  ? could not read /state back — " <> st.error)
    else case registryErrorOf st.body of
      -- a check that could not be MADE is not agreement, and must never print as it
      Just e -> log ("  ! the router could not check the registry — " <> e)
      Nothing -> case driftOf st.body of
        [] -> log "  ✓ the registry and the router agree."
        ds -> do
          log ""
          log (renderDrift ds)

-- ── bosun where <service|port> ──────────────────────────────────────────────

-- | ENSURE-AND-LOCATE from the command line: make sure a service is running,
-- | and say where it actually is.
-- |
-- | The operation itself lives in the resident router (`ensureAndLocate` in the
-- | shim) because only the router can spawn and probe; this is a thin client
-- | over `GET /where`, exactly as `runReload` is a thin client over
-- | `POST /control/reload`. DeepStar's pre-flight is the same client written in
-- | Go — which is why the answer is flat JSON with no client library in it.
-- |
-- | The argument is a service id (`slug:role`) or a public port; ports are
-- | identity everywhere else in the router, so they are identity here too.
runWhere :: Maybe Int -> String -> Effect Unit
runWhere mport key = do
  fallback <- resolveStatusPort
  let
    port = fromMaybe fallback mport
    query = case Int.fromString key of
      Just p -> "/where?port=" <> show p
      Nothing -> "/where/" <> key
  res <- getJsonUrl ("http://localhost:" <> show port <> query)
  if not res.ok then do
    log ("  ✗ the router on :" <> show port <> " did not answer — " <> res.error)
    log "    Nothing was started and nothing was located. (Check `bosun serve` is up.)"
  -- A non-`WhereResult` body is the router's 404/502 shape (`{ok,error}`), not a
  -- broken contract — report what it SAID. Leading with a decode error would
  -- blame the wire for an answer that was perfectly clear.
  else case CA.decode whereResultCodec res.body of
    Left err -> case J.toObject res.body >>= FO.lookup "error" >>= J.toString of
      Just e -> log ("  ✗ " <> e)
      Nothing -> log ("  ✗ the router answered something this build cannot read — " <> CA.printJsonDecodeError err)
    Right w -> do
      log ("  " <> w.service <> " — " <> w.mediation
             <> (if w.mediation == "broker" then " (bosun is NOT in the data path)" else " (bosun relays this)"))
      log ("  at " <> locatorLine w.at)
      -- three states, not two: ready, not-ready, and NOT CHECKED. Collapsing the
      -- third into the second is the coercion PRINCIPLES.md forbids everywhere
      -- else an observation is reported.
      log
        ( (if w.probe == "none" then "  ? readiness not checked (this service publishes no signal serve can probe)"
           else if w.ready then "  ✓ ready by probe `" <> w.probe <> "`"
           else "  ✗ NOT ready — probe `" <> w.probe <> "` did not pass")
            <> (if w.started then "; started by this call" else "; already running")
        )
      log ("  " <> w.detail)

locatorLine :: Locator -> String
locatorLine l = case l.transport of
  "unix" -> "unix " <> fromMaybe "?" l.path
  "none" -> "(no dialable address)"
  t -> t <> " " <> fromMaybe "?" l.host <> ":" <> maybe "?" show l.port
         <> maybe "" (\u -> "   " <> u) l.url

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

-- Brokered services are reported by name: most hold no port, so the port-keyed
-- lists say nothing about them at all.
stringsAt :: String -> Json -> Array String
stringsAt k j = A.mapMaybe J.toString (fromMaybe [] (J.toObject j >>= FO.lookup k >>= J.toArray))

asInt :: Json -> Maybe Int
asInt j = J.toNumber j >>= Int.fromNumber

-- `/state`'s `registry.error`: why the router could not check the registry at
-- all. It reports an EMPTY `drift` in that case, which is exactly what agreement
-- looks like, so the reason has to be read separately or the tool repeats the
-- bug it exists to close.
registryErrorOf :: Json -> Maybe String
registryErrorOf j = J.toObject j >>= FO.lookup "registry" >>= J.toObject >>= FO.lookup "error" >>= J.toString

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
