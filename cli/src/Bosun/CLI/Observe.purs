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
  , observeSupSnapshot
  , observeHoldings
  , observeHolding
  ) where

import Prelude

import Bosun.Atoms (Host, ServiceId, unAbsPath, unHost, unPort)
import Bosun.CLI.Exec as Exec
import Bosun.Executor (Executor(..))
import Bosun.Holding (Holding(..), HoldingEvidence, holdingScript, judgeHolding, readHoldingEvidence, tcpPorts)
import Bosun.Target (TargetMap, isRemote, resolveTarget)
import Bosun.Substrate (pidPath)
import Bosun.Exposure (Exposure(..))
import Bosun.Reachability (classify)
import Bosun.Health (Probe(..))
import Bosun.Plan (Reason(..), Snapshot, Status(..))
import Bosun.Service (Deployment, LooseService, deploymentServices)
import Bosun.Supervisor (Observation)
import Data.Map (Map)
import Data.Map as Map
import Data.Array as A
import Data.Maybe (Maybe(..))
import Data.String.Common (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn1, EffectFn2, EffectFn3, runEffectFn1, runEffectFn2, runEffectFn3)

-- host → port → path → HTTP status code as a string ("000" if unreachable)
foreign import probeHttpImpl :: EffectFn3 String Int String String
-- host → port → reachable?
foreign import probeTcpImpl :: EffectFn2 String Int Boolean
-- pid-file path → is any process in the recorded process GROUP alive?
foreign import probePgidAliveImpl :: EffectFn1 String Boolean
-- socket path → does the socket file exist?
foreign import probeSocketImpl :: EffectFn1 String Boolean
-- host command line → did it exit 0? (the only "whoever started it" reading)
foreign import probeExecImpl :: EffectFn1 String Boolean

observe :: Maybe Host -> Probe -> Effect Status
observe mh = case _ of
  HttpGet g -> do
    code <- runEffectFn3 probeHttpImpl (hostAddr mh) (unPort g.port) g.path
    pure (httpStatus g.expectStatus code)
  TcpConnect p -> do
    ok <- runEffectFn2 probeTcpImpl (hostAddr mh) (unPort p)
    pure (if ok then Running else Down)
  SocketReady path -> do
    ok <- runEffectFn1 probeSocketImpl (unAbsPath path)
    pure (if ok then Running else Down)
  -- The only probe that answers "is it up, WHOEVER started it". Everything
  -- else here reads either a port we expect this service to bind or a process
  -- group we ourselves recorded, and a singleton daemon started by hand — or
  -- by DeepStar — satisfies neither while being perfectly alive.
  HostExec argv -> do
    ok <- runEffectFn1 probeExecImpl (execLine argv)
    pure (if ok then Running else Down)
  NoProbe -> pure (Unknown (ProbeUnreachable "no readiness probe"))
  -- ProcessAlive is keyed by the recorded pid-file, which only `observeService`
  -- (with the ServiceId in scope) can locate.
  ProcessAlive -> pure (Unknown (ProbeUnreachable "process probe needs the service context"))
  _ -> pure (Unknown (ProbeUnreachable "probe kind not observable yet"))

observeSnapshot :: Deployment -> Effect Snapshot
observeSnapshot dep = do
  entries <- traverse probeOne (deploymentServices dep)
  pure (Map.fromFoldable entries)
  where
  probeOne :: LooseService -> Effect (Tuple ServiceId Status)
  probeOne s = Tuple s.id <$> observeService s

-- | The supervisor's reading: for every service, BOTH its readiness probe and
-- | whether the process GROUP `apply` launched is still alive (`pidPath s.id`).
-- | The pgid signal is what lets `Bosun.Supervisor.refine` tell "launched, still
-- | booting" (group alive, port not yet bound ⇒ `Starting`) from "actually down"
-- | (group gone) — the relaunch-storm fix. Closes observe → refine → plan.
observeSupSnapshot :: Deployment -> Effect (Map ServiceId Observation)
observeSupSnapshot dep = do
  entries <- traverse probeOne (deploymentServices dep)
  pure (Map.fromFoldable entries)
  where
  probeOne :: LooseService -> Effect (Tuple ServiceId Observation)
  probeOne s = do
    ready <- observeService s
    groupAlive <- runEffectFn1 probePgidAliveImpl (pidPath s.id)
    pure (Tuple s.id { ready, groupAlive })

-- Service-aware probe: `ProcessAlive` is checked against the process GROUP
-- `apply` recorded for this service (`pidPath s.id`) — the honest liveness signal
-- for a UDP/socket/no-network daemon (es9/link/fh2) a TCP probe would mis-read,
-- and the supervisor's keep-alive signal for them. Everything else delegates to
-- the host/network `observe`.
observeService :: LooseService -> Effect Status
observeService s = case effectiveProbe s of
  ProcessAlive -> do
    alive <- runEffectFn1 probePgidAliveImpl (pidPath s.id)
    pure (if alive then Running else Down)
  p -> observe s.host p

-- A service with no declared readiness probe but a listening port is observable
-- by the port itself: a successful TCP connect is the implicit liveness signal.
-- (A docker `ExecCmd` healthcheck runs inside the container and is not
-- host-observable, so it is left to the explicit-probe path.)
effectiveProbe :: LooseService -> Probe
effectiveProbe s = case s.readiness of
  NoProbe -> case classify s.reachability of
    HostPort p -> TcpConnect p
    InternalPort p -> TcpConnect p
    _ -> NoProbe
  p -> p

-- Docker's `test:` convention names the FORM in the first token, not the
-- program: `CMD` is argv, `CMD-SHELL` is a shell line. Both are run here as a
-- shell line (the same space-joined convention `renderCommand` uses for a
-- service's own start command), so the leading token is dropped rather than
-- executed as if it were a binary called `CMD`.
execLine :: Array String -> String
execLine argv = joinWith " " case A.uncons argv of
  Just { head, tail } | head == "CMD" || head == "CMD-SHELL" -> tail
  _ -> argv

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

-- | WHOSE process holds each service's port (Bosun.Holding) — the reading that
-- | tells an owned `running` from a stranger answering on our port. One
-- | evidence script covers every local service with a TCP port; a service on a
-- | remote host is reported unobservable rather than guessed at, since `lsof`
-- | here would be describing the wrong machine.
-- |
-- | Not part of the tick. Nothing acts on a stranger unasked, so this runs only
-- | where the answer is read: `/state`, and a `restart` about to act.
observeHoldings :: TargetMap -> Array LooseService -> Effect (Map ServiceId Holding)
observeHoldings targets svcs = do
  let
    ported = A.filter (\s -> isLocal s && not (A.null (tcpPorts s.reachability))) svcs
    ports = A.nub (A.concatMap (\s -> tcpPorts s.reachability) ported)
  ev <-
    if A.null ported then pure (readHoldingEvidence { ran: false, output: "" })
    else do
      res <- Exec.execLine (holdingScript ports (map (\s -> { sid: s.id, cwd: serviceCwd s }) ported))
      pure (readHoldingEvidence { ran: res.ok, output: res.message })
  pure (Map.fromFoldable (map (\s -> Tuple s.id (judgeOne ev s)) svcs))
  where
  isLocal s = not (isRemote (resolveTarget targets s.host))

  judgeOne :: HoldingEvidence -> LooseService -> Holding
  judgeOne ev s =
    if isLocal s then judgeHolding ev { sid: s.id, ports: tcpPorts s.reachability, cwd: serviceCwd s }
    else Unobservable "the service runs on a remote host"

-- | One service's holding (what `restart` reads just before it acts).
observeHolding :: TargetMap -> LooseService -> Effect Holding
observeHolding targets s = do
  m <- observeHoldings targets [ s ]
  pure (fromMaybe' m)
  where
  fromMaybe' m = case Map.lookup s.id m of
    Just h -> h
    Nothing -> Unobservable "no reading"

-- The directory a process service is launched from — what a claimable
-- stranger must share. Other executors have none, so nothing they hold is
-- claimable.
serviceCwd :: LooseService -> Maybe String
serviceCwd s = case s.launch.executor of
  Process p -> Just (unAbsPath p.cwd)
  _ -> Nothing
