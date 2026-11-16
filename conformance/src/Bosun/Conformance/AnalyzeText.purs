-- | The whole `/analyze` path as one pure function from text to text: parse
-- | two JSON documents, ingest, reconcile, validate, project to the wire view,
-- | encode with the shared codec, stringify.
-- |
-- | It exists so that two runtimes can be given the same two files and their
-- | answers compared byte for byte, with no foreign code of the harness's own
-- | in between. It exercises what the hardcoded-fixture Mains do not: the JSON
-- | parser, the object type, the adapters and the codec.
module Bosun.Conformance.AnalyzeText
  ( analyzeText
  ) where

import Prelude

import Bosun.Analyze (analyze)
import Bosun.Protocol (analyzeResultCodec)
import Data.Argonaut.Core (stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))

-- | Compose document (as JSON text), then registry document (as JSON text).
analyzeText :: String -> String -> String
analyzeText composeText registryText =
  case jsonParser composeText, jsonParser registryText of
    Right compose, Right registry ->
      stringify
        ( CA.encode analyzeResultCodec
            (analyze { compose: Just compose, registry: Just registry, overrides: [] })
        )
    Left problem, _ -> "compose does not parse: " <> problem
    _, Left problem -> "registry does not parse: " <> problem
