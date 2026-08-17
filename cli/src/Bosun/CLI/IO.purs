-- | The CLI's synchronous I/O edge: read a YAML or JSON file off disk and hand
-- | back a `Json` for the pure adapters to decode. Synchronous by design — the
-- | no-Aff seam (DESIGN §8): all genuinely effectful work is straight-line and
-- | lives here at the edge, never in the pure core. (`Json`'s runtime
-- | representation is just the parsed JS value, so js-yaml / JSON.parse output
-- | is a `Json` directly.)
module Bosun.CLI.IO
  ( readYamlFile
  , readJsonFile
  , readJsonUrl
  , HttpResult
  , getJsonUrl
  , postJsonUrl
  , argv
  ) where

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)

foreign import readYamlImpl :: EffectFn1 String Json
foreign import readJsonImpl :: EffectFn1 String Json
foreign import readJsonUrlImpl :: EffectFn1 String Json
foreign import getJsonUrlImpl :: EffectFn1 String HttpResult
foreign import postJsonUrlImpl :: EffectFn1 String HttpResult
foreign import argv :: Effect (Array String)

-- | A talk-to-a-local-daemon result that does NOT throw. `readJsonUrl` is fine
-- | for a source we require (a failure there should abort), but `bosun reload`
-- | has to be able to SAY "the router isn't running" rather than die with a
-- | stack trace — an unreachable router is a legitimate, reportable outcome.
-- | `body` is `null` when `ok` is false.
type HttpResult = { ok :: Boolean, body :: Json, error :: String }

readYamlFile :: String -> Effect Json
readYamlFile = runEffectFn1 readYamlImpl

readJsonFile :: String -> Effect Json
readJsonFile = runEffectFn1 readJsonImpl

readJsonUrl :: String -> Effect Json
readJsonUrl = runEffectFn1 readJsonUrlImpl

getJsonUrl :: String -> Effect HttpResult
getJsonUrl = runEffectFn1 getJsonUrlImpl

postJsonUrl :: String -> Effect HttpResult
postJsonUrl = runEffectFn1 postJsonUrlImpl
