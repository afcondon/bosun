module Bosun.Beam.Main where

import Prelude

import Bosun.Version (version)
import Effect (Effect)
import Effect.Console (log)

main :: Effect Unit
main = log ("bosun-beam " <> version)
