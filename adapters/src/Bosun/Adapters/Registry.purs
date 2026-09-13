-- | Ingest the Marginalia service registry (the `/api/ports` JSON) into loose
-- | `ServiceInstance`s. The registry is the cross-source partner to compose:
-- | it is where the *native/dev* facet of each service lives (mbp, a
-- | `startCommand`, a localhost port), against compose's *containerised* facet.
-- |
-- | A pure decode (`Json -> Array ServiceInstance`): the effectful read of the
-- | JSON file/endpoint happens in the CLI, keeping the no-Aff seam. Decoding is
-- | lenient — the registry shape is known and stable; a row missing its `role`
-- | is skipped rather than failing the whole ingest.
-- |
-- | 2026-09-13: a row's project is read from `projectId`, not the retired
-- | `projectSlug`. Three functions here build the same `<project>:<role>` key
-- | and all three go through `projectRef`, so the identity cannot drift between
-- | what reconcile files a row under and what the claim/hint passes name.
module Bosun.Adapters.Registry (ingestRegistry, RegistryClaim, registryClaims, registryHints) where

import Prelude

import Bosun.Adapters.StartCommand (parseStartCommand)
import Bosun.Atoms (AbsPath, mkAbsPath, mkHost, mkPort, mkProjectId)
import Bosun.Reachability (BindScope(..), hostPort, listening, noNetwork, unixSocket)
import Bosun.Health (BaseRestart(..), Probe(..), defaultRestart)
import Bosun.Serve (ServeHint, readMediation)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Data.Argonaut.Core (Json, toArray, toNumber, toObject, toString)
import Data.Array as A
import Data.Int (round)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as String
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
      Just p -> case hostM of
        Just h -> listening (HostIface h) p
        Nothing -> hostPort p
      -- A row with no port can still SAY where it is. `unix:///path/to.sock` is
      -- how the socket daemons are addressed (es9-daemon, the fh2 daemon), and
      -- without reading it they ingest as `noNetwork` — startable, but with no
      -- address anyone could be told, which is the one thing a broker exists to
      -- provide. `Reachability` has had `Socket` since ADDRESS-TYPE landed; this
      -- is the registry finally able to reach it.
      Nothing -> fromMaybe noNetwork (map unixSocket (socketPathOf =<< str o "url"))
  pure
    { source: FromRegistry
    , project: map mkProjectId (projectRef o)
    , localName: fromMaybe role (str o "projectName")
    , role: mkRole role
    , host: hostM
    , executor: parseStartCommand (fromMaybe "" (str o "startCommand"))
    , artifact: Nothing
    , reachability: reach
    , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
    -- A registry row is a service someone registered to be UP; it says nothing
    -- about restarting, so it takes the shared default with `Always` for the
    -- base (the registry's standing intent) rather than a second, drifting
    -- literal. Anything finer is expressed in a compose facet.
    , restart: defaultRestart { base = Always }
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
-- | canonical `projectId:role`, so two rows sharing that pair collapse into
-- | ONE service and the loser vanishes with no diagnostic anywhere. On the live
-- | fleet (53 rows → 50 services) this is unchanged by the slug→id migration:
-- | the mapping is one-to-one, so the same three rows collapse either way. The
-- | drift check compares
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
    -- a project-less row is keyed by its bare role, as there.
    pure { serviceId: maybe role (\pid -> pid <> ":" <> role) (projectRef o), publicPort: port }

-- | The router-facing hints one registry ROW carries: whether Bosun should be in
-- | this service's data path at all (`serveMode`), and the scheme of its `url`.
-- |
-- | Read from the RAW rows, beside `registryClaims` and for the same reason: a
-- | row's `serveMode` is an instruction to the ROUTER, not a property of the
-- | deployed service, and threading it through `ServiceInstance` → reconcile →
-- | `LooseService` would put an operational preference into the deployment IR
-- | (and would have to answer "what does it mean when the compose facet and the
-- | registry facet disagree", a question nobody is asking).
-- |
-- | `serveMode` is absent from every row written before broker mode existed, and
-- | `readMediation` reads absence as `Proxy` — so re-reading today's fleet.json
-- | produces exactly today's plan.
registryHints :: Json -> Array ServeHint
registryHints json = fromMaybe [] do
  obj <- toObject json
  servers <- toArray =<< FO.lookup "servers" obj
  pure (A.mapMaybe hint servers)
  where
  hint j = do
    o <- toObject j
    role <- str o "role"
    pure
      { serviceId: maybe role (\pid -> pid <> ":" <> role) (projectRef o)
      , mediation: readMediation (fromMaybe "" (str o "serveMode"))
      , scheme: str o "url" >>= schemeOf
      }

-- The scheme of a URL, as written: everything before "://". Not a URL parse —
-- the registry's `url` is a hand-written field and the only part of it we can
-- trust is the part before the punctuation that defines it.
schemeOf :: String -> Maybe String
schemeOf url = case String.indexOf (String.Pattern "://") url of
  Just i | i > 0 -> Just (String.take i url)
  _ -> Nothing

-- The socket path a `unix://` url names. Absolute by construction (`mkAbsPath`
-- refuses anything else), which is what makes it a usable `Socket` address
-- rather than a string somebody has to resolve.
socketPathOf :: String -> Maybe AbsPath
socketPathOf url = String.stripPrefix (String.Pattern "unix://") url >>= mkAbsPath

-- | The project half of a row's canonical `<project>:<role>` identity, read
-- | from `projectId`.
-- |
-- | Marginalia writes a JSON *number* (`"projectId": 55`); a registry written
-- | by hand or by a tool with no Marginalia behind it (the fixtures, and
-- | anything a third party registers) writes a *string*. Both are accepted and
-- | rendered as text, because the identity is a token, not an arithmetic
-- | quantity — nothing downstream ever adds two of these together.
-- |
-- | `Nothing` is the one answer with teeth: reconcile falls back to the row's
-- | `localName`, which is a DIFFERENT namespace, silently. That is precisely
-- | how the retired `projectSlug` would have failed had this field kept its old
-- | name while Marginalia stopped sending it, so the rename is made here, once,
-- | and the old name is not read as a fallback. A row with no project is a row
-- | that genuinely belongs to no project.
projectRef :: Object Json -> Maybe String
projectRef o = FO.lookup "projectId" o >>= \j ->
  case toString j of
    Just s -> Just s
    Nothing -> show <<< round <$> toNumber j

str :: Object Json -> String -> Maybe String
str o k = FO.lookup k o >>= toString

int :: Object Json -> String -> Maybe Int
int o k = round <$> (FO.lookup k o >>= toNumber)
