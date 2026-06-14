-- | The CLI's synchronous I/O edge: read a YAML or JSON file off disk and hand
-- | back a `Json` for the pure adapters to decode. Synchronous by design — the
-- | no-Aff seam (DESIGN §8): all genuinely effectful work is straight-line and
-- | lives here at the edge, never in the pure core. (`Json`'s runtime
-- | representation is just the parsed JS value, so js-yaml / JSON.parse output
-- | is a `Json` directly.)
module Bosun.CLI.IO
  ( readYamlFile
  , readJsonFile
  , argv
  ) where

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)

foreign import readYamlImpl :: EffectFn1 String Json
foreign import readJsonImpl :: EffectFn1 String Json
foreign import argv :: Effect (Array String)

readYamlFile :: String -> Effect Json
readYamlFile = runEffectFn1 readYamlImpl

readJsonFile :: String -> Effect Json
readJsonFile = runEffectFn1 readJsonImpl
