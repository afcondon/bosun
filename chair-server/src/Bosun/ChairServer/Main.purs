-- | Bosun's Chair analysis backend (MVP-PLAN workstream B).
-- |
-- | An HTTPurple server exposing one real endpoint, `POST /analyze`: read the
-- | compose + registry sources at the edge, run the pure `Bosun.Analyze`
-- | ladder, and serialise the `AnalyzeResult` with the shared `Bosun.View`
-- | codecs. Read-only — it owns no processes (that is `bosun serve`). CORS is
-- | wide-open for the :3020 frontend; OPTIONS is answered for preflight.
module Bosun.ChairServer.Main where

import Prelude hiding ((/))

import Bosun.Analyze (AnalyzeInput, analyze)
import Bosun.ChairServer.IO (readJsonFile, readJsonUrl, readYamlFile, resolvePort)
import Bosun.View (AnalyzeRequest, analyzeRequestCodec, analyzeResultCodec)
import Data.Argonaut.Core (Json, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.String as String
import Data.Traversable (traverse)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import HTTPurple (Method(..), Request, ResponseM, ServerM, badRequest', ok', serve, toString)
import HTTPurple.Headers (ResponseHeaders, headers)
import Routing.Duplex (RouteDuplex', root)
import Routing.Duplex.Generic (noArgs, sum)
import Routing.Duplex.Generic.Syntax ((/))

data Route = Analyze | Health
derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Analyze": "analyze" / noArgs
  , "Health": "health" / noArgs
  }

corsHeaders :: ResponseHeaders
corsHeaders = headers
  { "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
  , "Access-Control-Allow-Headers": "Content-Type"
  }

jsonCors :: ResponseHeaders
jsonCors = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
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

main :: ServerM
main = do
  port <- resolvePort
  Console.log ("bosun chair-server — analysis backend on :" <> show port)
  serve { hostname: "0.0.0.0", port } { route, router }
