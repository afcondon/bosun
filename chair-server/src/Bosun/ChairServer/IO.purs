-- | The chair-server's synchronous I/O edge (mirrors the CLI's `Bosun.CLI.IO`):
-- | read a YAML/JSON file or fetch a JSON URL and hand back a `Json` for the
-- | pure adapters. Synchronous by design — the no-Aff seam (DESIGN §8): the
-- | effectful, can-fail work lives here at the edge and is lifted into the
-- | server's `Aff` handler, never reaching the pure core.
-- |
-- | Registry-edit edge (added 2026-06-23): the Marginalia → Bosun ownership
-- | migration moves /api/ports + write APIs here. `readFleet` / `writeFleet`
-- | are the file-edge; `reloadBosunServe` nudges :3997 to re-admit; the
-- | Marginalia project lookup is the one runtime cross-link Bosun keeps to
-- | denormalise projectName/projectSlug into fleet.json rows at POST time.
module Bosun.ChairServer.IO
  ( readYamlFile
  , readJsonFile
  , readJsonUrl
  , resolvePort
  , fleetPath
  , readFleet
  , writeFleet
  , ReloadOutcome
  , reloadBosunServe
  , fetchMarginaliaProject
  ) where

import Prelude (Unit)

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)

-- | What asking the router to reload actually did. `ok` is "the router answered
-- | at all"; the answer itself (`body.ok`, and which ports it now routes) is the
-- | caller's to read. Non-throwing on purpose: a down router must be a
-- | *reportable* outcome, since the registry write has already happened and is
-- | not being undone.
type ReloadOutcome = { ok :: Boolean, body :: Json, error :: String }

foreign import readYamlImpl :: EffectFn1 String Json
foreign import readJsonImpl :: EffectFn1 String Json
foreign import readJsonUrlImpl :: EffectFn1 String Json
foreign import resolvePort :: Effect Int

foreign import fleetPath :: Effect String
foreign import readFleetImpl :: Effect Json
foreign import writeFleetImpl :: EffectFn1 Json Unit
foreign import reloadBosunServeImpl :: Effect ReloadOutcome
foreign import fetchMarginaliaProjectImpl :: EffectFn1 Int Json

readYamlFile :: String -> Effect Json
readYamlFile = runEffectFn1 readYamlImpl

readJsonFile :: String -> Effect Json
readJsonFile = runEffectFn1 readJsonImpl

readJsonUrl :: String -> Effect Json
readJsonUrl = runEffectFn1 readJsonUrlImpl

readFleet :: Effect Json
readFleet = readFleetImpl

writeFleet :: Json -> Effect Unit
writeFleet = runEffectFn1 writeFleetImpl

reloadBosunServe :: Effect ReloadOutcome
reloadBosunServe = reloadBosunServeImpl

-- | Fetch a Marginalia project by id; returns the raw JSON record (or throws
-- | on HTTP error). One synchronous curl — same shape as readJsonUrl.
-- | This is the only runtime Bosun → Marginalia link kept on writes; reads
-- | (GET /api/ports etc.) are fully independent.
fetchMarginaliaProject :: Int -> Effect Json
fetchMarginaliaProject = runEffectFn1 fetchMarginaliaProjectImpl
