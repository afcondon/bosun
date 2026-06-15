-- | The chair-server's synchronous I/O edge (mirrors the CLI's `Bosun.CLI.IO`):
-- | read a YAML/JSON file or fetch a JSON URL and hand back a `Json` for the
-- | pure adapters. Synchronous by design — the no-Aff seam (DESIGN §8): the
-- | effectful, can-fail work lives here at the edge and is lifted into the
-- | server's `Aff` handler, never reaching the pure core.
module Bosun.ChairServer.IO
  ( readYamlFile
  , readJsonFile
  , readJsonUrl
  , resolvePort
  ) where

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)

foreign import readYamlImpl :: EffectFn1 String Json
foreign import readJsonImpl :: EffectFn1 String Json
foreign import readJsonUrlImpl :: EffectFn1 String Json
foreign import resolvePort :: Effect Int

readYamlFile :: String -> Effect Json
readYamlFile = runEffectFn1 readYamlImpl

readJsonFile :: String -> Effect Json
readJsonFile = runEffectFn1 readJsonImpl

readJsonUrl :: String -> Effect Json
readJsonUrl = runEffectFn1 readJsonUrlImpl
