-- | Glassbox's conformance suite for one machine, as text from text.
-- |
-- | `glassbox vectors` (node) writes `printSuite (suiteFor spec)` to
-- | `conformance/vectors/<machine>.json`, and those files are committed. This
-- | is the same expression, so that the BEAM can be asked for the same file
-- | and the two compared byte for byte. Agreement means the BEAM parses the
-- | artefact, enumerates the same worlds, and steps the machine to the same
-- | answers, for every state, event and assignment.
module Bosun.Beam.GlassboxVectors
  ( vectorsText
  ) where

import Prelude

import Data.Either (Either(..))
import Glassbox.Codec.JSON (parseSpec)
import Glassbox.Conformance (printSuite, suiteFor)

vectorsText :: String -> String
vectorsText artefact = case parseSpec artefact of
  Right spec -> printSuite (suiteFor spec)
  Left problem -> "artefact does not parse: " <> problem
