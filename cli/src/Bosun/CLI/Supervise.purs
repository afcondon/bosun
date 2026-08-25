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
import Bosun.Apply (Command(..), StagedCommand, applyScript, downScript)
import Bosun.Atoms (ServiceId, unServiceId)
import Bosun.CLI.Exec (execLine)
import Bosun.CLI.IO (readJsonFile, readYamlFile)
import Bosun.CLI.Observe (observeSupSnapshot)
import Bosun.CLI.Resident (Resident, accepted, nowMs, refused, runResident)
import Bosun.Plan (Change(..), Plan, Status(..), plan, planSteps)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderAddressMiss, renderCommand, renderReport, renderTeardown, renderTeardownSummary)
import Bosun.Serve (controlPort)
import Bosun.Service (Deployment, ValidatedDeployment, unServiceRef, unValidatedDeployment)
import Bosun.Substrate (TeardownVerdict, readTeardown, teardownSettled)
import Bosun.Supervisor (Launch, SuperviseDiff, SupConfig, SupState, SvcState, addressService, defaultConfig, emptySupState, forgetLaunches, recordLaunches, refine, superviseDiff)
import Bosun.Target (TargetMap)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (intercalate, traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.Traversable (traverse)
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

-- | A re-ingest capability for hot-reload: re-read the compose + registry from
-- | disk and reconcile+validate them into a fresh deployment, or a concise
-- | reason the reload was rejected (kept in the message so the operator sees why
-- | the running group was left untouched). `Nothing` ⇒ this resident has no
-- | reload source (the embedded-fixture conformance harness), so `POST
-- | /control/reload` reports that rather than silently no-op'ing.
type ReloadSource = Maybe (Effect (Either String (Tuple Deployment ValidatedDeployment)))

-- | Re-read + reconcile + validate the two spec files, for hot-reload. A parse
-- | or validation failure is a `Left` with a short reason — the resident keeps
-- | the CURRENT deployment running rather than tearing the rig down over a typo.
reIngest :: String -> String -> Effect (Either String (Tuple Deployment ValidatedDeployment))
reIngest composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
    dep = r.deployment
  pure case toEither (validate dep) of
    Left _ -> Left "reloaded spec does not validate — keeping current deployment"
    Right vd -> Right (Tuple dep vd)

-- | `bosun supervise [--port N] <compose> <registry>`. The status port defaults
-- | to 3996; pass `--port` to run one supervisor PER GROUP, each on its own port
-- | (a group = one deployment), so the Chair polls/controls each independently.
runSupervise :: TargetMap -> Maybe Int -> Boolean -> String -> String -> Effect Unit
runSupervise targets mPort startHeld composePath registryPath = do
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
    Right vd ->
      superviseResident targets mPort startHeld (Just (reIngest composePath registryPath)) dep vd
        >>= runResident

-- | Build the supervise `Resident` — Refs for desired-state and launch memory,
-- | the observe→refine→plan→enact `tick`, the `/state` renderer, the `/control`
-- | handler — and run the initial bring-up, returning the record for
-- | `runResident`. Extracted from `runSupervise` so the Go-column conformance
-- | harness (`Bosun.Conformance.SuperviseMain`) drives the IDENTICAL keep-alive
-- | logic under backend-go that the node CLI runs — the point of the Menagerie's
-- | dual-runtime parity test (mirrors `Bosun.CLI.Docker.dockerResident`). The
-- | `targets` are threaded (not hardcoded) so a remote-host supervise resolves
-- | the same way `apply` does.
superviseResident :: TargetMap -> Maybe Int -> Boolean -> ReloadSource -> Deployment -> ValidatedDeployment -> Effect Resident
superviseResident targets mPort startHeld reloadSource dep0 vd0 = do
  -- `startHeld` boots the resident with the group HELD DOWN (desired=down) and
  -- skips the initial bring-up: the daemon is up and answering /state + /control
  -- so the Chair sees an armable supervise group, but nothing is launched until a
  -- `POST /control/up` (the Chair's ▲ up all). This is the first-bring-up-from-the
  -- -Chair path — replacing DeepStar, where the supervisor was resident and you
  -- ran `deepstar up` to raise the rig. Default (false) keeps `supervise`'s
  -- bring-it-up-and-keep-it-up lifecycle for the always-on deployments.
  desiredUp <- Ref.new (not startHeld)
  -- The threaded `recorded` state (D-7): launch memory across ticks. This is
  -- what makes `supervise` more than a stateless plan-loop — without it a
  -- slow-boot service re-Starts every tick (the relaunch storm).
  supRef <- Ref.new emptySupState
  -- The DEPLOYMENT itself is mutable now: a `POST /control/reload` re-reads the
  -- spec and swaps these, so the loop below always plans/observes against the
  -- CURRENT deployment. Before reload this was closed-over-once; the diff-guided
  -- swap in the `reload` verb is what makes it safe (unchanged services keep
  -- their launch memory ⇒ never double-launched).
  depRef <- Ref.new dep0
  vdRef <- Ref.new vd0
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

    -- A TEARDOWN stage, run for its verdict. `runOne`'s `res.ok` cannot serve
    -- here: the stop script exits 0 whatever it finds — deliberately, so one
    -- unstoppable service does not abort the teardown of the rest — which is
    -- precisely why the exit code carries no information and the printed
    -- `TeardownVerdict` does.
    --
    -- Stages the plan did not flag (`docker compose stop`, and anything else
    -- that is not a tracked Process) keep the old ok/✗ reporting: they answer
    -- with an exit code and that is a real signal for them.
    runStop :: StagedCommand -> Effect (Maybe (Tuple ServiceId TeardownVerdict))
    runStop sc = case sc.command of
      Manual note -> do
        log ("  · skip (manual): " <> note)
        pure Nothing
      command -> do
        let line = renderCommand command
        res <- execLine line
        if sc.reportsTeardown then do
          let v = readTeardown { ran: res.ok, output: res.message }
          log ("  " <> (if teardownSettled v then "✓" else "✗") <> " " <> renderTeardown sc.service v)
          pure (Just (Tuple sc.service v))
        else do
          log ("  " <> (if res.ok then "✓" else "✗") <> " " <> line)
          pure Nothing

    enactStop label script =
      if A.null script then pure []
      else do
        log ("supervise: " <> label)
        A.catMaybes <$> traverse runStop (A.sortWith _.stage script)

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
    -- plan → enact → stamp launch memory. Reads the CURRENT deployment from
    -- `vdRef`, so a reload takes effect on the very next enact.
    enactPlan label now observed = do
      vd <- Ref.read vdRef
      let p = plan vd { desired: vd, recorded: Nothing, observed }
      enact label (applyScript targets vd p)
      Ref.modify_ (recordLaunches cfg now (launchesOf p)) supRef

    bringUp = do
      now <- nowMs
      enactPlan "bring-up" now Map.empty

    bringDown = do
      vd <- Ref.read vdRef
      enactStop "teardown" (downScript targets vd)

    -- Stop just a SUBSET of services (their current, old-spec generation): filter
    -- the full teardown script to the wanted ids. Used by `reload` to bring down
    -- only the removed/changed services, leaving the unchanged ones running.
    stopSubset theVd ids =
      let
        wanted = Set.fromFoldable ids :: Set.Set ServiceId
        only = A.filter (\sc -> Set.member sc.service wanted) (downScript targets theVd)
      in
        enactStop "reload-stop" only

    tick = do
      up <- Ref.read desiredUp
      dep <- Ref.read depRef
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
        accepted "up: desired=up, bringing up"
      -- The reply carries what the teardown ACTUALLY DID. It used to read
      -- `{"ok":true,"message":"down: desired=down, auto-restart suspended"}`
      -- unconditionally, which is two true clauses arranged so that the missing
      -- third one ("and nothing was stopped") is the one you infer.
      --
      -- `ok` stays TRUE even when services survive, and that is a deliberate
      -- choice rather than an oversight: the shim answers 400 for `ok:false`,
      -- and 400 says the REQUEST was bad. The request was fine — desired=down
      -- took effect and auto-restart is suspended — it is the rig that did not
      -- comply. Answering "bad request" would send the operator to look at
      -- their curl. So the truth rides the message, and `renderTeardownSummary`
      -- puts the failures at the front of it where they cannot be skimmed past.
      "down" -> do
        Ref.write false desiredUp
        verdicts <- bringDown
        -- forget launch memory so stopped services read Down, not Failed
        Ref.write emptySupState supRef
        accepted ("down: desired=down, auto-restart suspended — " <> renderTeardownSummary verdicts)
      "restart" -> do
        now <- nowMs
        dep <- Ref.read depRef
        obs <- observeSupSnapshot dep
        prev <- Ref.read supRef
        let refined = refine cfg now prev obs
        Ref.write refined.state supRef
        -- A name that is not in the group cannot be restarted, and saying
        -- "restart: <typo>" as though it had been is how a control surface
        -- teaches you to trust it wrongly.
        --
        -- WHICH mistake it was is the part that used to be missing. `serve`
        -- keys by PORT and a group keys by ID, so the natural first move on a
        -- misbehaving daemon — `?service=3028` — answered "no service `3028`
        -- in this group", which is true and reads as "that daemon is down"
        -- about a daemon that is up and lazy-spawned by the router
        -- (FINDINGS-supervision-blind-spots.md §4). The router's half of that
        -- was fixed in bd28adc; `addressService` is this half, and it splits
        -- out the empty argument and the near-miss spellings while it is there.
        case addressService (Set.toUnfoldable (Map.keys refined.snapshot)) arg of
          Left miss -> refused (renderAddressMiss { verb: "restart", asked: arg, routerPort: controlPort } miss)
          Right sid -> do
            enactPlan ("restart " <> arg) now (Map.insert sid Failed refined.snapshot)
            accepted ("restart: " <> arg)
      -- HOT-RELOAD (note #397): re-read the spec, diff it against what is
      -- running, and stop ONLY the services whose launch spec changed (or were
      -- removed) — the unchanged ones keep running with their launch memory, so
      -- a live UDP/socket daemon is never double-launched. The changed/added
      -- services come up on the next keep-alive tick (desired=up). A spec that
      -- fails to parse/validate is rejected and the running group is untouched.
      "reload" -> case reloadSource of
        Nothing -> refused "reload: no reload source configured for this resident"
        Just reload -> do
          res <- reload
          case res of
            Left err -> refused ("reload: rejected — " <> err)
            Right (Tuple dep' vd') -> do
              oldVd <- Ref.read vdRef
              let
                d = superviseDiff
                  (unValidatedDeployment oldVd).services
                  (unValidatedDeployment vd').services
                toStop = d.removed <> d.changed
              -- Stop the CURRENT generation of removed+changed services — render
              -- their Stop commands from the OLD vd (it describes what is running
              -- now), then forget their launch memory so the next tick relaunches
              -- the changed ones with the new spec and leaves the removed dead.
              verdicts <- stopSubset oldVd toStop
              Ref.modify_ (forgetLaunches toStop) supRef
              -- Swap in the new deployment. UNCHANGED services are untouched and
              -- keep their launch memory (the double-launch guard).
              Ref.write dep' depRef
              Ref.write vd' vdRef
              -- A reload's stop half is a teardown like any other, and a
              -- changed service that would not die is the one thing that makes
              -- the relaunch on the next tick lose the bind race. So the same
              -- verdicts ride this reply, appended only when there is bad news
              -- — an unremarkable reload should still read as one line.
              accepted ("reload: " <> reloadSummary d <> stopNote verdicts)
      _ -> refused ("unknown control verb: " <> verb)
  if startHeld then
    log "supervise: resident, held down (desired=down) — no initial bring-up; raise from the Chair (▲ up all)"
  else do
    log "supervise: initial bring-up…"
    bringUp
  pure ({ statusPort: fromMaybe defaultStatusPort mPort, intervalMs, tick, stateBody, control } :: Resident)

-- | The teardown clause a reload reply carries only when something did not
-- | stop. Silent otherwise — a summary that always ends "0 NOT STOPPED" trains
-- | the reader to stop reading the end of the line.
stopNote :: Array (Tuple ServiceId TeardownVerdict) -> String
stopNote verdicts
  | A.any (\(Tuple _ v) -> not (teardownSettled v)) verdicts =
      " — " <> renderTeardownSummary verdicts
  | otherwise = ""

-- | A one-line human summary of what a hot-reload did, for the `/control/reload`
-- | response the Chair surfaces.
reloadSummary :: SuperviseDiff -> String
reloadSummary d =
  show (A.length d.added) <> " added, "
    <> show (A.length d.changed) <> " changed, "
    <> show (A.length d.removed) <> " removed, "
    <> show (A.length d.unchanged) <> " unchanged"

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
