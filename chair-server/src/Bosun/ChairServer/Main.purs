-- | Bosun's Chair analysis backend (MVP-PLAN workstream B).
-- |
-- | An HTTPurple server. Original mandate: read-only `POST /analyze`. As of
-- | 2026-06-23 it also hosts the **registry write API** that takes ownership
-- | of `servers/ports/startCommand/host` from Marginalia (the seam landed in
-- | docs/MARGINALIA-SEAM.md). The on-disk source of truth is
-- | `registry/fleet.json` — shape-compatible with Marginalia's `/api/ports`
-- | so consumers (the Cambrian Explosion view, the `/marginalia` skill, this
-- | session's own scripts) can switch over without breakage.
-- |
-- | Endpoints (all under `/api`):
-- |   GET    /ports                      list every server row + collisions
-- |   GET    /ports/suggest              next free port from 3000
-- |   GET    /projects/:id/servers       list servers for one project
-- |   POST   /projects/:id/servers       create a server row (assigns id)
-- |   DELETE /servers/:id                remove a server row
-- |
-- | Plus the pre-existing `POST /analyze` (compose+registry ladder) and
-- | `GET /health`. CORS open for the :3020 Chair frontend.
-- |
-- | Reads (the hot path) are fully independent — they touch only fleet.json.
-- | Writes synchronously fetch the Marginalia project record for projectName
-- | denormalisation, and POST `:3997/control/reload` so bosun-serve
-- | re-admits the new row immediately.
-- |
-- | A write has TWO halves and they can part company: fleet.json is durable and
-- | is never rolled back, while the routing half depends on a router that may be
-- | down, or may refuse the row. Since 2026-08-17 the response says which
-- | happened (`routing`), and a write that persisted without being routed
-- | answers **202 Accepted**, not 200 — the failure mode that hid itajara @3028
-- | for three days was precisely a 200 with the routing half silently dropped.
module Bosun.ChairServer.Main where

import Prelude hiding ((/))

import Bosun.Analyze (AnalyzeInput, analyze)
import Bosun.ChairServer.IO (ReloadOutcome, fetchMarginaliaProject, readFleet, readJsonFile, readJsonUrl, readYamlFile, reloadBosunServe, resolvePort, writeFleet)
import Bosun.View (AnalyzeRequest, ServiceInstanceView, TopologyEntry, analyzeRequestCodec, analyzeResultCodec, topologyCodec)
import Data.Argonaut.Core (Json, jsonNull, stringify)
import Data.Argonaut.Core as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as A
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Foldable (foldl, maximum)
import Data.Generic.Rep (class Generic)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set as Set
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Exception (message)
import Foreign.Object as FO
import HTTPurple (Method(..), Request, ResponseM, ServerM, badRequest', notFound', ok', response', serve, toString)
import HTTPurple.Headers (ResponseHeaders, headers)
import HTTPurple.Status as Status
import Routing.Duplex (RouteDuplex', int, root, segment)
import Routing.Duplex.Generic (noArgs, sum)
import Routing.Duplex.Generic.Syntax ((/))

data Route
  = Analyze
  | Topology
  | Health
  | ApiPorts
  | ApiPortsSuggest
  | ApiProjectsServers Int
  | ApiServersById Int

derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Analyze": "analyze" / noArgs
  , "Topology": "topology" / noArgs
  , "Health": "health" / noArgs
  , "ApiPorts": "api" / "ports" / noArgs
  , "ApiPortsSuggest": "api" / "ports" / "suggest" / noArgs
  , "ApiProjectsServers": "api" / "projects" / int segment / "servers"
  , "ApiServersById": "api" / "servers" / int segment
  }

corsHeaders :: ResponseHeaders
corsHeaders = headers
  { "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS"
  , "Access-Control-Allow-Headers": "Content-Type"
  }

jsonCors :: ResponseHeaders
jsonCors = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS"
  , "Access-Control-Allow-Headers": "Content-Type"
  }

-- | JSON-string → typed value via the shared codec; a `Left` message on either
-- | a JSON syntax error or a codec mismatch.
parseBody :: forall a. CA.JsonCodec a -> String -> Either String a
parseBody codec s = case jsonParser s of
  Left err -> Left ("invalid JSON: " <> err)
  Right j -> case CA.decode codec j of
    Left de -> Left (CA.printJsonDecodeError de)
    Right a -> Right a

-- | Resolve the request's source locators to parsed `Json` at the edge.
-- | Compose is YAML on disk; the registry is JSON on disk, or — if it looks
-- | like a URL — fetched (so the Chair can point at the live registry).
resolveInput :: AnalyzeRequest -> Aff AnalyzeInput
resolveInput rq = do
  compose <- traverse (\p -> liftEffect (readYamlFile p)) rq.compose
  registry <- traverse resolveRegistry rq.registry
  pure { compose, registry, overrides: rq.overrides }
  where
  resolveRegistry :: String -> Aff Json
  resolveRegistry p = liftEffect (if isHttp p then readJsonUrl p else readJsonFile p)
  isHttp p = String.take 4 p == "http"

-- ── topology (the declared supervisor tree) ──────────────────────────────────

-- | Pull `--port N <compose> <registry>` out of a `… supervise …` command.
parseSupervise :: String -> Maybe { port :: Int, compose :: String, registry :: String }
parseSupervise detail =
  let toks = A.filter (_ /= "") (String.split (String.Pattern " ") detail)
  in
    if not (A.elem "supervise" toks) then Nothing
    else case A.elemIndex "--port" toks of
      Nothing -> Nothing
      Just i -> do
        port <- Int.fromString =<< A.index toks (i + 1)
        compose <- A.index toks (i + 2)
        registry <- A.index toks (i + 3)
        pure { port, compose, registry }

-- | DFS-resolve one group into a flat entry list: the group's own entry, then
-- | each member (a sub-supervisor recurses; a leaf service is emitted directly).
-- | Depth-capped; a group whose compose fails to read yields no children rather
-- | than sinking the whole tree.
resolveTopoNode :: Int -> Maybe String -> String -> Int -> String -> String -> Aff (Array TopologyEntry)
resolveTopoNode depth parent name gport composePath registryPath = do
  let selfEntry = { name, port: Nothing, groupPort: Just gport, compose: Just composePath, registry: Just registryPath, parent, mechanism: "supervise", depth }
  children <-
    if depth >= 6 then pure []
    else do
      res <- attempt do
        input <- resolveInput { compose: Just composePath, registry: Just registryPath, overrides: [] }
        pure (analyze input)
      case res of
        Left _ -> pure []
        Right a -> map A.concat (traverse (resolveInstance (depth + 1) name) a.instances)
  pure (A.cons selfEntry children)

resolveInstance :: Int -> String -> ServiceInstanceView -> Aff (Array TopologyEntry)
resolveInstance depth parent inst = case parseSupervise inst.executor.detail of
  Just sup -> resolveTopoNode depth (Just parent) inst.localName sup.port sup.compose sup.registry
  Nothing -> pure
    [ { name: inst.localName
      , port: A.findMap _.port inst.reachability
      , groupPort: Nothing
      , compose: Nothing
      , registry: Nothing
      , parent: Just parent
      , mechanism: inst.executor.mechanism
      , depth
      } ]

-- | POST /topology — body `{ compose, registry, port }` → the declared tree,
-- | flattened DFS. `port` is the root supervisor's own `/state` port (external
-- | knowledge — launchd passes it to `bosun supervise --port`).
handleTopology :: String -> ResponseM
handleTopology bodyStr = case jsonParser bodyStr of
  Left err -> badRequest' jsonCors ("invalid JSON: " <> err)
  Right j -> case extractTopoReq j of
    Nothing -> badRequest' jsonCors "topology: expected { compose, registry, port }"
    Just req -> do
      entries <- resolveTopoNode 0 Nothing "root" req.port req.compose req.registry
      ok' jsonCors (stringify (CA.encode topologyCodec entries))

extractTopoReq :: Json -> Maybe { compose :: String, registry :: String, port :: Int }
extractTopoReq j = do
  o <- J.toObject j
  compose <- J.toString =<< FO.lookup "compose" o
  registry <- J.toString =<< FO.lookup "registry" o
  portN <- J.toNumber =<< FO.lookup "port" o
  pure { compose, registry, port: Int.round portN }

router :: Request Route -> ResponseM
router { route: r, method, body } = case method of
  Options -> ok' corsHeaders ""
  _ -> case r of
    -- Not a bare "ok". The registry-edit half of this server is unusable if
    -- fleet.json cannot be read, and every other endpoint 400s in that case
    -- while /health cheerfully said the service was fine — a health check that
    -- checks nothing it serves. Read the file it owns and report what it found.
    Health -> do
      fleet <- attempt (liftEffect readFleet)
      case fleet of
        Left e -> response' Status.serviceUnavailable jsonCors
          (stringify (healthJson false ("registry unreadable: " <> message e)))
        Right f -> ok' jsonCors
          (stringify (healthJson true (show (A.length (serverList f)) <> " server rows")))
    Analyze -> do
      bodyStr <- toString body
      case parseBody analyzeRequestCodec bodyStr of
        Left msg -> badRequest' jsonCors msg
        Right rq -> do
          input <- resolveInput rq
          ok' jsonCors (stringify (CA.encode analyzeResultCodec (analyze input)))
    Topology -> do
      bodyStr <- toString body
      handleTopology bodyStr
    ApiPorts -> handleGetPorts
    ApiPortsSuggest -> handleSuggest
    ApiProjectsServers pid -> case method of
      Get -> handleProjectServers pid
      Post -> do
        bodyStr <- toString body
        handleCreateServer pid bodyStr
      _ -> badRequest' jsonCors "method not allowed"
    ApiServersById sid -> case method of
      Delete -> handleDeleteServer sid
      _ -> badRequest' jsonCors "method not allowed"

main :: ServerM
main = do
  port <- resolvePort
  Console.log ("bosun chair-server — analysis + registry backend on :" <> show port)
  serve { hostname: "0.0.0.0", port } { route, router }

----------------------------------------------------------------------
-- Registry handlers
----------------------------------------------------------------------

-- | GET /api/ports — the fleet, shape-compatible with Marginalia. Adds a
-- | `collisions` field (computed live) so consumers can detect port conflicts.
handleGetPorts :: ResponseM
handleGetPorts = do
  result <- attempt (liftEffect readFleet)
  case result of
    Left e -> badRequest' jsonCors ("fleet.json read failed: " <> message e)
    Right fleet -> ok' jsonCors (stringify (withCollisions fleet))

-- | GET /api/ports/suggest — first free port from 3000 upward.
handleSuggest :: ResponseM
handleSuggest = do
  result <- attempt (liftEffect readFleet)
  case result of
    Left e -> badRequest' jsonCors ("fleet.json read failed: " <> message e)
    Right fleet -> do
      let port = nextFreePort fleet
      ok' jsonCors (stringify (J.fromObject (FO.singleton "port" (J.fromNumber (Int.toNumber port)))))

-- | GET /api/projects/:id/servers — filter fleet by projectId.
handleProjectServers :: Int -> ResponseM
handleProjectServers pid = do
  result <- attempt (liftEffect readFleet)
  case result of
    Left e -> badRequest' jsonCors ("fleet.json read failed: " <> message e)
    Right fleet ->
      let matches = A.filter (\s -> serverProjectId s == Just pid) (serverList fleet)
      in ok' jsonCors (stringify (J.fromArray matches))

-- | POST /api/projects/:id/servers — body shape mirrors Marginalia.
-- | Look up the project name from Marginalia (the only write-time runtime
-- | link), assign a fresh id, atomic-write fleet.json, then ask bosun-serve to
-- | re-admit and REPORT what it said. 200 when the row is routed; 202 when it
-- | persisted but is not routed (with the reason in `routing.note`).
handleCreateServer :: Int -> String -> ResponseM
handleCreateServer pid bodyStr = case jsonParser bodyStr of
  Left err -> badRequest' jsonCors ("invalid JSON: " <> err)
  Right bodyJson -> do
    fleetResult <- attempt (liftEffect readFleet)
    projectResult <- attempt (liftEffect (fetchMarginaliaProject pid))
    case Tuple fleetResult projectResult of
      Tuple (Left e) _ -> badRequest' jsonCors ("fleet.json read failed: " <> message e)
      Tuple _ (Left e) -> badRequest' jsonCors ("marginalia project " <> show pid <> " lookup failed: " <> message e)
      Tuple (Right fleet) (Right project) ->
        let
          newId = nextServerId fleet
          row = buildServerRow newId pid project bodyJson
          fleet' = appendServer row fleet
        in do
          writeResult <- attempt (liftEffect (writeFleet fleet'))
          case writeResult of
            Left e -> badRequest' jsonCors ("fleet.json write failed: " <> message e)
            Right _ -> do
              outcome <- liftEffect reloadBosunServe
              let
                report = createReport (serverPort row) outcome
                answer = withField "routing" report.json row
              -- 200 only when BOTH halves landed. Persisting is durable and is
              -- never undone, so this is an honest partial success, not an error.
              if report.routed then ok' jsonCors (stringify answer)
              else response' Status.accepted jsonCors (stringify answer)

-- | DELETE /api/servers/:id — atomic remove + reload. 404 if id not present.
-- | 202 when the removal persisted but the router was not told (it will still be
-- | holding the port until someone reloads it).
handleDeleteServer :: Int -> ResponseM
handleDeleteServer sid = do
  fleetResult <- attempt (liftEffect readFleet)
  case fleetResult of
    Left e -> badRequest' jsonCors ("fleet.json read failed: " <> message e)
    Right fleet ->
      let
        servers = serverList fleet
        doomed = A.find (\s -> serverId s == Just sid) servers
      in
        case doomed of
          Nothing -> notFound' jsonCors
          Just row ->
            let fleet' = setServers (A.filter (\s -> serverId s /= Just sid) servers) fleet
            in do
              writeResult <- attempt (liftEffect (writeFleet fleet'))
              case writeResult of
                Left e -> badRequest' jsonCors ("fleet.json write failed: " <> message e)
                Right _ -> do
                  outcome <- liftEffect reloadBosunServe
                  let
                    report = deleteReport (serverPort row) outcome
                    answer = withField "routing" report.json
                      (J.fromObject (FO.singleton "deleted" (J.fromNumber (Int.toNumber sid))))
                  if report.routed then ok' jsonCors (stringify answer)
                  else response' Status.accepted jsonCors (stringify answer)

----------------------------------------------------------------------
-- The routing half of a write, reported honestly
----------------------------------------------------------------------

-- | The router's post-reload verdict on ONE public port. Closed alternatives, so
-- | an ADT (§10) — and the distinction that matters is `Refused` vs `Absent`:
-- | refused means the router looked at the row and can't use it (fix the row),
-- | absent means it never saw it (reload, or the router is stale).
data PortVerdict
  = Routed
  | Redirected
  | Refused String
  | Absent
  | NoPortDeclared

-- | Did the write end up routed, and what do we tell the caller? `routed` gates
-- | the 200-vs-202; `json` is the `routing` object spliced into the response.
type WriteReport = { routed :: Boolean, json :: Json }

createReport :: Maybe Int -> ReloadOutcome -> WriteReport
createReport mport outcome = case reloadFailure outcome of
  Just why -> unrouted false
    ( "persisted but NOT routed — the reload failed: " <> why
        <> ". fleet.json IS written; run `bosun reload` (or start the router) to route it."
    )
  Nothing -> case verdictFor mport outcome.body of
    Routed -> report true "routed — the router is bound to this port and will lazy-spawn it on first request."
    Redirected -> report true "routed — bound as a 421 redirect (the row's host is not this machine)."
    Refused why -> unrouted true
      ( "persisted, and the router reloaded — but it will NOT route this row: " <> why
          <> ". Fix the row (see docs/REGISTER-A-SERVICE.md) and re-register; the reload cannot help."
      )
    NoPortDeclared -> unrouted true
      "persisted; the row declares no port, so there is nothing for the router to bind."
    Absent -> unrouted true
      "persisted, and the router reloaded — but this port is in none of its routes, redirects or refusals. Check the router's /state."
  where
  report routed note = { routed, json: routingJson routed true note outcome }
  unrouted reloaded note = { routed: false, json: routingJson false reloaded note outcome }

deleteReport :: Maybe Int -> ReloadOutcome -> WriteReport
deleteReport mport outcome = case reloadFailure outcome of
  Just why ->
    { routed: false
    , json: routingJson false false
        ( "removed from fleet.json but the router was NOT told — the reload failed: " <> why
            <> ". It is still holding this port; run `bosun reload`."
        )
        outcome
    }
  Nothing -> case verdictFor mport outcome.body of
    Routed -> { routed: false, json: routingJson false true "removed from fleet.json, but the router STILL routes this port — check for another row on it." outcome }
    Redirected -> { routed: false, json: routingJson false true "removed from fleet.json, but the router still 421s this port — check for another row on it." outcome }
    _ -> { routed: true, json: routingJson false true "removed, and the router has released the port." outcome }

-- | `Nothing` ⇒ the router answered and accepted the reload. `Just why` ⇒ it
-- | didn't (unreachable, or it answered `{ok:false}`).
reloadFailure :: ReloadOutcome -> Maybe String
reloadFailure outcome
  | not outcome.ok = Just outcome.error
  | jsonBool "ok" outcome.body = Nothing
  | otherwise = Just (fromMaybe "the router refused the reload" (jsonString "error" outcome.body))

verdictFor :: Maybe Int -> Json -> PortVerdict
verdictFor mport body = case mport of
  Nothing -> NoPortDeclared
  Just port
    | A.elem port (jsonInts "routes" body) -> Routed
    | A.elem port (jsonInts "redirects" body) -> Redirected
    | Just why <- refusalFor port body -> Refused why
    | otherwise -> Absent

refusalFor :: Int -> Json -> Maybe String
refusalFor port body = do
  entry <- A.find (\r -> serverInt "publicPort" r == Just port) (jsonArray "rejected" body)
  serverField "reason" entry >>= J.toString

routingJson :: Boolean -> Boolean -> String -> ReloadOutcome -> Json
routingJson routed reloaded note outcome = J.fromObject
  (FO.fromFoldable
    [ Tuple "persisted" (J.fromBoolean true)
    , Tuple "reloaded" (J.fromBoolean reloaded)
    , Tuple "routed" (J.fromBoolean routed)
    , Tuple "note" (J.fromString note)
    , Tuple "reload" (if outcome.ok then outcome.body else jsonNull)
    ])

-- | `GET /health` — what this server can actually do right now, not that its
-- | process is running (the caller can see that from the connection).
healthJson :: Boolean -> String -> Json
healthJson ok note = J.fromObject
  (FO.fromFoldable
    [ Tuple "ok" (J.fromBoolean ok)
    , Tuple "registry" (J.fromString note)
    ])

-- | Splice a computed field into a response object. The value is response-only —
-- | `routing` describes what happened, so it is never part of the persisted row.
withField :: String -> Json -> Json -> Json
withField k v j = J.fromObject (FO.insert k v (fromMaybe FO.empty (J.toObject j)))

----------------------------------------------------------------------
-- fleet.json helpers (Json-shaped — no typed model)
----------------------------------------------------------------------

serverList :: Json -> Array Json
serverList fleet = fromMaybe []
  (J.toObject fleet >>= FO.lookup "servers" >>= J.toArray)

setServers :: Array Json -> Json -> Json
setServers servers fleet =
  let
    obj = fromMaybe FO.empty (J.toObject fleet)
    obj' = FO.insert "servers" (J.fromArray servers) (FO.insert "count" (J.fromNumber (Int.toNumber (A.length servers))) obj)
  in J.fromObject obj'

appendServer :: Json -> Json -> Json
appendServer row fleet = setServers (A.snoc (serverList fleet) row) fleet

serverField :: String -> Json -> Maybe Json
serverField k j = J.toObject j >>= FO.lookup k

-- Reading the router's control-surface answer. It is hand-rolled JSON in the
-- serve shim (no shared codec to thread through), so these are total with
-- absent-means-nothing defaults: the handler that exists to REPORT a failure
-- must not itself fail on a shape surprise.
jsonBool :: String -> Json -> Boolean
jsonBool k j = fromMaybe false (serverField k j >>= J.toBoolean)

jsonString :: String -> Json -> Maybe String
jsonString k j = serverField k j >>= J.toString

jsonArray :: String -> Json -> Array Json
jsonArray k j = fromMaybe [] (serverField k j >>= J.toArray)

jsonInts :: String -> Json -> Array Int
jsonInts k j = A.mapMaybe (\x -> J.toNumber x >>= Int.fromNumber) (jsonArray k j)

serverInt :: String -> Json -> Maybe Int
serverInt k j = serverField k j >>= J.toNumber >>= Int.fromNumber

serverPort :: Json -> Maybe Int
serverPort = serverInt "port"

serverId :: Json -> Maybe Int
serverId = serverInt "id"

serverProjectId :: Json -> Maybe Int
serverProjectId = serverInt "projectId"

nextServerId :: Json -> Int
nextServerId fleet =
  let ids = A.mapMaybe serverId (serverList fleet)
  in 1 + fromMaybe 0 (maximum ids)

nextFreePort :: Json -> Int
nextFreePort fleet =
  let
    used = Set.fromFoldable (A.mapMaybe serverPort (serverList fleet))
    go p = if Set.member p used then go (p + 1) else p
  in go 3000

-- | Compute port → claimants. Add as `collisions` field to the fleet object
-- | for the GET /api/ports response. Mirrors Marginalia's response shape.
withCollisions :: Json -> Json
withCollisions fleet =
  let
    servers = serverList fleet
    addRow acc s = case serverPort s of
      Nothing -> acc
      Just p -> FO.alter (\m -> Just (A.snoc (fromMaybe [] m) (claimant s))) (show p) acc
    grouped = foldl addRow (FO.empty :: FO.Object (Array Json)) servers
    cols = FO.filter (\v -> A.length v > 1) grouped
    obj = fromMaybe FO.empty (J.toObject fleet)
  in J.fromObject (FO.insert "collisions" (J.fromObject (map J.fromArray cols)) obj)

claimant :: Json -> Json
claimant s =
  let
    pick k = fromMaybe jsonNull (serverField k s)
  in J.fromObject
    (FO.fromFoldable
      [ Tuple "id" (pick "id")
      , Tuple "projectId" (pick "projectId")
      , Tuple "projectName" (pick "projectName")
      , Tuple "role" (pick "role")
      ])

----------------------------------------------------------------------
-- POST body → fleet row
----------------------------------------------------------------------

-- | Build a complete fleet row from the request body. Required fields are
-- | taken from the body; `projectName` is denormalised from the freshly-fetched
-- | Marginalia project record. Any unknown body fields are preserved
-- | (forward-compat with Marginalia adding fields).
-- |
-- | `projectSlug` was denormalised here too until 2026-09-13. It is gone, along
-- | with the slugs themselves: `projectId` is the row's identity and it comes
-- | from the URL, not from the lookup. The lookup still happens, and must —
-- | it is what proves the project EXISTS before a row claims to belong to it
-- | (see `fetchMarginaliaProjectImpl`'s `curl -f`), and it is where the human
-- | name comes from.
buildServerRow :: Int -> Int -> Json -> Json -> Json
buildServerRow newId pid project body =
  let
    bodyObj = fromMaybe FO.empty (J.toObject body)
    projectObj = fromMaybe FO.empty (J.toObject project)
    projectName = fromMaybe jsonNull (FO.lookup "name" projectObj)
    -- Start with the body (preserves arbitrary extra fields), then overwrite
    -- the server-assigned + denormalised fields.
    withAssigned = FO.insert "id" (J.fromNumber (Int.toNumber newId)) bodyObj
    withProject = FO.insert "projectId" (J.fromNumber (Int.toNumber pid))
      (FO.insert "projectName" projectName withAssigned)
  in J.fromObject withProject

