-- | The observation edge (DESIGN §4, PRINCIPLES.md — Phase 5/6).
-- |
-- | `observe :: Maybe Host -> Probe -> Effect Status` is the first genuinely
-- | effectful edge beyond the file read: a *synchronous* probe of running
-- | reality (the no-Aff seam holds — straight-line `execSync`, no callbacks).
-- | It is read-only; nothing here mutates the rig.
-- |
-- | A probe that cannot reach its target returns `Down`, and a probe kind we
-- | cannot yet observe returns `Unknown` with a reason — never silently coerced
-- | to `Down` (PRINCIPLES.md). `observeSnapshot` walks a reconciled deployment
-- | and produces the `Snapshot` that `plan` consumes, closing the
-- | observe → plan loop.
module Bosun.CLI.Observe
  ( observe
  , observeSnapshot
  ) where

import Prelude

import Bosun.Atoms (Host, ServiceId, unHost, unPort)
import Bosun.Exposure (Exposure(..))
import Bosun.Health (Probe(..))
import Bosun.Plan (Reason(..), Snapshot, Status(..))
import Bosun.Service (Deployment, LooseService, deploymentServices)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn2, EffectFn3, runEffectFn2, runEffectFn3)

-- host → port → path → HTTP status code as a string ("000" if unreachable)
foreign import probeHttpImpl :: EffectFn3 String Int String String
-- host → port → reachable?
foreign import probeTcpImpl :: EffectFn2 String Int Boolean

observe :: Maybe Host -> Probe -> Effect Status
observe mh = case _ of
  HttpGet g -> do
    code <- runEffectFn3 probeHttpImpl (hostAddr mh) (unPort g.port) g.path
    pure (httpStatus g.expectStatus code)
  TcpConnect p -> do
    ok <- runEffectFn2 probeTcpImpl (hostAddr mh) (unPort p)
    pure (if ok then Running else Down)
  NoProbe -> pure (Unknown (ProbeUnreachable "no readiness probe"))
  _ -> pure (Unknown (ProbeUnreachable "probe kind not observable yet"))

observeSnapshot :: Deployment -> Effect Snapshot
observeSnapshot dep = do
  entries <- traverse probeOne (deploymentServices dep)
  pure (Map.fromFoldable entries)
  where
  probeOne :: LooseService -> Effect (Tuple ServiceId Status)
  probeOne s = Tuple s.id <$> observe s.host (effectiveProbe s)

-- A service with no declared readiness probe but a listening port is observable
-- by the port itself: a successful TCP connect is the implicit liveness signal.
-- (A docker `ExecCmd` healthcheck runs inside the container and is not
-- host-observable, so it is left to the explicit-probe path.)
effectiveProbe :: LooseService -> Probe
effectiveProbe s = case s.readiness of
  NoProbe -> case s.exposure of
    HostPort p -> TcpConnect p
    InternalPort p -> TcpConnect p
    _ -> NoProbe
  p -> p

-- The probing machine is the mbp, so `mbp` services are reached on localhost
-- and `macmini` services over the tailnet. Other hosts are a best-effort
-- passthrough.
hostAddr :: Maybe Host -> String
hostAddr mh = case map unHost mh of
  Just "mbp" -> "localhost"
  Just "macmini" -> "andrews-mac-mini"
  Just other -> other
  Nothing -> "localhost"

httpStatus :: Int -> String -> Status
httpStatus expect code
  | code == "000" = Down            -- nothing answered the connection
  | code == show expect = Running   -- answered with the expected status
  | otherwise = Failed              -- answered, but the wrong status
