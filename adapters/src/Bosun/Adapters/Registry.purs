-- | Ingest the Marginalia service registry (the `/api/ports` JSON) into loose
-- | `ServiceInstance`s. The registry is the cross-source partner to compose:
-- | it is where the *native/dev* facet of each service lives (mbp, a
-- | `startCommand`, a localhost port), against compose's *containerised* facet.
-- |
-- | A pure decode (`Json -> Array ServiceInstance`): the effectful read of the
-- | JSON file/endpoint happens in the CLI, keeping the no-Aff seam. Decoding is
-- | lenient — the registry shape is known and stable; a row missing its `role`
-- | is skipped rather than failing the whole ingest.
module Bosun.Adapters.Registry (ingestRegistry, RegistryClaim, registryClaims) where

import Prelude

import Bosun.Adapters.StartCommand (parseStartCommand)
import Bosun.Atoms (mkHost, mkPort, mkProjectSlug)
import Bosun.Reachability (BindScope(..), hostPort, listening, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Data.Argonaut.Core (Json, toArray, toNumber, toObject, toString)
import Data.Array as A
import Data.Int (round)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Foreign.Object (Object)
import Foreign.Object as FO

ingestRegistry :: Json -> Array ServiceInstance
ingestRegistry json = fromMaybe [] do
  obj <- toObject json
  serversJson <- FO.lookup "servers" obj
  servers <- toArray serversJson
  pure (A.mapMaybe decodeRow servers)

decodeRow :: Json -> Maybe ServiceInstance
decodeRow j = do
  o <- toObject j
  role <- str o "role"
  let
    portM = int o "port"
    hostM = map mkHost (str o "host")
    -- §8: a registry row names its host, so a listener binds that specific
    -- interface (`HostIface host`), not all interfaces. Falls back to a bare
    -- host-published port when the row has no host.
    reach = case portM >>= mkPort of
      Nothing -> noNetwork
      Just p -> case hostM of
        Just h -> listening (HostIface h) p
        Nothing -> hostPort p
  pure
    { source: FromRegistry
    , project: map mkProjectSlug (str o "projectSlug")
    , localName: fromMaybe role (str o "projectName")
    , role: mkRole role
    , host: hostM
    , executor: parseStartCommand (fromMaybe "" (str o "startCommand"))
    , artifact: Nothing
    , reachability: reach
    , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
    , restart: { base: Always, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
    , rawDeps: []
    , rawRoutes: []
    , selectors: []
    , extra: Map.empty
    }

-- | What one registry ROW claims: the canonical id it will be filed under, and
-- | the public port it asks for.
type RegistryClaim = { serviceId :: String, publicPort :: Int }

-- | The raw claims a registry makes, one per row — BEFORE reconcile merges and
-- | before `servePlan` judges.
-- |
-- | `ingestRegistry` cannot answer this question. Reconcile keys services by
-- | canonical `projectSlug:role`, so two rows sharing that pair collapse into
-- | ONE service and the loser vanishes with no diagnostic anywhere. On the live
-- | fleet (2026-08-17) that is 53 rows → 50 services. The drift check compares
-- | against these claims, which is what lets it say "the registry declares
-- | :3033 and nothing in the plan accounts for it" instead of silently agreeing.
-- |
-- | Rows with no `role` (ingest-skipped) or no `port` (nothing to bind) claim
-- | nothing and are omitted — same leniency as `decodeRow`.
registryClaims :: Json -> Array RegistryClaim
registryClaims json = fromMaybe [] do
  obj <- toObject json
  servers <- toArray =<< FO.lookup "servers" obj
  pure (A.mapMaybe claim servers)
  where
  claim j = do
    o <- toObject j
    role <- str o "role"
    port <- int o "port"
    -- the canonical id reconcile will file this row under (see Reconcile);
    -- a slug-less row is keyed by its bare role, as there.
    pure { serviceId: maybe role (\slug -> slug <> ":" <> role) (str o "projectSlug"), publicPort: port }

str :: Object Json -> String -> Maybe String
str o k = FO.lookup k o >>= toString

int :: Object Json -> String -> Maybe Int
int o k = round <$> (FO.lookup k o >>= toNumber)
