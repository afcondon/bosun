-- | `/state` as one pure function from text to text: read a document with
-- | the shared description, print it again with the same description.
-- |
-- | Held three ways by `beam/conformance.sh` over `protocol/vectors/state/`:
-- | node and the BEAM give the same bytes; a document the daemon wrote comes
-- | back unchanged (so the printer still writes what was on the wire); and a
-- | document with an `.expected` file beside it comes back as that file says
-- | (a newer supervisor's extra fields dropped; a wrong document refused).
module Bosun.Conformance.StateText
  ( stateText
  , stateDocument
  ) where

import Prelude

import Bosun.Protocol.State (document, printState, readState)
import Data.Maybe (maybe)

stateText :: String -> String
stateText = readState >>> maybe "UNREADABLE" printState

-- | The generated tables of `protocol/STATE.md` (`scripts/state-doc.sh`).
stateDocument :: String
stateDocument = document
