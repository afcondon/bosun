-- | Ingest a docker-compose file (already parsed from YAML to `Json` by the
-- | CLI's js-yaml FFI) into loose `ServiceInstance`s — the *containerised*
-- | facet partner to the registry's native facet.
-- |
-- | Each `services:` entry becomes a `ServiceInstance`: `build`/`image` -> a
-- | `Container` executor, `ports:` -> a `hostPort` reachability (binds every
-- | interface, like `0.0.0.0:p`; else `noNetwork`, behind the edge),
-- | `depends_on:` -> `rawDeps` (array form = `Requires OnStarted`; map
-- | form reads `condition:`), `healthcheck:` presence -> a readiness probe,
-- | `profiles:` -> `Selector`s. Pure; compose runs on the macmini, so the host
-- | is tagged `macmini` (the deploy target — configurable later).
-- |
-- | PHASE 3B SCOPE: unmodeled fields (networks, container_name, build details
-- | beyond context) are dropped rather than stashed in `extra`; the
-- | byte-identical round-trip (`extra` passthrough) is Phase 6.
module Bosun.Adapters.Compose (ingestCompose) where

import Prelude

import Bosun.Atoms (Port, mkHost, mkPort, mkRoutePath)
import Bosun.Edge (DepOrdering(..), Gate(..), Requirement(..))
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Reachability (hostPort, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Selector (Selector(..))
import Bosun.Service (RawDep, RawRoute, ServiceInstance, Source(..), mkRole)
import Data.Argonaut.Core (Json, toArray, toObject, toString)
import Data.Array as A
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (uncurry)
import Foreign.Object (Object)
import Foreign.Object as FO

ingestCompose :: Json -> Array ServiceInstance
ingestCompose json = fromMaybe [] do
  root <- toObject json
  servicesJson <- FO.lookup "services" root
  services <- toObject servicesJson
  pure (A.mapMaybe (uncurry decodeService) (FO.toUnfoldable services))

decodeService :: String -> Json -> Maybe ServiceInstance
decodeService name sj = do
  o <- toObject sj
  pure
    { source: FromCompose
    , project: Nothing
    , localName: name
    , role: mkRole (roleFromName name)
    , host: Just (mkHost "macmini")   -- compose's deploy target
    , executor: executorOf name o
    , reachability: maybe noNetwork hostPort (publishPort o)
    , health: { liveness: probeOf o, readiness: probeOf o, startup: Nothing }
    , restart: { base: UnlessStopped, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
    , rawDeps: dependsOn o <> xbosunDeps o
    , rawRoutes: xbosunRoutes o
    , selectors: map Profile (strArray o "profiles")
    , extra: Map.empty
    }

-- "tidal-frontend" -> "frontend"; "edge" -> "edge"
roleFromName :: String -> String
roleFromName name = fromMaybe name (A.last (String.split (Pattern "-") name))

executorOf :: String -> Object Json -> Executor
executorOf name o = case FO.lookup "image" o >>= toString of
  Just img -> Container (ContainerSpec { source: Left (ImageRef img), internalPort: Nothing, publish: publishPort o })
  Nothing -> case FO.lookup "build" o >>= toObject of
    Just b -> Container (ContainerSpec
      { source: Right (BuildContext { context: fromMaybe "" (str b "context"), dockerfile: str b "dockerfile" })
      , internalPort: Nothing
      , publish: publishPort o
      })
    Nothing -> Unmanaged name

-- first "host:container" entry -> the published host port
publishPort :: Object Json -> Maybe Port
publishPort o = do
  pj <- FO.lookup "ports" o
  ps <- toArray pj
  first <- A.head ps
  s <- toString first
  hostPart <- A.head (String.split (Pattern ":") s)
  Int.fromString hostPart >>= mkPort

-- a healthcheck present -> a (non-NoProbe) readiness signal
probeOf :: Object Json -> Probe
probeOf o = if isJust (FO.lookup "healthcheck" o) then ExecCmd (healthTest o) else NoProbe

healthTest :: Object Json -> Array String
healthTest o = fromMaybe [] do
  hc <- FO.lookup "healthcheck" o >>= toObject
  arr <- FO.lookup "test" hc >>= toArray
  pure (A.mapMaybe toString arr)

dependsOn :: Object Json -> Array RawDep
dependsOn o = case FO.lookup "depends_on" o of
  Nothing -> []
  Just dj -> case toArray dj of
    Just arr -> A.mapMaybe (\x -> toString x <#> \n -> rawDep n OnStarted) arr
    Nothing -> case toObject dj of
      Just obj -> map (uncurry (\n cj -> rawDep n (gateOf cj))) (FO.toUnfoldable obj)
      Nothing -> []

rawDep :: String -> Gate -> RawDep
rawDep n gate = { to: n, ordering: Just StartAfter, requirement: Just (Requires gate) }

gateOf :: Json -> Gate
gateOf cj = case toObject cj >>= str' "condition" of
  Just "service_healthy" -> OnHealthy
  Just "service_completed_successfully" -> OnCompleted
  _ -> OnStarted
  where
  str' k ob = FO.lookup k ob >>= toString

-- | The full requirement gradient compose can't natively express, carried in a
-- | service's `x-bosun.requires:` map (target -> kind). compose `x-` keys are
-- | the sanctioned home for "the stuff that has no other format" (the overlay
-- | philosophy, applied inline). Each entry adds a typed dependency edge:
-- |
-- |   web:
-- |     x-bosun:
-- |       requires:
-- |         logger-sidecar: binds-to     # ●●-side of the §4.3 gradient
-- |         external-vault: requisite
-- |         metrics: wants
xbosunDeps :: Object Json -> Array RawDep
xbosunDeps o = fromMaybe [] do
  xb <- FO.lookup "x-bosun" o >>= toObject
  reqs <- FO.lookup "requires" xb >>= toObject
  pure (map (uncurry (\n kj -> typedDep n (fromMaybe "requires" (toString kj)))) (FO.toUnfoldable reqs))

typedDep :: String -> String -> RawDep
typedDep n kind = { to: n, ordering: Just StartAfter, requirement: Just (reqOf kind) }

reqOf :: String -> Requirement
reqOf = case _ of
  "wants" -> Wants
  "requisite" -> Requisite
  "binds-to" -> BindsTo
  "part-of" -> PartOf
  _ -> Requires OnStarted

-- | Reverse-proxy routes (the traffic channel, §3.6/D-5) — compose has no native
-- | place for them, so they ride in `x-bosun.routes: [{ path, to }]`. Each is a
-- | data/traffic edge from this (proxy) service to a backend, NOT a lifecycle
-- | edge — kept in a separate graph.
xbosunRoutes :: Object Json -> Array RawRoute
xbosunRoutes o = fromMaybe [] do
  xb <- FO.lookup "x-bosun" o >>= toObject
  arr <- FO.lookup "routes" xb >>= toArray
  pure (A.mapMaybe decodeRoute arr)
  where
  decodeRoute rj = do
    ro <- toObject rj
    to <- str ro "to"
    path <- str ro "path"
    pure { to, path: mkRoutePath path }

strArray :: Object Json -> String -> Array String
strArray o k = fromMaybe [] (FO.lookup k o >>= toArray <#> A.mapMaybe toString)

str :: Object Json -> String -> Maybe String
str o k = FO.lookup k o >>= toString
