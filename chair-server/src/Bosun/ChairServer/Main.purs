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
-- | Writes synchronously fetch the Marginalia project record for projectName +
-- | projectSlug denormalisation, and POST `:3997/control/reload` so bosun-serve
-- | re-admits the new row immediately.
module Bosun.ChairServer.Main where

import Prelude hiding ((/))

import Bosun.Analyze (AnalyzeInput, analyze)
import Bosun.ChairServer.IO (fetchMarginaliaProject, readFleet, readJsonFile, readJsonUrl, readYamlFile, reloadBosunServe, resolvePort, writeFleet)
import Bosun.View (AnalyzeRequest, analyzeRequestCodec, analyzeResultCodec)
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
import HTTPurple (Method(..), Request, ResponseM, ServerM, badRequest', notFound', ok', serve, toString)
import HTTPurple.Headers (ResponseHeaders, headers)
import Routing.Duplex (RouteDuplex', int, root, segment)
import Routing.Duplex.Generic (noArgs, sum)
import Routing.Duplex.Generic.Syntax ((/))

data Route
  = Analyze
  | Health
  | ApiPorts
  | ApiPortsSuggest
  | ApiProjectsServers Int
  | ApiServersById Int

derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Analyze": "analyze" / noArgs
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

router :: Request Route -> ResponseM
router { route: r, method, body } = case method of
  Options -> ok' corsHeaders ""
  _ -> case r of
    Health -> ok' corsHeaders "ok"
    Analyze -> do
      bodyStr <- toString body
      case parseBody analyzeRequestCodec bodyStr of
        Left msg -> badRequest' jsonCors msg
        Right rq -> do
          input <- resolveInput rq
          ok' jsonCors (stringify (CA.encode analyzeResultCodec (analyze input)))
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
-- | Look up project name/slug from Marginalia (the only write-time runtime
-- | link), assign a fresh id, atomic-write fleet.json, nudge bosun-serve.
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
              _ <- liftEffect reloadBosunServe
              ok' jsonCors (stringify row)

-- | DELETE /api/servers/:id — atomic remove + reload. 404 if id not present.
handleDeleteServer :: Int -> ResponseM
handleDeleteServer sid = do
  fleetResult <- attempt (liftEffect readFleet)
  case fleetResult of
    Left e -> badRequest' jsonCors ("fleet.json read failed: " <> message e)
    Right fleet ->
      let
        servers = serverList fleet
        present = A.any (\s -> serverId s == Just sid) servers
      in
        if not present
          then notFound' jsonCors
          else
            let fleet' = setServers (A.filter (\s -> serverId s /= Just sid) servers) fleet
            in do
              writeResult <- attempt (liftEffect (writeFleet fleet'))
              case writeResult of
                Left e -> badRequest' jsonCors ("fleet.json write failed: " <> message e)
                Right _ -> do
                  _ <- liftEffect reloadBosunServe
                  ok' jsonCors (stringify (J.fromObject (FO.singleton "deleted" (J.fromNumber (Int.toNumber sid)))))

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
-- | taken from the body; projectName + projectSlug are denormalised from the
-- | freshly-fetched Marginalia project record. Any unknown body fields are
-- | preserved (forward-compat with Marginalia adding fields).
buildServerRow :: Int -> Int -> Json -> Json -> Json
buildServerRow newId pid project body =
  let
    bodyObj = fromMaybe FO.empty (J.toObject body)
    projectObj = fromMaybe FO.empty (J.toObject project)
    projectName = fromMaybe jsonNull (FO.lookup "name" projectObj)
    projectSlug = fromMaybe jsonNull (FO.lookup "slug" projectObj)
    -- Start with the body (preserves arbitrary extra fields), then overwrite
    -- the server-assigned + denormalised fields.
    withAssigned = FO.insert "id" (J.fromNumber (Int.toNumber newId)) bodyObj
    withProject = FO.insert "projectId" (J.fromNumber (Int.toNumber pid))
      (FO.insert "projectName" projectName
        (FO.insert "projectSlug" projectSlug withAssigned))
  in J.fromObject withProject

