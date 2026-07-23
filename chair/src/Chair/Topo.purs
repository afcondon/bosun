-- | The declared supervisor topology, fetched from chair-server.
-- |
-- | The Chair's landing was a hand-curated card list. This asks chair-server
-- | (which reads compose files) to recursively resolve the REAL tree — launchd
-- | → root → sub-supervisors → services — and returns it flattened depth-first
-- | (`depth` = indent) as `TopologyEntry`s. The landing renders that tree and
-- | overlays each group's live `/state`. One typed round-trip; the resolution
-- | (reading composes, recognising `supervise --port …` members) lives server-
-- | side where compose-reading belongs.
module Chair.Topo
  ( fetchTopology
  , fetchFleetNames
  , rootCompose
  , rootRegistry
  , rootPort
  ) where

import Prelude

import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Bosun.View (TopologyEntry, topologyCodec)
import Data.Argonaut.Core (fromNumber, fromObject, fromString, toArray, toObject, toString)
import Data.Array as Array
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Foreign.Object as FO

analyzeBase :: String
analyzeBase = "http://localhost:3022"

-- | The launchd-rooted supervisor and its compose (the single host bootstrap).
rootPort :: Int
rootPort = 3990

-- Repo-relative: chair-server reads these from its own cwd (the bosun repo
-- root), the same basis registry/fleet.json already resolves against.
rootCompose :: String
rootCompose = "fixtures/router/compose.yml"

rootRegistry :: String
rootRegistry = "fixtures/router/registry.json"

-- | `POST /topology { compose, registry, port }` → the declared tree (flat DFS).
fetchTopology :: Aff (Either String (Array TopologyEntry))
fetchTopology = do
  let
    reqBody = fromObject $ FO.fromFoldable
      [ Tuple "compose" (fromString rootCompose)
      , Tuple "registry" (fromString rootRegistry)
      , Tuple "port" (fromNumber (Int.toNumber rootPort))
      ]
  res <- AX.post RF.json (analyzeBase <> "/topology") (Just (RB.json reqBody))
  pure case res of
    Left err -> Left (AX.printError err)
    Right resp -> case CA.decode topologyCodec resp.body of
      Left e -> Left (CA.printJsonDecodeError e)
      Right t -> Right t

-- | projectSlug → human projectName, read from chair-server's fleet.json
-- | (`/api/ports`). Both the serve router's `/state` serviceId (`slug:role`) and
-- | the supervise views key by slug, so a slug→name map makes every surface
-- | (landing fleet, cockpit tables) show a readable name, not a NATO callsign.
fetchFleetNames :: Aff (Map String String)
fetchFleetNames = do
  res <- AX.get RF.json (analyzeBase <> "/api/ports")
  pure case res of
    Left _ -> Map.empty
    Right resp -> fromMaybe Map.empty do
      obj <- toObject resp.body
      servers <- toArray =<< FO.lookup "servers" obj
      pure (Map.fromFoldable (Array.mapMaybe rowKV servers))
  where
  rowKV j = do
    o <- toObject j
    slug <- toString =<< FO.lookup "projectSlug" o
    n <- toString =<< FO.lookup "projectName" o
    pure (Tuple slug n)
