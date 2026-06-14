-- | The `bosun` CLI.
-- |
-- |   bosun check <compose.yml> <registry.json>
-- |     ingest both sources → reconcile (facet model) → validate → report,
-- |     over the LIVE files. The cross-source alias map is built automatically
-- |     by matching a registry row's startCommand cwd against a compose
-- |     service's build context — same directory basename ⇒ same logical
-- |     service (so the native and containerised facets group).
-- |
-- |   bosun            (no args) — the built-in §7 fixture demo.
module Bosun.CLI.Main where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Atoms (AbsPath, Port, ServiceId, mkAbsPath, mkHost, mkPort, mkProjectSlug, mkServiceId, unAbsPath, unProjectSlug)
import Bosun.CLI.IO (argv, readJsonFile, readYamlFile)
import Bosun.Edge (Gate(..), Requirement(..))
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Reconcile (AliasMap, reconcile)
import Bosun.Report (renderReport)
import Bosun.Service (ServiceInstance, Source(..), mkRole, unRole)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Array as A
import Data.Either (Either(..), either)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, fromMaybe)
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Partial.Unsafe (unsafePartial)

main :: Effect Unit
main = do
  args <- argv
  case args of
    [ "check", composePath, registryPath ] -> runCheck composePath registryPath
    _ -> runDemo

-- ── bosun check <compose> <registry> ────────────────────────────────────────

runCheck :: String -> String -> Effect Unit
runCheck composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
    vErrors = either identity (const []) (toEither (validate r.deployment))
  log ("bosun " <> version <> " — check " <> composePath <> " + " <> registryPath)
  log ""
  log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)

-- Bridge compose ↔ registry by shared directory basename (the registry row's
-- cwd vs the compose service's build context). DECISIONS "alias-map for MVP",
-- derived rather than hand-maintained.
buildAliases :: Array ServiceInstance -> AliasMap
buildAliases insts =
  Map.fromFoldable (insts # A.mapMaybe aliasFor)
  where
  canon :: Map String ServiceId
  canon = Map.fromFoldable (insts # A.mapMaybe registryKey)

  registryKey si = case si.source of
    FromRegistry -> (\k -> Tuple k (canonId si)) <$> dirKey si
    _ -> Nothing

  aliasFor si = case si.source of
    FromCompose -> do
      k <- dirKey si
      cid <- Map.lookup k canon
      pure (Tuple si.localName cid)
    _ -> Nothing

canonId :: ServiceInstance -> ServiceId
canonId si = case si.project of
  Just slug -> mkServiceId (unProjectSlug slug <> ":" <> unRole si.role)
  Nothing -> mkServiceId si.localName

dirKey :: ServiceInstance -> Maybe String
dirKey si = case si.executor of
  Process p -> Just (basename (unAbsPath p.cwd))
  Container (ContainerSpec cs) -> case cs.source of
    Right (BuildContext b) -> Just (basename b.context)
    _ -> Nothing
  _ -> Nothing

basename :: String -> String
basename p = fromMaybe p (A.last (A.filter (_ /= "") (String.split (Pattern "/") p)))

-- ── built-in §7 fixture demo (no args) ──────────────────────────────────────

runDemo :: Effect Unit
runDemo = do
  log ("bosun " <> version <> " — check (built-in §7 fixture)")
  log ""
  let
    aliases = Map.singleton "tidal-frontend" (mkServiceId "uniform-romeo-romeo-juliet:frontend")
    r = reconcile aliases fixture
    vErrors = either identity (const []) (toEither (validate r.deployment))
  log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)

fixture :: Array ServiceInstance
fixture =
  [ inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "uniform-romeo-romeo-juliet")
      , localName = "psd3-tilted-radio"
      , host = Just (mkHost "mbp")
      , executor = Process { cwd: absPath "/Users/afc/work/afc-work/purescript-hylograph-showcases/psd3-tilted-radio", command: "npx serve", env: [] }
      , exposure = HostPort (port_ 3013)
      }
  , inst
      { source = FromCompose
      , localName = "tidal-frontend"
      , host = Just (mkHost "macmini")
      , executor = Container (ContainerSpec { source: Left (ImageRef "tidal-frontend"), internalPort: Nothing, publish: Nothing })
      , exposure = NoNetwork
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-backend"
      , role = mkRole "api"
      , host = Just (mkHost "mbp")
      , exposure = HostPort (port_ 3000)
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-frontend"
      , host = Just (mkHost "mbp")
      , exposure = HostPort (port_ 3001)
      , rawDeps = [ { to: "minard:api", ordering: Nothing, requirement: Just (Requires OnHealthy) } ]
      }
  ]

inst :: ServiceInstance
inst =
  { source: FromRegistry
  , project: Nothing
  , localName: "svc"
  , role: mkRole "frontend"
  , host: Just (mkHost "mbp")
  , executor: Unmanaged "svc"
  , exposure: NoNetwork
  , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))
