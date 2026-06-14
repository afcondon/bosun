module Bosun.CLI.Main where

import Prelude

import Bosun.Version (version)
import Effect (Effect)
import Effect.Console (log)

-- | Phase 0 stub: prove the CLI builds and runs on the node backend.
-- | The real subcommands (`check`, `plan`, `apply`, `emit`) arrive from
-- | Phase 3 onward.
main :: Effect Unit
main = log ("bosun " <> version)
