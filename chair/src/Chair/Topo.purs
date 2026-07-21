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
  , rootCompose
  , rootRegistry
  , rootPort
  ) where

import Prelude

import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Bosun.View (TopologyEntry, topologyCodec)
import Data.Argonaut.Core (fromNumber, fromObject, fromString)
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Foreign.Object as FO

analyzeBase :: String
analyzeBase = "http://localhost:3022"

-- | The launchd-rooted supervisor and its compose (the single host bootstrap).
rootPort :: Int
rootPort = 3990

rootCompose :: String
rootCompose = "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures/router/compose.yml"

rootRegistry :: String
rootRegistry = "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures/router/registry.json"

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
