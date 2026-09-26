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
import Bosun.CLI.Observe (observeHolding, observeHoldings, observeSupSnapshot)
import Bosun.Holding (Holding(..), describeHolder, holdingJson, readReap, reapScript, reapSettled, reapTag, strangers)
import Bosun.CLI.Resident (Resident, accepted, nowMs, refused, runResident)
import Bosun.CLI.Supervise.Machine (complaints, desiredFromPhase, evDone, evDown, evRejected, evReload, evReloaded, evRestart, evTick, evUp, phaseTag)
import Bosun.Machine.SuperviseGroup as SG
import Bosun.Machine.SuperviseGroupSource (artifactJson)
import Glassbox.Drive (Wiring, fire, start) as Drive
import Glassbox.Host (dispatch)
import Glassbox.Codec.JSON (parseSpec)
import Glassbox.Run (setConfig, setFact, worldFrom)
import Glassbox.Spec (CommandId, ConfigId(..), EventId, FactId(..), RefusalId, Spec, StateId, Value(..), textOfRefusal)
import Bosun.Plan (Change(..), Plan, Status(..), plan, planSteps)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderAddressMiss, renderCommand, renderReport, renderTeardown, renderTeardownSummary)
import Bosun.Serve (controlPort)
import Bosun.Service (Deployment, LooseService, ValidatedDeployment, deploymentServices, unServiceRef, unValidatedDeployment)
import Bosun.Substrate (TeardownVerdict, leaseEveryMs, pidLease, readTeardown, teardownSettled, teardownTag)
import Bosun.Supervisor (Launch, Policies, SuperviseDiff, SupConfig, SupState, SvcState, addressService, cfgFor, clearFails, defaultConfig, emptySupState, forgetLaunches, policies, recordLaunches, refine, superviseDiff)
import Bosun.Target (TargetMap)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Array as A
import Data.Either (Either(..), isRight)
import Data.Foldable (foldr, intercalate, traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst)
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
    Right vd -> case loadMachine of
      Left why -> do
        log ("cannot supervise: " <> why)
        log ""
        log "The group lifecycle is `machines/supervise-group.json`, compiled in via"
        log "`Bosun.Machine.SuperviseGroupSource`. Regenerate both generated modules"
        log "after editing it: `scripts/machine-vocabulary.sh`."
      Right machine ->
        superviseResident targets mPort startHeld (Just (reIngest composePath registryPath)) machine dep vd
          >>= runResident

-- | The group lifecycle artifact, decoded and checked against what this daemon
-- | can actually do.
-- |
-- | Two failures, and they are different in kind. The decode failing means the
-- | artifact is not a machine. `complaints` failing means it IS one, and names
-- | words this daemon has no answer for — a state it cannot report, a command
-- | it cannot carry out. Both stop the daemon before it starts, which is the
-- | whole argument: a supervisor that silently drops one of its own commands is
-- | worse than one that refuses to boot, because you find out at 3am instead of
-- | at deploy time.
loadMachine :: Either String Spec
loadMachine = case parseSpec artifactJson of
  Left err -> Left ("the group lifecycle artifact does not decode — " <> err)
  Right machine -> case complaints machine of
    [] -> Right machine
    problems -> Left (intercalate "; " problems)

-- | Build the supervise `Resident` — Refs for desired-state and launch memory,
-- | the observe→refine→plan→enact `tick`, the `/state` renderer, the `/control`
-- | handler — and run the initial bring-up, returning the record for
-- | `runResident`. Extracted from `runSupervise` so the Go-column conformance
-- | harness (`Bosun.Conformance.SuperviseMain`) drives the IDENTICAL keep-alive
-- | logic under backend-go that the node CLI runs — the point of the Menagerie's
-- | dual-runtime parity test (mirrors `Bosun.CLI.Docker.dockerResident`). The
-- | `targets` are threaded (not hardcoded) so a remote-host supervise resolves
-- | the same way `apply` does.
superviseResident :: TargetMap -> Maybe Int -> Boolean -> ReloadSource -> Spec -> Deployment -> ValidatedDeployment -> Effect Resident
superviseResident targets mPort startHeld reloadSource machine dep0 vd0 = do
  -- `startHeld` boots the resident with the group HELD DOWN (desired=down) and
  -- skips the initial bring-up: the daemon is up and answering /state + /control
  -- so the Chair sees an armable supervise group, but nothing is launched until a
  -- `POST /control/up` (the Chair's ▲ up all). This is the first-bring-up-from-the
  -- -Chair path — replacing DeepStar, where the supervisor was resident and you
  -- ran `deepstar up` to raise the rig. Default (false) keeps `supervise`'s
  -- bring-it-up-and-keep-it-up lifecycle for the always-on deployments.
  -- WHERE THE GROUP IS, per `machines/supervise-group.json`. Every transition
  -- below is that artifact's decision; this file only carries them out.
  --
  -- This used to be `desiredUp :: Ref Boolean`, and a Boolean had no room for
  -- the five in-flight states — raising, lowering, restarting, reloading,
  -- adopting — that the artifact forces into existence by making every command
  -- hang off a state. They existed in the code all along, as the inside of a
  -- synchronous control handler; they simply could not be named or shown.
  phaseRef <- Ref.new machine.initial
  -- WHICH service a control verb is about.
  --
  -- A Glassbox command is an opaque identifier and carries no payload, so
  -- `restart-one` learns which service the same way the machine learns whether
  -- that service exists: out of band, from the host. The artifact says WHEN to
  -- restart one; Bosun says WHICH. That split is the format working, not a gap
  -- in it — a machine that knew about ServiceIds would be a machine about
  -- Bosun rather than about supervision.
  pendingArg <- Ref.new ""
  -- What the machine did during the fire that is currently running, so the HTTP
  -- reply can report it. Cleared before each verb.
  outRef <- Ref.new emptyOut
  -- WHOSE process holds the port of the service a `restart` names, read just
  -- before the machine decides (Bosun.Holding). The machine's
  -- `port-held-by-foreigner` fact is this, and `restart-one` acts on it: a
  -- stranger it may claim is stopped first, so the launch that follows binds
  -- the port instead of dying on EADDRINUSE while the old code keeps
  -- answering — the 2026-09-25 `ok` that restarted nothing.
  pendingHolding <- Ref.new (Nothing :: Maybe Holding)
  -- When the pidfile lease was last renewed (Substrate.pidLease). Zero, so the
  -- first observation renews at once — a supervisor restarted onto pidfiles
  -- already two days old must not let them lapse on the third.
  leaseRef <- Ref.new 0.0
  -- The observation the current pass is working from, so `reconcile` enacts
  -- against what was just seen instead of observing the rig twice in one tick.
  observedRef <- Ref.new Map.empty
  -- A reload in flight: `re-ingest` produces it, and `stop-changed`,
  -- `forget-changed-launches` and `swap-spec` each consume part of it.
  pendingReload <- Ref.new Nothing
  -- The threaded `recorded` state (D-7): launch memory across ticks. This is
  -- what makes `supervise` more than a stateless plan-loop — without it a
  -- slow-boot service re-Starts every tick (the relaunch storm).
  supRef <- Ref.new emptySupState
  -- What the LAST teardown of each service actually did.
  --
  -- Remembered rather than re-derived, unlike the adoption claim `b45bb21`
  -- put back on a clock — because "did the stop reach it?" is a fact about
  -- history and no probe can answer it later. What keeps it from going stale
  -- is that a LAUNCH supersedes it: `enactPlan` drops a service's verdict the
  -- moment it relaunches, because the verdict describes a generation that no
  -- longer exists.
  --
  -- It lives beside `supRef` rather than inside it because `down` wipes the
  -- launch memory (so stopped services read Down, not Failed) and a verdict
  -- that vanished with it would be gone exactly when it matters most.
  teardownRef <- Ref.new (Map.empty :: Map.Map ServiceId { verdict :: TeardownVerdict, at :: Number })
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

    -- The group defaults, refined by whatever each service's spec declared.
    -- Resolved from the CURRENT deployment on every use rather than closed over
    -- once, so a `/control/reload` that changes a restart policy takes effect
    -- on the next tick — the same reason `enactPlan` re-reads `vdRef`.
    policiesFor :: Deployment -> Policies
    policiesFor d =
      policies cfg (map (\sv -> Tuple sv.id sv.restart) (deploymentServices d))

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
      dep <- Ref.read depRef
      Ref.modify_ (recordLaunches (policiesFor dep) now (launchesOf p)) supRef
      -- A relaunched service's teardown verdict is about the generation we
      -- just replaced, so keeping it would report a dead fact about a live
      -- process — the staleness this whole branch exists to remove.
      Ref.modify_ (\m -> foldr (Map.delete <<< _.id) m (launchesOf p)) teardownRef

    bringUp = do
      now <- nowMs
      enactPlan "bring-up" now Map.empty

    bringDown = do
      vd <- Ref.read vdRef
      verdicts <- enactStop "teardown" (downScript targets vd)
      rememberTeardown verdicts
      pure verdicts

    rememberTeardown verdicts = do
      now <- nowMs
      Ref.modify_
        (\m -> foldr (\(Tuple sid v) -> Map.insert sid { verdict: v, at: now }) m verdicts)
        teardownRef

    -- Stop just a SUBSET of services (their current, old-spec generation): filter
    -- the full teardown script to the wanted ids. Used by `reload` to bring down
    -- only the removed/changed services, leaving the unchanged ones running.
    stopSubset theVd ids =
      let
        wanted = Set.fromFoldable ids :: Set.Set ServiceId
        only = A.filter (\sc -> Set.member sc.service wanted) (downScript targets theVd)
      in
        do
          verdicts <- enactStop "reload-stop" only
          rememberTeardown verdicts
          pure verdicts

    -- Observe and refine, and record BOTH results. This is bookkeeping, not
    -- action: it runs on every tick whatever phase the group is in, because
    -- `/state` must stay current while the group is held. What the observation
    -- is then USED for is the machine's decision, not this function's — which
    -- is exactly the `when up (...)` that used to live at the end of `tick`.
    refreshObserved = do
      dep <- Ref.read depRef
      obs <- observeSupSnapshot dep
      now <- nowMs
      prev <- Ref.read supRef
      let refined = refine (policiesFor dep) now prev obs
      Ref.write refined.state supRef
      Ref.write refined.snapshot observedRef
      renewLease now obs
      pure now

    -- Renew the pidfile lease of every group still alive, so macOS's three-day
    -- `/tmp` sweep never takes the record of a process this group is running.
    renewLease now obs = do
      last <- Ref.read leaseRef
      when (now - last >= leaseEveryMs) do
        let alive = map fst (A.filter (\(Tuple _ o) -> o.groupAlive) (Map.toUnfoldable obs))
        unless (A.null alive) (void (execLine (pidLease alive)))
        Ref.write now leaseRef

    -- Refresh only when nothing is about to. `reconcile` observes for itself —
    -- its own label says so — so a raised tick that refreshed here as well
    -- would probe every service twice a second for nothing. A held group has no
    -- reconcile, and `/state` must still be current, so it refreshes here.
    tick = do
      phase <- Ref.read phaseRef
      when (not (desiredFromPhase phase)) (void refreshObserved)
      Drive.fire wiring evTick

    stateBody = do
      st <- Ref.read supRef
      phase <- Ref.read phaseRef
      td <- Ref.read teardownRef
      dep <- Ref.read depRef
      holders <- observeHoldings targets (deploymentServices dep)
      pure (snapshotBody (policiesFor dep) phase st td holders)

    -- =====================================================================
    -- The seam: what the artifact's words mean here
    -- =====================================================================

    note msg = when (msg /= "") (Ref.modify_ (\o -> o { notes = A.snoc o.notes msg }) outRef)

    -- A command that ran and did not do what the verb promised. The reply is
    -- `ok:false` with this sentence: the machine accepted the verb, the world
    -- did not comply, and an `ok` would be the lie.
    fail msg = Ref.modify_ (_ { failure = Just msg }) outRef

    -- The world the guards read.
    --
    -- Both entries are facts about the HOST, which is the point of the split:
    -- `reload-source` is config because it decides which machine this resident
    -- is (a resident with no spec to re-read genuinely has no reload arc), and
    -- `service-in-group` is a fact because it changes under the machine's feet
    -- as services come and go.
    machineWorld = do
      arg <- Ref.read pendingArg
      observed <- Ref.read observedRef
      holding <- Ref.read pendingHolding
      pure
        ( worldFrom machine
            # setConfig (ConfigId "reload-source") (VBoolean (isJust reloadSource))
            # setFact (FactId "service-in-group")
                (VBoolean (isRight (addressService (Set.toUnfoldable (Map.keys observed)) arg)))
            # setFact (FactId "port-held-by-foreigner") (VBoolean (heldByForeigner holding))
        )

    -- One reconcile against a FRESH observation.
    --
    -- It must observe for itself, and this is where the first attempt at this
    -- wiring got it wrong. `reconcile` is `raised`'s entry command, so it runs
    -- on the way in from `raising` — moments after `bring-up` launched
    -- everything against `Map.empty`. Reusing the observation of the pass would
    -- have meant reconciling against that same empty snapshot, concluding
    -- nothing was running, and launching the whole group A SECOND TIME. The
    -- duplicate generation is the one teardown does not know about, so `down`
    -- then reported every service reaped while two of them kept their ports.
    reconcileNow = do
      now <- refreshObserved
      observed <- Ref.read observedRef
      enactPlan "reconcile (keep-alive)" now observed

    restartOne = do
      now <- nowMs
      arg <- Ref.read pendingArg
      observed <- Ref.read observedRef
      case addressService (Set.toUnfoldable (Map.keys observed)) arg of
        -- Unreachable: the machine only enters `restarting` when the
        -- `service-in-group` fact holds, and that fact is this same lookup.
        Left _ -> note ("restart: " <> arg <> " vanished between the guard and the act")
        Right sid -> do
          -- Give the service its retry BUDGET back before relaunching it. The
          -- forced `Failed` below means the launch itself would happen either
          -- way; what would not is any attempt after it. A service parked by
          -- its cap has `fails` over the line, so one manual launch that did
          -- not take would park it again immediately, and the operator who
          -- just fixed the cause would get a single silent try. Pressing
          -- restart asserts the cause is fixed, and `fails` is exactly the
          -- accumulated belief that it is not.
          Ref.modify_ (clearFails [ sid ]) supRef
          holding <- Ref.read pendingHolding
          -- A claimable stranger is stopped BEFORE the launch, because the
          -- launch cannot do it: its reap reads the pgid this group recorded,
          -- and the stranger is not in it. If it will not go, nothing is
          -- launched and the answer says so — a relaunch into a held port is
          -- the silent success this exists to end.
          cleared <- case holding of
            Just (Stranger st) | st.claimable -> do
              res <- execLine (reapScript st.holders)
              pure (readReap res.message st.holders)
            _ -> pure []
          if A.all (\(Tuple _ v) -> reapSettled v) cleared then do
            enactPlan ("restart " <> arg) now (Map.insert sid Failed observed)
            note ("restart: " <> arg <> restartDetail holding)
          else
            fail
              ( "nothing restarted: could not stop what holds its port — "
                  <> intercalate "; " (map (\(Tuple h v) -> describeHolder h <> ": " <> reapTag v) cleared)
              )

    changedIds p = p.diff.removed <> p.diff.changed

    -- Every command the artifact declares, and nothing else. The row comes from
    -- the generated vocabulary, so a command added to the machine is a MISSING
    -- FIELD here — named, at compile time — rather than a verb that silently
    -- does nothing.
    commandTable :: Record (SG.Commands (Effect (Maybe EventId)))
    commandTable =
      { "bring-up": do
          bringUp
          pure (Just evDone)
      , "reconcile": do
          reconcileNow
          pure Nothing
      , "tear-down": do
          verdicts <- bringDown
          note (renderTeardownSummary verdicts)
          pure Nothing
      , "forget-launch-memory": do
          Ref.write emptySupState supRef
          pure (Just evDone)
      , "restart-one": do
          restartOne
          pure (Just evDone)
      , "re-ingest": case reloadSource of
          -- Unreachable while `reload-source` config gates the arc.
          Nothing -> do
            note "reload: no reload source configured for this resident"
            pure (Just evRejected)
          Just reload -> do
            res <- reload
            case res of
              Left err -> do
                note ("reload: rejected — " <> err)
                pure (Just evRejected)
              Right (Tuple dep' vd') -> do
                oldVd <- Ref.read vdRef
                let
                  d = superviseDiff
                    (unValidatedDeployment oldVd).services
                    (unValidatedDeployment vd').services
                Ref.write (Just { dep: dep', vd: vd', diff: d }) pendingReload
                pure (Just evReloaded)
      , "stop-changed": do
          mp <- Ref.read pendingReload
          case mp of
            Nothing -> pure Nothing
            Just p -> do
              oldVd <- Ref.read vdRef
              verdicts <- stopSubset oldVd (changedIds p)
              note (stopNote verdicts)
              pure Nothing
      , "forget-changed-launches": do
          mp <- Ref.read pendingReload
          case mp of
            Nothing -> pure Nothing
            Just p -> do
              Ref.modify_ (forgetLaunches (changedIds p)) supRef
              pure Nothing
      , "swap-spec": do
          mp <- Ref.read pendingReload
          case mp of
            Nothing -> pure (Just evDone)
            Just p -> do
              Ref.write p.dep depRef
              Ref.write p.vd vdRef
              Ref.write Nothing pendingReload
              note ("reload: " <> reloadSummary p.diff)
              pure (Just evDone)
      }

    wiring :: Drive.Wiring Effect
    wiring =
      { spec: machine
      , phase: Ref.read phaseRef
      , move: \next -> Ref.write next phaseRef
      , world: machineWorld
      , perform: \cmd -> case dispatch commandTable cmd of
          Just run -> run
          -- Unreachable in a daemon that started: `complaints` compares the
          -- artifact's command list with this table's row at boot and refuses
          -- to run if anything is missing.
          Nothing -> do
            log ("supervise: BUG — the artifact names a command this daemon has no handler for: " <> showCommand cmd)
            pure Nothing
      , refused: \rid -> Ref.modify_ (_ { refusal = Just rid }) outRef
      -- Synchronous, because this daemon is. Every command runs to completion
      -- inside the control handler that provoked it, exactly as before, so the
      -- transient states are passed THROUGH rather than rested in — `up` walks
      -- held → raising → raised in one call. The `busy` refusals the artifact
      -- declares are therefore unreachable today, and are the arc that becomes
      -- live the moment any of this is made asynchronous.
      , fork: \act -> act
      -- No deadlines in this machine: the tick is a heartbeat the host owns,
      -- and backoff belongs to the per-service classifier, not here.
      , arm: \_ -> pure unit
      }

    -- Fire one verb and say what came of it.
    fireVerb label ev = do
      Ref.write emptyOut outRef
      Drive.fire wiring ev
      out <- Ref.read outRef
      phase <- Ref.read phaseRef
      let extra = A.filter (_ /= "") out.notes
      holding <- Ref.read pendingHolding
      case out.refusal, out.failure of
        Just rid, _ -> refused (label <> ": " <> textOfRefusal machine rid <> refusalDetail holding)
        Nothing, Just msg -> refused (label <> ": " <> msg)
        Nothing, Nothing -> accepted
          ( label <> ": " <> phaseTag phase
              <> (if A.null extra then "" else " — " <> intercalate " " extra)
          )

    -- Every verb is now the same three steps: tell the host what the verb is
    -- about, ask the ARTIFACT what that means here, and report what came of it.
    --
    -- What used to be in each arm — "is the group up?", "does that service
    -- exist?", "is there a reload source?" — is not gone; it moved into
    -- `machines/supervise-group.json`, where it is one table that can be read,
    -- drawn and checked for holes. Three cells that were never written down
    -- came back with it: `restart` and `reload` are refused while held, which
    -- they were not before, so `POST /control/restart` on a `--held` group no
    -- longer quietly launches the service the hold exists to keep down.
    control = mkEffectFn2 \verb arg -> case verb of
      "up" -> fireVerb "up" evUp
      "down" -> fireVerb "down" evDown
      "restart" -> do
        -- Refresh first: the `service-in-group` guard the machine is about to
        -- read is a question about what is running NOW, and answering it from
        -- a snapshot taken up to a tick ago is how a live service reads as
        -- absent. The old handler refreshed here for the same reason.
        _ <- refreshObserved
        Ref.write arg pendingArg
        observed <- Ref.read observedRef
        -- The machine decides THAT a name it does not know is refused; Bosun
        -- still says WHICH mistake it was. `serve` keys by port and a group
        -- keys by id, so `?service=3028` must not answer "no such service"
        -- about a daemon that is up and lazy-spawned by the router.
        case addressService (Set.toUnfoldable (Map.keys observed)) arg of
          Left miss -> do
            Ref.write emptyOut outRef
            Drive.fire wiring evRestart
            out <- Ref.read outRef
            case out.refusal of
              Just _ -> refused (renderAddressMiss { verb: "restart", asked: arg, routerPort: controlPort } miss)
              Nothing -> accepted ("restart: " <> arg)
          Right sid -> do
            dep <- Ref.read depRef
            holding <- case A.find (\sv -> sv.id == sid) (deploymentServices dep) of
              Just sv -> Just <$> observeHolding targets sv
              Nothing -> pure Nothing
            Ref.write holding pendingHolding
            result <- fireVerb "restart" evRestart
            Ref.write Nothing pendingHolding
            pure result
      "reload" -> fireVerb "reload" evReload
      _ -> refused ("unknown control verb: " <> verb)
  -- Enter the artifact's initial state. It is `held` and has no entry commands,
  -- so this launches nothing — the bring-up below is a `up` event like any
  -- other, which is the point: there is one way into `raised` and the boot path
  -- is not a second one.
  Drive.start wiring
  if startHeld then
    log "supervise: resident, held down (desired=down) — no initial bring-up; raise from the Chair (▲ up all)"
  else do
    log "supervise: initial bring-up…"
    Drive.fire wiring evUp
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
-- | `teardown` is ADDITIVE and omitted entirely when empty, so every existing
-- | decoder — the Chair's included — goes on working untouched (ADR D-S1,
-- | "never break the existing decode").
-- |
-- | It is a TOP-LEVEL object rather than a field of `supervision`, and that is
-- | the whole reason it survives to be read: `down` writes `emptySupState`, so
-- | `services` and `supervision` are empty until the next tick repopulates them
-- | from observation. A verdict parked inside them would be wiped by the very
-- | operation that produced it.
-- | `/state`, with `phase` added beside `desired` rather than replacing it.
-- |
-- | `desired` is DERIVED from the phase rather than stored next to it, because
-- | a stored copy is a second description that can disagree — which is the
-- | complaint the artifact answers. Keeping the field at all is deliberate: the
-- | Chair on :3020 reads it, and an additive `/state` means the running Chair
-- | keeps working untouched while it learns about phases at its own pace.
snapshotBody :: Policies -> StateId -> SupState -> Map.Map ServiceId { verdict :: TeardownVerdict, at :: Number } -> Map.Map ServiceId Holding -> String
snapshotBody ps phase st td holders =
  "{ \"desired\": \"" <> (if desiredFromPhase phase then "up" else "down") <> "\""
    <> ", \"phase\": \"" <> phaseTag phase <> "\""
    <> ", \"supervised\": true"
    <> ", \"services\": { " <> intercalate ", " (map svcEntry entries) <> " }"
    <> ", \"supervision\": { " <> intercalate ", " (map supEntry entries) <> " }"
    <> teardownField
    <> holdersField
    <> " }"
  where
  -- WHOSE process each status is about (Bosun.Holding). Additive, like
  -- `teardown`: `services` keeps its words for every existing decoder, and a
  -- stranger answering on a service's port no longer reads exactly like a
  -- process this group owns. Services with no TCP port are left out.
  holdersField =
    let hs = A.filter (\(Tuple _ h) -> holdingTagIsPorted h) (Map.toUnfoldable holders :: Array (Tuple ServiceId Holding))
    in
      if A.null hs then ""
      else ", \"holders\": { " <> intercalate ", " (map (\(Tuple sid h) -> "\"" <> unServiceId sid <> "\": " <> holdingJson h) hs) <> " }"
  holdingTagIsPorted = case _ of
    NoPort -> false
    _ -> true

  entries = Map.toUnfoldable st :: Array (Tuple ServiceId SvcState)

  teardownEntries = Map.toUnfoldable td :: Array (Tuple ServiceId { verdict :: TeardownVerdict, at :: Number })

  teardownField =
    if A.null teardownEntries then ""
    else ", \"teardown\": { " <> intercalate ", " (map teardownEntry teardownEntries) <> " }"

  -- `settled` is carried rather than left to the reader to derive from the tag.
  -- A consumer that has to know which of six tokens mean "it stopped" will get
  -- it wrong the first time a seventh is added, and the core already knows.
  teardownEntry (Tuple sid v) =
    "\"" <> unServiceId sid <> "\": { "
      <> "\"verdict\": \"" <> teardownTag v.verdict <> "\""
      <> ", \"settled\": " <> (if teardownSettled v.verdict then "true" else "false")
      <> ", \"at\": " <> show v.at
      <> " }"

  svcEntry (Tuple sid s) =
    "\"" <> unServiceId sid <> "\": \"" <> statusToken s.status <> "\""

  supEntry (Tuple sid s) =
    "\"" <> unServiceId sid <> "\": { "
      <> "\"restarts\": " <> show s.restarts
      <> ", \"fails\": " <> show s.fails
      <> ", \"lastTransitionAt\": " <> show s.since
      <> ", \"suspendedUntil\": " <> maybe "null" show s.suspendedUntil
      <> ", \"retryCap\": " <> maybe "null" show (cfgFor ps sid).maxRetries
      <> ", \"gaveUp\": " <> (if gaveUp sid s then "true" else "false")
      <> " }"

  -- `in-backoff` covers two states a reader must not confuse: throttled (it
  -- will come back on its own, wait) and PARKED (it has spent its retry cap and
  -- nothing further will happen without you). Both NoOp the planner, so the
  -- status token alone cannot tell them apart, and a rig where the ES-9 daemon
  -- has quietly given up looks identical to one where it is a second from
  -- returning. Additive, so every existing decoder ignores it.
  gaveUp sid s = case (cfgFor ps sid).maxRetries of
    Just m -> s.fails >= m
    Nothing -> false

statusToken :: Status -> String
statusToken = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"

-- | What one `fire` did, gathered as it went.
-- |
-- | A refusal and a set of notes, rather than a Boolean and a message: the
-- | commands that run during a transition each have something to say — a
-- | teardown summary, a reload diff — and the reply is the sum of them.
type MachineOut = { refusal :: Maybe RefusalId, notes :: Array String, failure :: Maybe String }

emptyOut :: MachineOut
emptyOut = { refusal: Nothing, notes: [], failure: Nothing }

-- | The machine's `port-held-by-foreigner` fact: a stranger holds the port and
-- | is not one this group may claim.
heldByForeigner :: Maybe Holding -> Boolean
heldByForeigner = case _ of
  Just (Stranger st) -> not st.claimable
  _ -> false

-- | Who was on the port, for a refusal that has to name what it did not touch.
refusalDetail :: Maybe Holding -> String
refusalDetail = case _ of
  Just h@(Stranger _) -> " — " <> intercalate "; " (map describeHolder (strangers h))
  _ -> ""

-- | What a restart that went ahead replaced, said so the answer is about the
-- | process and not only the request. Criterion 1 of the findings: never a bare
-- | `ok` over a process that was not replaced.
restartDetail :: Maybe Holding -> String
restartDetail = case _ of
  Just (Ours hs) -> " — replaced " <> intercalate ", " (map describeHolder hs)
  Just h@(Stranger st) ->
    " — replaced " <> intercalate ", " (map describeHolder (strangers h))
      <> ", which this group had not started"
      <> (if A.null st.ours then "" else "; and its own " <> intercalate ", " (map describeHolder st.ours))
  Just Unheld -> " — nothing was listening on its port"
  Just (Unobservable why) -> " — whose process was replaced is not known: " <> why
  _ -> ""

showCommand :: CommandId -> String
showCommand = show
