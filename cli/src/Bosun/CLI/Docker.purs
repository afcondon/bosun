-- | `bosun docker <compose> <registry>` — the resident Docker-on-Node executor
-- | (docs/EXECUTORS.md, the first **mode-2** substrate: Bosun observes, a foreign
-- | supervisor owns keep-alive). Sibling of `bosun supervise`, behind the SAME
-- | `/state` + `/control` HTTP contract — so the Chair lights up a container
-- | group (the MacMini deploy) with zero Chair change.
-- |
-- | The mode-2 distinction is concrete in the tick:
-- |
-- |   · `supervise` (process) — Bosun owns keep-alive, so its tick OBSERVES AND
-- |     ENACTS (restart what crashed).
-- |   · `docker` — Docker owns keep-alive (container `restart:` policy), so this
-- |     tick ONLY OBSERVES (`ssh docker compose ps`), caching the snapshot for
-- |     `/state`. It never relaunches; `control up/down/restart` are the only
-- |     mutations, and they are *deploy/teardown* verbs relayed to docker.
-- |
-- | All the command generation is the EXISTING pure tier: `control` reuses
-- | `applyScript`/`downScript` exactly as `bosun apply`/`down` do (ssh-wrapped
-- | `docker compose up -d / stop / restart`, plus the `tailscale funnel` publish
-- | step for a Published edge) — so the conformance-pinned command script and the
-- | resident control surface share one code path. The only new effect is the
-- | read-only `docker compose ps` observe (`execLine` + the pure
-- | `Bosun.Adapters.DockerPs` parse).
module Bosun.CLI.Docker (runDocker, dockerResident) where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.DockerPs (ContainerObs, healthVerdictToken, parseDockerInspect)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Apply (Command(..), applyScript, downScript)
import Bosun.Atoms (Host, ServiceId, mkServiceId, unAbsPath, unServiceId)
import Bosun.CLI.Exec (execLine)
import Bosun.CLI.IO (readJsonFile, readYamlFile)
import Bosun.CLI.Resident (Resident, accepted, refused, runResident)
import Bosun.Executor (ExecutorMechanism(..), mechanism)
import Bosun.Plan (Status(..), plan)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderCommand, renderReport)
import Bosun.Service (ValidatedDeployment, unValidatedDeployment)
import Bosun.Target (ExecLoc(..), Target, TargetMap, resolveTarget, unSshDest)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldMap, intercalate, traverse_)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Uncurried (mkEffectFn2)

-- | Docker's resident default port (supervise is 3996); override with `--port`
-- | to run one per group.
defaultStatusPort :: Int
defaultStatusPort = 3997

-- | Slightly slower than supervise's 3s: each tick is an ssh round-trip to the
-- | host, and Docker — not Bosun — is doing the per-container keep-alive between
-- | observations, so there is nothing time-critical to catch.
intervalMs :: Int
intervalMs = 5000

-- | `bosun docker [--port N] <compose> <registry>`.
runDocker :: TargetMap -> Maybe Int -> String -> String -> Effect Unit
runDocker targets mPort composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
    dep = r.deployment
  log ("bosun " <> version <> " — docker " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate dep) of
    Left vErrors -> do
      log "cannot drive docker: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> dockerResident targets mPort vd >>= runResident

-- | Build the resident Docker substrate from a validated deployment, do the
-- | initial read-only observe, and return the `Resident` for `runResident` to
-- | mount. Factored out of `runDocker` so the I/O-free conformance harness
-- | (`Bosun.Conformance.DockerMain`) can build it from a pure-constructed
-- | deployment — exercising the execLine + residentImpl foreigns on the Go
-- | column without dragging in the yaml/json/argv read foreigns.
dockerResident :: TargetMap -> Maybe Int -> ValidatedDeployment -> Effect Resident
dockerResident targets mPort vd = do
      -- The cached observation the resident `/state` serves; the tick refreshes
      -- it. `desired` is display-only ("observing" until a control verb sets the
      -- group's intent).
      snapRef <- Ref.new (Map.empty :: Map ServiceId ContainerObs)
      desiredRef <- Ref.new "observing"
      let
        names = serviceNames vd                 -- compose name → canonical id
        target = resolveTarget targets (containerHost vd)
        inspectLine = renderCommand (inspectCommand target)

        observe = do
          res <- execLine inspectLine
          Ref.write (if res.ok then parseDockerInspect names res.message else Map.empty) snapRef

        runScript label script =
          when (not (A.null script)) do
            log ("docker: " <> label)
            traverse_ runOne (A.sortWith _.stage script)
          where
          runOne sc = case sc.command of
            Manual note -> log ("  · skip (manual): " <> note)
            command -> do
              let line = renderCommand command
              res <- execLine line
              log ("  " <> (if res.ok then "✓" else "✗") <> " " <> line)

        -- `up`/`down`/`restart` ride the existing pure command tier. `up` plans
        -- against the freshly observed snapshot (so already-running containers
        -- NoOp); `restart` forces ONE service `Failed` and lets the planner's
        -- D-E5 coupled co-restart fall out — identical to supervise's path.
        bringUp = do
          observe
          snap <- Ref.read snapRef
          runScript "up (docker compose up -d)" (applyScript targets vd (plan vd { desired: vd, recorded: Nothing, observed: map _.status snap }))
          observe

        teardown = do
          runScript "down (docker compose stop)" (downScript targets vd)
          observe

        restartOne arg = do
          observe
          snap <- Ref.read snapRef
          let forced = Map.insert (mkServiceId arg) Failed (map _.status snap)
          runScript ("restart " <> arg) (applyScript targets vd (plan vd { desired: vd, recorded: Nothing, observed: forced }))
          observe

        tick = observe       -- mode 2: observe only; Docker owns keep-alive

        stateBody = do
          snap <- Ref.read snapRef
          desired <- Ref.read desiredRef
          pure (snapshotBody desired snap)

        control = mkEffectFn2 \verb arg -> case verb of
          "up" -> do
            Ref.write "up" desiredRef
            bringUp
            accepted "up: deploy (docker compose up -d)"
          "down" -> do
            Ref.write "down" desiredRef
            teardown
            accepted "down: teardown (docker compose stop)"
          "restart" -> do
            snap <- Ref.read snapRef
            -- as in supervise: a name this group does not contain is a refusal,
            -- not a restart that happens to have done nothing
            if not (Map.member (mkServiceId arg) snap) then
              refused ("restart: no service `" <> arg <> "` in this group")
            else do
              restartOne arg
              accepted ("restart: " <> arg)
          _ -> refused ("unknown control verb: " <> verb)
      log "docker: initial observe (read-only)…"
      observe
      pure
        ({ statusPort: fromMaybe defaultStatusPort mPort, intervalMs, tick, stateBody, control } :: Resident)

-- | Compose service name → canonical `ServiceId` (docker's `ps` reports by the
-- | compose service name, which is the launch spec's `localName`).
serviceNames :: ValidatedDeployment -> Map String ServiceId
serviceNames vd =
  Map.fromFoldable
    (map (\svc -> Tuple svc.launch.localName svc.id)
      (A.fromFoldable (Map.values (unValidatedDeployment vd).services)))

-- | The host the container group deploys to — the first `Container` facet's
-- | host (a compose project lives on one host, so one `docker compose ps`
-- | observes all of it). Multi-host container deployments would need one query
-- | per host (future; the homelab core is single-host: macmini).
containerHost :: ValidatedDeployment -> Maybe Host
containerHost vd =
  case A.find (\svc -> mechanism svc.launch.executor == MechContainer) services of
    Just svc -> svc.host
    Nothing -> Nothing
  where
  services = A.fromFoldable (Map.values (unValidatedDeployment vd).services)

-- | The read-only observation command, built through the SAME `Target`/`Command`
-- | machinery `applyScript` uses for its `docker compose up -d` — so the ssh
-- | login, remote workdir (where the compose file lives) and Docker-Desktop PATH
-- | are identical to the enactment path, by construction.
-- |
-- | One `inspect` deeper than `ps`: `docker inspect $(docker compose ps -aq)`
-- | dumps each container's full state — crucially `.State.Health.Log[]`, which
-- | `ps` omits — so the observer can tell a broken healthcheck from an unhealthy
-- | service (see `Bosun.Adapters.DockerPs`). The `$(…)` is expanded on the REMOTE
-- | host (the ssh wrapper single-quotes the line); the `"{{json .}}"` template
-- | uses double quotes, safe inside that single-quoted remote command. An empty
-- | project (`ps -aq` yields nothing) makes `inspect` exit non-zero, which the
-- | observer reads as "no containers" ⇒ every known service seeded `Down`.
inspectCommand :: Target -> Command
inspectCommand target = case target.exec of
  RemoteSsh dest -> Ssh (unSshDest dest) shell
  LocalExec -> shell
  where
  shell = Shell
    { cwd: map unAbsPath target.workdir
    , line: envExports target.envPrefix <> "docker inspect $(docker compose ps -aq) --format \"{{json .}}\""
    }

-- mirrors Bosun.Apply.envExports (kept local to avoid widening Apply's surface
-- for one helper): leading `export K=V && …` so a non-interactive ssh shell has
-- docker on PATH.
envExports :: Array (Tuple String String) -> String
envExports = foldMap \(Tuple k v) -> "export " <> k <> "=" <> v <> " && "

-- | `/state` JSON — the SAME shape `supervise` emits (services map + additive
-- | `supervision`), so the Chair's decoder is unchanged. The differences are
-- | honest and additive: `supervised: false` (Bosun does NOT run the keep-alive
-- | loop here) but `selfHeals: true` with `keepAliveOwner: "docker"` (the `↻`
-- | badge should read the container `restart:` policy, per EXECUTORS.md). Each
-- | `supervision` entry carries docker's `health` verdict; `restarts`/`fails`
-- | are 0 because Bosun isn't the one counting them — Docker is.
snapshotBody :: String -> Map ServiceId ContainerObs -> String
snapshotBody desired snap =
  "{ \"desired\": \"" <> desired <> "\""
    <> ", \"supervised\": false"
    <> ", \"selfHeals\": true"
    <> ", \"keepAliveOwner\": \"docker\""
    <> ", \"services\": { " <> intercalate ", " (map svcEntry entries) <> " }"
    <> ", \"supervision\": { " <> intercalate ", " (map supEntry entries) <> " }"
    <> " }"
  where
  entries = Map.toUnfoldable snap :: Array (Tuple ServiceId ContainerObs)

  svcEntry (Tuple sid obs) =
    "\"" <> unServiceId sid <> "\": \"" <> statusToken obs.status <> "\""

  -- `health` is now docker's own verdict, with `check-error` distinct from
  -- `unhealthy` (the broken-vs-failing distinction `ps` could not make).
  supEntry (Tuple sid obs) =
    "\"" <> unServiceId sid <> "\": { "
      <> "\"restarts\": 0, \"fails\": 0"
      <> ", \"health\": \"" <> healthVerdictToken obs.health <> "\""
      <> ", \"keepAliveOwner\": \"docker\""
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
