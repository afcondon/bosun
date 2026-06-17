-- | The supervisor's pure tick-transition — the `recorded` state DESIGN D-7
-- | always reserved, made concrete for the live `bosun supervise` daemon.
-- |
-- | `bosun supervise` is "`plan` on a loop", but a stateless loop storms: a
-- | slow-boot service (a BEAM, a `spago run`) is observed `Down` on its
-- | readiness probe for several ticks while it binds, so the planner re-`Start`s
-- | it every tick — `beam.smp`×4, `spago`×6, the port never bound (the bug the
-- | Chair session hit, HANDOFF-ENGINE.md). The fix is launch *memory*: once we
-- | launch a service its process GROUP is alive (we hold its pgid) long before
-- | its port binds, and "group alive but not ready" is `Starting`, which the
-- | planner already turns into `NoOp`. This module threads that memory across
-- | ticks and folds it back into the `Snapshot` the planner sees.
-- |
-- | It is PURE and time is a *parameter* (`Millis` passed in at the seam), so the
-- | whole transition is deterministic and rides go-conformance byte-identically
-- | — exactly like `plan` / `applyScript`. The effectful loop (clock, timer,
-- | HTTP) stays in the CLI shim.
-- |
-- | Two states drive two behaviours:
-- |   * boot-grace — a launched service whose group is alive but isn't ready is
-- |     `Starting` until `bootGraceMs` elapses (then `Failed`: wedged, relaunch).
-- |   * backoff — after a crash relaunch we arm `suspendedUntil`; while suspended
-- |     the service reads `InBackoff` (the planner `NoOp`s it), so a fast-crash
-- |     loop is throttled exponentially rather than piled on.
-- |
-- | `restarts` (cumulative) and `since` (last transition) are the same
-- | bookkeeping ADR D-S1 wants for the Chair's `↻ N` badge — built once, used
-- | twice. `SupConfig` is deliberately the seed of a future per-service typed
-- | policy: it mirrors `Bosun.Health.RestartPolicy` (`backoff { minSec,
-- | maxRetries }`), so when the validated `Service` carries its own
-- | `RestartPolicy` the knobs resolve per service instead of one for the group.
module Bosun.Supervisor
  ( Millis
  , Observation
  , SvcState
  , SupState
  , SupConfig
  , Launch
  , defaultConfig
  , emptySupState
  , initialSvc
  , lookupSvc
  , backoffMs
  , refine
  , recordLaunches
  ) where

import Prelude

import Bosun.Atoms (ServiceId)
import Bosun.Plan (Snapshot, Status(..))
import Data.Foldable (foldr)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Tuple (Tuple(..))

-- | Milliseconds since some fixed epoch — supplied by the caller's clock at the
-- | seam, never read here, so the transition stays pure/deterministic.
type Millis = Number

-- | One service's live-edge reading this tick: its readiness probe result, plus
-- | whether the process GROUP `apply` launched is still alive (the pgid signal,
-- | `kill(-pgid, 0)`). A service we launched whose group is alive but whose
-- | readiness hasn't passed is BOOTING, not Down — the distinction the
-- | relaunch-storm fix turns on.
type Observation =
  { ready :: Status
  , groupAlive :: Boolean
  }

-- | Per-service bookkeeping threaded across ticks. `restarts` is the cumulative
-- | badge the Chair renders (ADR D-S1); `fails` is the consecutive-failure count
-- | that drives exponential backoff and resets the moment the service is healthy
-- | again. `since` is the last-transition timestamp (the badge's "Xs ago").
type SvcState =
  { restarts       :: Int
  , fails          :: Int
  , launchedAt     :: Maybe Millis
  , suspendedUntil :: Maybe Millis
  , status         :: Status
  , since          :: Millis
  }

type SupState = Map ServiceId SvcState

-- | The supervisor's knobs — a deliberate seed for a future per-service typed
-- | `Bosun.Health.RestartPolicy` (`base :: BaseRestart`, `backoff { minSec,
-- | maxRetries }`). Today one policy for the whole group; later, resolve one of
-- | these per service from its `RestartPolicy` at validate.
type SupConfig =
  { bootGraceMs   :: Millis    -- a launched-but-not-ready process is Starting this long
  , backoffBaseMs :: Millis    -- first backoff window after a crash
  , backoffMaxMs  :: Millis    -- exponential cap
  , maxRetries    :: Maybe Int -- give up (stop relaunching) past this; Nothing = forever
  }

-- | Conservative defaults: a 60s boot grace fits a `spago run` / BEAM cold start;
-- | 5s→60s exponential backoff; retry forever (a daemon should come back).
defaultConfig :: SupConfig
defaultConfig =
  { bootGraceMs: 60000.0
  , backoffBaseMs: 5000.0
  , backoffMaxMs: 60000.0
  , maxRetries: Nothing
  }

emptySupState :: SupState
emptySupState = Map.empty

initialSvc :: Millis -> SvcState
initialSvc now =
  { restarts: 0
  , fails: 0
  , launchedAt: Nothing
  , suspendedUntil: Nothing
  , status: Down
  , since: now
  }

lookupSvc :: Millis -> ServiceId -> SupState -> SvcState
lookupSvc now sid = fromMaybe (initialSvc now) <<< Map.lookup sid

-- | Exponential backoff window for the `n`th consecutive failure (1-based),
-- | capped at `backoffMaxMs`: base · 2^(n-1).
backoffMs :: SupConfig -> Int -> Millis
backoffMs cfg fails = min cfg.backoffMaxMs (cfg.backoffBaseMs * pow2 (fails - 1))
  where
  pow2 n = if n <= 0 then 1.0 else 2.0 * pow2 (n - 1)

-- | The pure tick-transition. Given the live observations and the prior state,
-- | decide the `Status` the planner should see for each service — folding launch
-- | memory in (boot-grace → `Starting`, active backoff → `InBackoff`) — and carry
-- | each service's bookkeeping forward (`status`/`since` for the badge; `fails`
-- | and `suspendedUntil` reset on a healthy reading). Restart *counting* and
-- | arming the next backoff happen AFTER the plan, in `recordLaunches` — only the
-- | planner knows what it actually relaunched (incl. D-E5 coupled co-restart).
refine
  :: SupConfig
  -> Millis
  -> SupState
  -> Map ServiceId Observation
  -> { snapshot :: Snapshot, state :: SupState }
refine cfg now prev obs =
  { snapshot: Map.fromFoldable (map (\(Tuple sid r) -> Tuple sid r.refined) stepped)
  , state: Map.fromFoldable (map (\(Tuple sid r) -> Tuple sid r.svc) stepped)
  }
  where
  stepped :: Array (Tuple ServiceId { refined :: Status, svc :: SvcState })
  stepped =
    (Map.toUnfoldable obs :: Array (Tuple ServiceId Observation))
      # map \(Tuple sid o) ->
          let
            s = lookupSvc now sid prev
            refined = decide cfg now s o
          in
            Tuple sid { refined, svc: transition now s refined }

-- | The refined status one service reports to the planner this tick.
decide :: SupConfig -> Millis -> SvcState -> Observation -> Status
decide cfg now s o = case o.ready of
  Running -> Running
  CompletedOk -> CompletedOk
  -- No probe could read it, but its group is alive — best signal we have is
  -- "process exists" (the launchd KeepAlive philosophy). Treat as up.
  Unknown _ | o.groupAlive -> Running
  _
    | suspended -> InBackoff
    | o.groupAlive -> if wedged then Failed else Starting
    | exhausted -> InBackoff
    | isJust s.launchedAt -> Failed   -- we launched it, its group is gone ⇒ crashed
    | otherwise -> Down               -- never launched ⇒ bring it up
  where
  suspended = case s.suspendedUntil of
    Just t -> now < t
    Nothing -> false
  wedged = case s.launchedAt of
    Just l -> now - l >= cfg.bootGraceMs
    Nothing -> false
  exhausted = case cfg.maxRetries of
    Just m -> s.fails >= m
    Nothing -> false

-- | Carry bookkeeping forward: stamp the new refined status (and `since` if it
-- | changed), and reset the backoff/consecutive-fail counters once healthy.
transition :: Millis -> SvcState -> Status -> SvcState
transition now s refined =
  let
    reset = case refined of
      Running -> s { fails = 0, suspendedUntil = Nothing }
      CompletedOk -> s { fails = 0, suspendedUntil = Nothing }
      _ -> s
  in
    reset
      { status = refined
      , since = if s.status == refined then s.since else now
      }

-- | A service the planner decided to launch this tick. `isRestart` distinguishes
-- | a crash relaunch (a `Restart` change — bumps the badge + arms backoff) from a
-- | first bring-up (a `Start` of a `Down` service — sets `launchedAt`, no backoff).
type Launch = { id :: ServiceId, isRestart :: Boolean }

-- | After the plan enacts, stamp launch memory: every launch sets `launchedAt`
-- | (so boot-grace starts ticking) and marks the service `Starting`. A `Restart`
-- | also bumps the cumulative `restarts` badge and the consecutive `fails`, and
-- | arms the next exponential backoff window.
recordLaunches :: SupConfig -> Millis -> Array Launch -> SupState -> SupState
recordLaunches cfg now launches st = foldr stamp st launches
  where
  stamp l acc =
    let
      s = lookupSvc now l.id acc
      since' = if s.status == Starting then s.since else now
      s' =
        if l.isRestart then
          let f = s.fails + 1
          in s
            { restarts = s.restarts + 1
            , fails = f
            , launchedAt = Just now
            , suspendedUntil = Just (now + backoffMs cfg f)
            , status = Starting
            , since = since'
            }
        else
          s
            { launchedAt = Just now
            , suspendedUntil = Nothing
            , status = Starting
            , since = since'
            }
    in
      Map.insert l.id s' acc
