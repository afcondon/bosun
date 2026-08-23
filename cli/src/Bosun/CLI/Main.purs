-- | The `bosun` CLI.
-- |
-- |   bosun check <compose.yml> <registry.json>
-- |     ingest both sources → reconcile (facet model) → validate → report,
-- |     over the LIVE files. The cross-source alias map is built automatically
-- |     by matching a registry row's startCommand cwd against a compose
-- |     service's build context — same directory basename ⇒ same logical
-- |     service (so the native and containerised facets group).
-- |
-- |   bosun serve [registry.json]
-- |     with no arg, fetches the LIVE Marginalia registry (/api/ports); with a
-- |     path, reads a registry dump. Either way: the typed lazy-spawn router
-- |     (replacing SDI): ingest → reconcile →
-- |     admission control (servePlan) → bind valid ports → lazy-spawn + reverse-
-- |     proxy on first request, idle-reap. Prints the admission report (what it
-- |     will and won't route, with typed reasons) then stays resident.
-- |
-- |   bosun reload [--port <n>]
-- |     ask a RUNNING `bosun serve` (default :3997) to re-read its registry and
-- |     re-admit — the same `POST /control/reload` the chair-server fires on
-- |     every registry write, for the two cases it can't cover: the router was
-- |     down when the row was written, or the file was edited by hand. Reports
-- |     what it bound and whether the two now agree.
-- |
-- |   bosun where <service|port> [--port <n>]
-- |     ENSURE-AND-LOCATE: make sure a service is running and say where it
-- |     actually is. `mediation: broker` means bosun is NOT in the data path
-- |     and the address returned is the service's own — which is the only
-- |     answer that can work for a unix-socket or UDP daemon. The same
-- |     operation the router exposes at `GET /where`, for callers that are not
-- |     PureScript (DeepStar's pre-flight is the Go one).
-- |
-- |   bosun            (no args) — the built-in §7 fixture demo.
module Bosun.CLI.Main where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Adapters.Targets (ingestTargets)
import Bosun.Apply (Command(..), StagedCommand, applyScript, downScript)
import Bosun.Target (TargetMap, defaultTargets)
import Bosun.Atoms (AbsPath, Port, ServiceId, mkAbsPath, mkHost, mkPort, mkProjectSlug, mkServiceId, unServiceId)
import Bosun.CLI.Exec (execLine)
import Bosun.CLI.IO (argv, readJsonFile, readYamlFile)
import Bosun.CLI.Observe (observeSnapshot)
import Bosun.CLI.Audit (runAudit)
import Bosun.CLI.Serve (runReload, runServe, runServeLive, runServePlan, runWhere)
import Bosun.CLI.Supervise (runSupervise)
import Bosun.CLI.Docker (runDocker)
import Bosun.Edge (Gate(..), Requirement(..))
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Reachability (hostPort, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Plan (Reason(..), Snapshot, Status(..), plan)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderArtifactDrift, renderCommand, renderPlan, renderReport, renderScript, renderTopologyDrift)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Argonaut.Core (Json, toObject, toString)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..), either)
import Data.Foldable (intercalate)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, fromMaybe, maybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Foreign.Object as FO
import Effect (Effect)
import Effect.Console (log)
import Partial.Unsafe (unsafePartial)

main :: Effect Unit
main = do
  rawArgs <- argv
  -- Global options (`--targets <file>`, `--port <n>`) can appear anywhere: pull
  -- them out so the positional `apply`/`plan`/`supervise` forms below match
  -- unchanged. `--targets` layers a file over the built-in target defaults
  -- (consumed by `apply`); `--port` overrides `supervise`'s status port so you
  -- can run one supervisor per group on its own port.
  let
    tf = takeFlag "--targets" rawArgs
    pf = takeFlag "--port" tf.rest
    hf = takeBoolFlag "--held" pf.rest
    args = hf.rest
    supPort = pf.value >>= Int.fromString
    startHeld = hf.present
  targets <- loadTargets tf.value
  case args of
    [ "check", composePath, registryPath ] -> runCheck composePath registryPath
    [ "plan", composePath, registryPath ] -> runPlan composePath registryPath Nothing
    [ "plan", composePath, registryPath, snapshotPath ] -> runPlan composePath registryPath (Just snapshotPath)
    [ "observe", composePath, registryPath ] -> runObserve composePath registryPath
    [ "serve", "--plan" ] -> runServePlan Nothing
    [ "serve", "--plan", registryPath ] -> runServePlan (Just registryPath)
    [ "serve", "--audit" ] -> runAudit Nothing
    [ "serve", "--audit", registryPath ] -> runAudit (Just registryPath)
    [ "serve" ] -> runServeLive
    [ "serve", registryPath ] -> runServe registryPath
    -- `--port` is the same global flag `supervise` uses, so one router per port
    -- is addressable without new flag machinery.
    [ "reload" ] -> runReload supPort
    [ "where", key ] -> runWhere supPort key
    [ "apply", "--dry-run", composePath, registryPath ] -> runApplyDryRun targets composePath registryPath Nothing
    [ "apply", "--dry-run", composePath, registryPath, snapshotPath ] -> runApplyDryRun targets composePath registryPath (Just snapshotPath)
    [ "apply", composePath, registryPath ] -> runApply targets composePath registryPath Nothing
    [ "apply", composePath, registryPath, snapshotPath ] -> runApply targets composePath registryPath (Just snapshotPath)
    [ "down", "--dry-run", composePath, registryPath ] -> runDownDryRun targets composePath registryPath
    [ "down", composePath, registryPath ] -> runDown targets composePath registryPath
    [ "supervise", composePath, registryPath ] -> runSupervise targets supPort startHeld composePath registryPath
    [ "docker", composePath, registryPath ] -> runDocker targets supPort composePath registryPath
    _ -> runDemo

-- | Pull an optional `<name> <value>` flag out of the argument vector wherever
-- | it appears, returning the value and the remaining args (so the positional
-- | command forms match unchanged).
takeFlag :: String -> Array String -> { value :: Maybe String, rest :: Array String }
takeFlag name args = case A.findIndex (_ == name) args of
  Just i
    | Just v <- A.index args (i + 1) ->
        { value: Just v
        , rest: fromMaybe args (A.deleteAt i args >>= A.deleteAt i)
        }
  _ -> { value: Nothing, rest: args }

-- | Pull an optional valueless boolean flag (e.g. `--held`) out of the argument
-- | vector wherever it appears, reporting whether it was present and returning
-- | the remaining args so the positional command forms match unchanged.
takeBoolFlag :: String -> Array String -> { present :: Boolean, rest :: Array String }
takeBoolFlag name args = case A.findIndex (_ == name) args of
  Just i -> { present: true, rest: fromMaybe args (A.deleteAt i args) }
  Nothing -> { present: false, rest: args }

-- | The built-in `defaultTargets`, with a `targets.json` layered on top (file
-- | entries win per host — `Map.union` is left-biased).
loadTargets :: Maybe String -> Effect TargetMap
loadTargets = case _ of
  Nothing -> pure defaultTargets
  Just path -> do
    j <- readJsonFile path
    pure (Map.union (ingestTargets j) defaultTargets)

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
  -- artifact drift is independent of validation (a valid deployment can still
  -- run different content per substrate), so it's surfaced separately here.
  when (not (A.null r.artifactDrift)) do
    log ""
    log (renderArtifactDrift r.artifactDrift)
  -- the per-host edge check is likewise independent of validation: a valid
  -- deployment can still drop the edge on one of its hosts (links 404 there).
  when (not (A.null r.topologyDrift)) do
    log ""
    log (renderTopologyDrift r.topologyDrift)

-- ── bosun plan <compose> <registry> [snapshot.json] ─────────────────────────
-- |
-- | Reconcile + validate, then diff the validated deployment against an
-- | observed `Snapshot`. The snapshot is a JSON object `{ "<serviceId>":
-- | "<status>" }` (`running`/`starting`/`in-backoff`/`failed`/`down`/
-- | `completed-ok`); any service absent from it — or the whole file absent — is
-- | treated as `down`, so the bare `bosun plan` answers "bring the rig up from
-- | nothing." This reads a snapshot *file*; the live observation edge
-- | (`observe :: Probe -> Effect Status`) is the next step (Phase 6). A
-- | deployment that fails validation cannot be planned — we print the check
-- | report instead, since `plan` is total only past `validate`.
runPlan :: String -> String -> Maybe String -> Effect Unit
runPlan composePath registryPath snapshotPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  observed <- maybe (pure Map.empty) (map decodeSnapshot <<< readJsonFile) snapshotPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  log ("bosun " <> version <> " — plan " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate r.deployment) of
    Left vErrors -> do
      log "cannot plan: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd ->
      log (renderPlan (plan vd { desired: vd, recorded: Nothing, observed }))

-- ── bosun apply --dry-run <compose> <registry> [snapshot.json] ───────────────
-- |
-- | Print the command script `apply` WOULD run — the pure `Plan -> Array
-- | StagedCommand` rendered as a shell script (docker/ssh lines; un-automatable
-- | steps as `# MANUAL:` comments). No mutation. Like `plan`, it refuses a
-- | deployment that does not validate. Live execution (os-exec) is a deliberate
-- | next step, to be run with the user present.
runApplyDryRun :: TargetMap -> String -> String -> Maybe String -> Effect Unit
runApplyDryRun targets composePath registryPath snapshotPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  observed <- maybe (pure Map.empty) (map decodeSnapshot <<< readJsonFile) snapshotPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  log ("bosun " <> version <> " — apply --dry-run " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate r.deployment) of
    Left vErrors -> do
      log "cannot apply: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd ->
      log (renderScript (applyScript targets vd (plan vd { desired: vd, recorded: Nothing, observed })))

-- ── bosun apply <compose> <registry> [snapshot.json] ────────────────────────
-- |
-- | The real thing: reconcile → validate → plan → run the command script via
-- | os-exec, stage by stage, IN BOOT ORDER. Within a stage commands run
-- | sequentially (concurrency is a later, Go-owned tier); a failed command
-- | aborts the run before its dependents start. `# MANUAL:` steps are reported
-- | and skipped. Refuses a deployment that does not validate.
runApply :: TargetMap -> String -> String -> Maybe String -> Effect Unit
runApply targets composePath registryPath snapshotPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  observed <- maybe (pure Map.empty) (map decodeSnapshot <<< readJsonFile) snapshotPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  log ("bosun " <> version <> " — apply " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate r.deployment) of
    Left vErrors -> do
      log "cannot apply: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> do
      let
        script = applyScript targets vd (plan vd { desired: vd, recorded: Nothing, observed })
        stages = A.groupBy (\a b -> a.stage == b.stage) script
      if A.null stages then log "apply: nothing to do — the rig already matches desired state."
      else runStages 1 (map NEA.toArray stages)

-- ── bosun down [--dry-run] <compose> <registry> ────────────────────────────
-- |
-- | Teardown: stop every service in REVERSE boot order (`downScript`). For a
-- | `Container` group (the macmini deploy) this is `docker compose stop`,
-- | ssh-wrapped — the apply↔down symmetry. An unmanaged local `Process` stop is
-- | still an honest `# MANUAL` note (task #8); it is reported and skipped, never
-- | a port-kill heuristic. Refuses a deployment that does not validate.
runDownDryRun :: TargetMap -> String -> String -> Effect Unit
runDownDryRun targets composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  log ("bosun " <> version <> " — down --dry-run " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate r.deployment) of
    Left vErrors -> do
      log "cannot down: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> log (renderScript (downScript targets vd))

runDown :: TargetMap -> String -> String -> Effect Unit
runDown targets composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  log ("bosun " <> version <> " — down " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate r.deployment) of
    Left vErrors -> do
      log "cannot down: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> do
      let
        script = downScript targets vd
        stages = A.groupBy (\a b -> a.stage == b.stage) script
      if A.null stages then log "down: nothing to do — no services to stop."
      else runStages 1 (map NEA.toArray stages)

runStages :: Int -> Array (Array StagedCommand) -> Effect Unit
runStages n stages = case A.uncons stages of
  Nothing -> log "\napply: done."
  Just { head: stage, tail: rest } -> do
    log ("stage " <> show n <> ":")
    ok <- runStage stage
    if ok then runStages (n + 1) rest
    else log "\napply: ABORTED — a command failed; dependents were not started."

runStage :: Array StagedCommand -> Effect Boolean
runStage cmds = do
  results <- traverse runOne cmds
  pure (A.all identity results)
  where
  runOne sc = case sc.command of
    Manual note -> do
      log ("  · skip (manual): " <> note)
      pure true
    command -> do
      let line = renderCommand command
      res <- execLine line
      log ("  " <> (if res.ok then "✓" else "✗ (" <> show res.code <> ")") <> " " <> line)
      when (not res.ok && res.message /= "") (log ("      " <> res.message))
      pure res.ok

-- ── bosun observe <compose> <registry> ──────────────────────────────────────
-- |
-- | Probe the live rig (read-only) and print the observed `Snapshot` as JSON on
-- | stdout, in the exact shape `bosun plan … <snapshot.json>` reads back — so
-- | the loop is `bosun observe … > snap.json && bosun plan … snap.json`. Works
-- | off the reconciled (loose) deployment, so it does not require the rig to
-- | validate first.
runObserve :: String -> String -> Effect Unit
runObserve composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  snapshot <- observeSnapshot r.deployment
  log (encodeSnapshot snapshot)

-- | The encode half of the snapshot boundary codec (inverse of `statusOf`):
-- | emits tokens `statusOf` parses, so observe → plan round-trips.
encodeSnapshot :: Snapshot -> String
encodeSnapshot snap =
  "{\n" <> intercalate ",\n" (map entry (Map.toUnfoldable snap :: Array (Tuple ServiceId Status))) <> "\n}"
  where
  entry (Tuple sid st) = "  " <> show (unServiceId sid) <> ": " <> show (statusToken st)

statusToken :: Status -> String
statusToken = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"

-- | Boundary codec (entry-73): observed reality crossing into the pure core.
decodeSnapshot :: Json -> Snapshot
decodeSnapshot json = fromMaybe Map.empty do
  obj <- toObject json
  pure (Map.fromFoldable (map decodeEntry (FO.toUnfoldable obj :: Array (Tuple String Json))))
  where
  decodeEntry (Tuple k v) = Tuple (mkServiceId k) (statusOf (fromMaybe "" (toString v)))

statusOf :: String -> Status
statusOf = case _ of
  "running" -> Running
  "starting" -> Starting
  "in-backoff" -> InBackoff
  "failed" -> Failed
  "down" -> Down
  "completed-ok" -> CompletedOk
  other -> Unknown (ProbeUnreachable other)

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
      , reachability = hostPort (port_ 3013)
      }
  , inst
      { source = FromCompose
      , localName = "tidal-frontend"
      , host = Just (mkHost "macmini")
      , executor = Container (ContainerSpec { source: Left (ImageRef "tidal-frontend"), internalPort: Nothing, publish: Nothing })
      , reachability = noNetwork
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-backend"
      , role = mkRole "api"
      , host = Just (mkHost "mbp")
      , reachability = hostPort (port_ 3000)
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectSlug "minard")
      , localName = "minard-frontend"
      , host = Just (mkHost "mbp")
      , reachability = hostPort (port_ 3001)
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
  , artifact: Nothing
  , reachability: noNetwork
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
