-- | Conformance column for the supervisor's pure tick-transition
-- | (`Bosun.Supervisor` — the relaunch-storm fix). Like `Conformance.Main`, it
-- | is I/O-free: a scripted sequence of (now, observations) is threaded through
-- | `refine → derive launches → recordLaunches` (a faithful miniature of the CLI
-- | supervise loop, minus the live probes), and the per-tick digest is printed.
-- |
-- | Because time is a *parameter* and the transition is pure, node and
-- | backend-go must print this byte-identically — the same gate `plan` and
-- | `applyScript` already pass. The script walks every branch: a Down bring-up,
-- | the boot-grace `Starting` that kills the storm, recovery to `Running`, a
-- | crash → `Restart`, the `InBackoff` throttle, escalating backoff, and a final
-- | recovery that resets the counters.
module Bosun.Conformance.SuperviseMain where

import Prelude

import Bosun.Atoms (ServiceId, mkServiceId)
import Bosun.Plan (Snapshot, Status(..))
import Bosun.Supervisor
  ( Launch, Observation, SupConfig, SupState
  , backoffMs, emptySupState, initialSvc, recordLaunches, refine, uniform
  )
import Data.Array (foldl, mapMaybe)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)

cfg :: SupConfig
cfg = { bootGraceMs: 60000.0, backoffBaseMs: 5000.0, backoffMaxMs: 60000.0, maxRetries: Nothing }

web :: ServiceId
web = mkServiceId "web"

-- One observation map for the single service this script tracks.
obs :: Status -> Boolean -> Map.Map ServiceId Observation
obs ready groupAlive = Map.singleton web { ready, groupAlive }

-- A faithful miniature of the CLI supervise loop: refine the raw observation
-- against launch memory, derive what the planner would launch (Down ⇒ Start,
-- Failed ⇒ Restart), then stamp that launch back into the state.
driveTick :: Number -> SupState -> Map.Map ServiceId Observation -> { refined :: Snapshot, state :: SupState }
driveTick now st o =
  let
    r = refine (uniform cfg) now st o
    toLaunch (Tuple sid s) = case s of
      Down -> Just { id: sid, isRestart: false } :: Maybe Launch
      Failed -> Just { id: sid, isRestart: true }
      _ -> Nothing
    launches = mapMaybe toLaunch (Map.toUnfoldable r.snapshot)
  in
    { refined: r.snapshot, state: recordLaunches (uniform cfg) now launches r.state }

-- (now, ready, groupAlive) — the scripted reality the supervisor reacts to.
script :: Array { now :: Number, ready :: Status, alive :: Boolean }
script =
  [ { now: 0.0,     ready: Down,    alive: false }  -- never launched ⇒ Start
  , { now: 3000.0,  ready: Down,    alive: true  }  -- booting ⇒ Starting (NO relaunch)
  , { now: 6000.0,  ready: Down,    alive: true  }  -- still booting ⇒ Starting
  , { now: 9000.0,  ready: Running, alive: true  }  -- bound ⇒ Running
  , { now: 12000.0, ready: Down,    alive: false }  -- crashed ⇒ Failed ⇒ Restart
  , { now: 15000.0, ready: Down,    alive: false }  -- within backoff ⇒ InBackoff
  , { now: 18000.0, ready: Down,    alive: false }  -- backoff elapsed ⇒ Restart (escalates)
  , { now: 21000.0, ready: Running, alive: true  }  -- recovered ⇒ Running, counters reset
  ]

main :: Effect Unit
main = do
  log "SUPERVISE — pure tick-transition over a scripted rig"
  log ""
  _ <- foldl step (pure emptySupState) script
  log ""
  log "backoff windows (ms): 1..6"
  log (joinInts (map (\n -> backoffMs cfg n) [ 1, 2, 3, 4, 5, 6 ]))
  where
  step acc s = do
    st <- acc
    let r = driveTick s.now st (obs s.ready s.alive)
        svc = fromMaybe (initialSvc s.now) (Map.lookup web r.state)
        refined = fromMaybe Down (Map.lookup web r.refined)
    log
      ( "t=" <> show s.now
          <> "  web=" <> tok refined
          <> "  restarts=" <> show svc.restarts
          <> "  fails=" <> show svc.fails
          <> "  susp=" <> maybe "none" show svc.suspendedUntil
      )
    pure r.state

tok :: Status -> String
tok = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"

joinInts :: Array Number -> String
joinInts = foldl (\acc n -> acc <> " " <> show n) ""
