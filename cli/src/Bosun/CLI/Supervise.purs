-- | `bosun supervise <compose> <registry>` — the resident keep-alive daemon
-- | (ROADMAP Stage 2 delta #2). Where `serve` is a lazy-spawn *router* (proxy +
-- | idle-reap), `supervise` is the opposite lifecycle: bring the deployment UP
-- | and KEEP it up, restarting what crashes — yet it exposes the SAME `/state` +
-- | `/control/*` HTTP surface as `serve` (the HANDOFF-CHAIR contract), so the
-- | Chair drives it with no change.
-- |
-- | The decision tier is the PURE core, unchanged: `supervise` is just `plan`
-- | run on a loop. Each tick observes the rig, plans against desired, and enacts
-- | the resulting Start/Restart changes (`baseChange` already maps `Failed →
-- | Restart`, `Down → Start`, `Running → NoOp`, `InBackoff → NoOp`). Only the
-- | watch-loop and the HTTP surface are new, and they live in the JS shim
-- | (`superviseImpl`) — the one place the no-Aff seam yields, exactly as `serve`.
-- |
-- | `desiredUp` makes a manual STOP HOLD ("stop means stop", ADR-aligned): a
-- | `POST /control/down` sets it false and suspends auto-restart until a
-- | `POST /control/up`. `POST /control/restart?service=<id>` forces ONE service
-- | to restart by marking it `Failed` in the observed snapshot and letting the
-- | pure planner do the rest (incl. D-E5 coupled co-restart) — no ref-minting,
-- | no special path.
module Bosun.CLI.Supervise (runSupervise, superviseResident) where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Apply (Command(..), applyScript, downScript)
import Bosun.Atoms (ServiceId, mkServiceId, unServiceId)
import Bosun.CLI.Exec (execLine)
import Bosun.CLI.IO (readJsonFile, readYamlFile)
import Bosun.CLI.Observe (observeSupSnapshot)
import Bosun.CLI.Resident (Resident, nowMs, runResident)
import Bosun.Plan (Change(..), Plan, Status(..), plan, planSteps)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderCommand, renderReport)
import Bosun.Service (Deployment, ValidatedDeployment, unServiceRef)
import Bosun.Supervisor (Launch, SupConfig, SupState, SvcState, defaultConfig, emptySupState, recordLaunches, refine)
import Bosun.Target (TargetMap, defaultTargets)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (intercalate, traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Uncurried (mkEffectFn2)

defaultStatusPort :: Int
defaultStatusPort = 3996

intervalMs :: Int
intervalMs = 3000

-- | `bosun supervise [--port N] <compose> <registry>`. The status port defaults
-- | to 3996; pass `--port` to run one supervisor PER GROUP, each on its own port
-- | (a group = one deployment), so the Chair polls/controls each independently.
runSupervise :: Maybe Int -> String -> String -> Effect Unit
runSupervise mPort composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
    dep = r.deployment
  log ("bosun " <> version <> " — supervise " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate dep) of
    Left vErrors -> do
      log "cannot supervise: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> superviseResident defaultTargets mPort dep vd >>= runResident

-- | Build the supervise `Resident` — Refs for desired-state and launch memory,
-- | the observe→refine→plan→enact `tick`, the `/state` renderer, the `/control`
-- | handler — and run the initial bring-up, returning the record for
-- | `runResident`. Extracted from `runSupervise` so the Go-column conformance
-- | harness (`Bosun.Conformance.SuperviseMain`) drives the IDENTICAL keep-alive
-- | logic under backend-go that the node CLI runs — the point of the Menagerie's
-- | dual-runtime parity test (mirrors `Bosun.CLI.Docker.dockerResident`). The
-- | `targets` are threaded (not hardcoded) so a remote-host supervise resolves
-- | the same way `apply` does.
superviseResident :: TargetMap -> Maybe Int -> Deployment -> ValidatedDeployment -> Effect Resident
superviseResident targets mPort dep vd = do
  desiredUp <- Ref.new true
  -- The threaded `recorded` state (D-7): launch memory across ticks. This is
  -- what makes `supervise` more than a stateless plan-loop — without it a
  -- slow-boot service re-Starts every tick (the relaunch storm).
  supRef <- Ref.new emptySupState
  let
    cfg :: SupConfig
    cfg = defaultConfig

    runOne sc = case sc.command of
      Manual note -> log ("  · skip (manual): " <> note)
      command -> do
        let line = renderCommand command
        res <- execLine line
        log ("  " <> (if res.ok then "✓" else "✗") <> " " <> line)

    enact label script =
      when (not (A.null script)) do
        log ("supervise: " <> label)
        traverse_ runOne (A.sortWith _.stage script)

    -- Which services this plan launches, and whether each is a crash
    -- relaunch (Restart) or a first bring-up (Start) — so `recordLaunches`
    -- bumps the badge + arms backoff only for the former.
    launchesOf :: Plan -> Array Launch
    launchesOf p = A.mapMaybe toLaunch (planSteps p)
      where
      toLaunch step = case step.change of
        Start ref -> Just { id: unServiceRef ref, isRestart: false }
        Restart ref _ -> Just { id: unServiceRef ref, isRestart: true }
        _ -> Nothing

    -- One reconcile pass against an already-refined observed snapshot:
    -- plan → enact → stamp launch memory.
    enactPlan label now observed = do
      let p = plan vd { desired: vd, recorded: Nothing, observed }
      enact label (applyScript targets vd p)
      Ref.modify_ (recordLaunches cfg now (launchesOf p)) supRef

    bringUp = do
      now <- nowMs
      enactPlan "bring-up" now Map.empty

    bringDown = enact "teardown" (downScript targets vd)

    tick = do
      up <- Ref.read desiredUp
      obs <- observeSupSnapshot dep
      now <- nowMs
      prev <- Ref.read supRef
      let refined = refine cfg now prev obs
      Ref.write refined.state supRef
      when up (enactPlan "reconcile (keep-alive)" now refined.snapshot)

    stateBody = do
      st <- Ref.read supRef
      up <- Ref.read desiredUp
      pure (snapshotBody up st)

    control = mkEffectFn2 \verb arg -> case verb of
      "up" -> do
        Ref.write true desiredUp
        bringUp
        pure "up: desired=up, bringing up"
      "down" -> do
        Ref.write false desiredUp
        bringDown
        -- forget launch memory so stopped services read Down, not Failed
        Ref.write emptySupState supRef
        pure "down: desired=down, auto-restart suspended"
      "restart" -> do
        now <- nowMs
        obs <- observeSupSnapshot dep
        prev <- Ref.read supRef
        let
          refined = refine cfg now prev obs
          forced = Map.insert (mkServiceId arg) Failed refined.snapshot
        Ref.write refined.state supRef
        enactPlan ("restart " <> arg) now forced
        pure ("restart: " <> arg)
      _ -> pure ("unknown control verb: " <> verb)
  log "supervise: initial bring-up…"
  bringUp
  pure ({ statusPort: fromMaybe defaultStatusPort mPort, intervalMs, tick, stateBody, control } :: Resident)

-- | `/state` JSON. The `services` map (id → status string) is UNCHANGED — the
-- | Chair's existing decoder keeps working. Everything else is ADDITIVE (ADR
-- | D-S1, "never break the existing decode"): a top-level `supervised: true`
-- | marks this as a supervise daemon, and a parallel `supervision` map carries
-- | the per-service badge data (`restarts`, `lastTransitionAt`, plus `fails` /
-- | `suspendedUntil` diagnostics) the Chair renders as `↻ N` and "Xs ago". An
-- | older decoder simply ignores the two new keys.
snapshotBody :: Boolean -> SupState -> String
snapshotBody up st =
  "{ \"desired\": \"" <> (if up then "up" else "down") <> "\""
    <> ", \"supervised\": true"
    <> ", \"services\": { " <> intercalate ", " (map svcEntry entries) <> " }"
    <> ", \"supervision\": { " <> intercalate ", " (map supEntry entries) <> " }"
    <> " }"
  where
  entries = Map.toUnfoldable st :: Array (Tuple ServiceId SvcState)

  svcEntry (Tuple sid s) =
    "\"" <> unServiceId sid <> "\": \"" <> statusToken s.status <> "\""

  supEntry (Tuple sid s) =
    "\"" <> unServiceId sid <> "\": { "
      <> "\"restarts\": " <> show s.restarts
      <> ", \"fails\": " <> show s.fails
      <> ", \"lastTransitionAt\": " <> show s.since
      <> ", \"suspendedUntil\": " <> maybe "null" show s.suspendedUntil
      <> " }"

statusToken :: Status -> String
statusToken = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"
