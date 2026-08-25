-- | DESIGN §4/§6 — `applyScript`, the PURE half of the launch tier (Phase 6B).
-- |
-- | `apply` itself is effectful (os-exec), and lives at the CLI edge. But the
-- | *decision* of WHICH commands to run is pure and total: given a
-- | `ValidatedDeployment` (so every `Change` names a real, proven service) and
-- | a `Plan`, `applyScript` produces the ordered list of shell commands that
-- | would realise it. That keeps the effectful shell trivial — it just runs the
-- | strings — and, crucially, makes the command script **conformance-testable**:
-- | the backend-go binary must emit the byte-identical docker/ssh script the
-- | node binary does.
-- |
-- | A `Change` maps to a command via the service's representative-facet
-- | `Executor` (the `LaunchSpec` threaded through `validate`): a `Process` runs
-- | its `cd … && <command>`; a `Container` runs `docker compose … up/restart/
-- | stop`; mechanisms we do not yet drive (CDN, systemd, launchd, remote,
-- | unmanaged) surface as a `Manual` note rather than a silent omission.
-- | Commands for `macmini` services are `ssh`-wrapped (the executing machine is
-- | the mbp).
module Bosun.Apply
  ( Command(..)
  , StagedCommand
  , applyScript
  , downScript
  , commandFor
  ) where

import Prelude

import Bosun.Artifact (Artifact(..), ArtifactRef(..))
import Bosun.Atoms (EnvVar, Port, ServiceId, unAbsPath, unEnvVar, unPort, unServiceId)
import Bosun.Executor (Executor(..))
import Bosun.Plan (Change(..), Plan, changeRef, planSteps)
import Bosun.Reachability (Address(..), addresses)
import Bosun.Service (Service, ValidatedDeployment, unBootOrder, unServiceRef, unValidatedDeployment)
import Bosun.Substrate (composeCmd, daemonize, pidStop, shellQuote)
import Bosun.Target (ExecLoc(..), Target, TargetMap, resolveTarget, unSshDest)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Foldable (foldMap)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

-- | A launch action. `Shell` is a local command (optionally in a cwd); `Ssh`
-- | runs an inner command on a remote login target; `Manual` is a documented
-- | action Bosun does not (yet) automate — never silently dropped.
data Command
  = Shell { cwd :: Maybe String, line :: String }
  | Ssh String Command
  | Manual String
derive instance Eq Command

-- | One command in a script, with the stage it belongs to and the service it
-- | acts on.
-- |
-- | `reportsTeardown` marks the stages whose command answers with a
-- | `TeardownVerdict` the core can read (`Substrate.readTeardown`) — today,
-- | exactly the Process Stops. The exec edge needs to know WHICH stages to read
-- | a verdict from, and it must learn that from the plan rather than by
-- | sniffing the rendered string: a `docker compose stop` prints no token, and
-- | concluding `Unreadable` from its silence would be a false alarm about a
-- | teardown that worked.
type StagedCommand =
  { stage :: Int
  , service :: ServiceId
  , command :: Command
  , reportsTeardown :: Boolean
  }

-- | The ordered command script for a plan. `NoOp`s contribute nothing. The
-- | `TargetMap` resolves each service's host to its enactment profile (ssh
-- | login, remote workdir, env prefix) — so the same pure script renders
-- | local for `mbp` and ssh-wrapped for `macmini`, with no host strings baked
-- | into the planner.
applyScript :: TargetMap -> ValidatedDeployment -> Plan -> Array StagedCommand
applyScript tmap vd p =
  planSteps p # A.concatMap \step ->
    case Map.lookup (unServiceRef (changeRef step.change)) svcs of
      Nothing -> []
      Just svc ->
        -- a step yields the launch command (if any) THEN any publish commands
        -- (e.g. `tailscale funnel` for a service with a Published address),
        -- both at this step's stage so the publish follows the launch in order.
        map (\command -> { stage: step.stage, service: svc.id, command, reportsTeardown: false })
          ( A.fromFoldable (commandFor tmap step.change svc)
              <> publishCommands tmap step.change svc
              <> advisoryCommands step.change svc
          )
  where
  svcs = (unValidatedDeployment vd).services

-- | The teardown script: a `Stop` for every service, in REVERSE boot order
-- | (dependents before their dependencies — the D-E5 stop ordering), so a
-- | `Container` group comes down cleanly. A `Process` Stop kills the group
-- | `daemonize` recorded and REPORTS what that did (`reportsTeardown`); a
-- | mechanism Bosun does not drive is still an honest `# MANUAL` note. No
-- | publish/unpublish here — stopping the service is the teardown.
downScript :: TargetMap -> ValidatedDeployment -> Array StagedCommand
downScript tmap vd =
  A.reverse (unBootOrder vr.bootOrder) # A.mapWithIndex stageCmds # A.concat
  where
  vr = unValidatedDeployment vd
  svcs = vr.services
  stageCmds stage nea =
    NEA.toArray nea # A.mapMaybe \ref ->
      case Map.lookup (unServiceRef ref) svcs of
        Nothing -> Nothing
        Just svc -> case commandFor tmap (Stop ref) svc of
          Nothing -> Nothing
          Just command ->
            Just { stage, service: svc.id, command, reportsTeardown: reportsTeardown svc }

-- Which services' Stop answers with a readable `TeardownVerdict`: the ones
-- whose teardown is `Substrate.pidStop`. Kept beside `commandFor`'s `Stop`
-- case, because the two must not drift apart — a Stop that emits a token and a
-- flag that says it does not (or the reverse) would be worse than neither.
reportsTeardown :: Service -> Boolean
reportsTeardown svc = case svc.launch.executor of
  Process _ -> true
  _ -> false

-- | The command for one change on one service, `ssh`-wrapped for remote hosts.
-- | `Nothing` ⇒ a `NoOp` (no command needed). The service's host resolves to a
-- | `Target` (`resolveTarget`); a `Container` op runs `docker compose` in that
-- | target's `workdir` (so the remote shell finds the compose file) prefixed by
-- | its `envPrefix` (so a non-interactive ssh shell finds `docker`), and `wrap`
-- | ssh-wraps it when the target is remote.
commandFor :: TargetMap -> Change -> Service -> Maybe Command
commandFor tmap change svc = map (wrap target) (raw change)
  where
  name = svc.launch.localName
  target = resolveTarget tmap svc.host

  -- The container substrate's compose CLI for THIS host's platform
  -- (`docker compose` / `podman compose` / …) — selected by the resolved
  -- `Target.platform`, not baked in (Bosun.Substrate.composeCmd).
  compose = composeCmd target.platform

  -- A named service is started/stopped explicitly, so no `--profile` flags are
  -- needed (docker compose acts on a service named on the command line even when
  -- its profile is inactive). Bosun has no profile-*selection* concept yet — it
  -- enacts every service in the ingested deployment — so emitting the union of a
  -- service's profile tags would be noise, not fidelity.
  docker :: String -> Command
  docker verb = Shell
    { cwd: map unAbsPath target.workdir
    , line: envExports target.envPrefix <> compose <> " " <> verb <> " " <> name
    }

  -- Build-once-ship (docs/ARTIFACTS.md): a service whose artifact is a PREBUILT
  -- image is PULLED, never built per host — `--no-build` refuses a local build
  -- even if the host compose declares one, so the shipped bytes are what runs.
  dockerPullUp :: Command
  dockerPullUp = Shell
    { cwd: map unAbsPath target.workdir
    , line: envExports target.envPrefix
        <> compose <> " pull " <> name
        <> " && " <> compose <> " up -d --no-build " <> name
    }

  -- A Container Start derives its launch from the artifact: a prebuilt Image is
  -- pulled-not-built; anything else (a source build, or an unclassified
  -- container) falls back to plain `up -d` (which respects the host compose) —
  -- with a build-once-ship advisory emitted alongside for a source build.
  containerStart :: Command
  containerStart = case svc.launch.artifact of
    Just (Image _) -> dockerPullUp
    _ -> docker "up -d"

  -- A Process is a long-running service, so a launch must be DETACHED — else
  -- `apply` blocks forever on the first foreground server (flask, julia, a dev
  -- server). `daemonize` (Bosun.Substrate, dialected by the host OS) reaps any
  -- prior recorded generation, then backgrounds + log-redirects + records the
  -- fresh launch. EVERY Process goes through that now: a command carrying its
  -- own trailing `&` has it dropped rather than being passed through untracked,
  -- so its Stop has a group to kill. Because that reap is built in, a Process
  -- Start and a Process Restart are the SAME command: "ensure the old
  -- generation is dead, then launch" — there is no cheaper restart for a native
  -- process, and the reap is the `down`-orphan fix.
  processLaunch pr = Shell
    { cwd: Just (unAbsPath pr.cwd)
    , line: daemonize target.platform.os svc.id (envAssign pr.env <> pr.command)
    }

  -- Stop a Process by killing the group `daemonize` recorded for it — Bosun's
  -- own record of what it launched, NOT "whatever holds the port" — and REPORT
  -- which of the six `TeardownVerdict`s that established. A missing pidfile
  -- still does not abort the teardown of the other services, but it no longer
  -- passes for having stopped anything.
  processStop = Shell { cwd: Nothing, line: pidStop svc.id }

  raw :: Change -> Maybe Command
  raw = case _ of
    NoOp _ -> Nothing
    Start _ -> Just case svc.launch.executor of
      Process pr -> processLaunch pr
      Container _ -> containerStart
      ex -> manual ex
    Restart _ _ -> Just case svc.launch.executor of
      Process pr -> processLaunch pr
      Container _ -> docker "restart"
      ex -> manual ex
    Stop _ -> Just case svc.launch.executor of
      Container _ -> docker "stop"
      Process _ -> processStop
      ex -> manual ex

-- | Commands that PUBLISH a service after it launches — the network-exposure
-- | half of enactment, distinct from the launch itself. A service whose
-- | `reachability` carries a `Published` address (a public DNS name) gets a
-- | `tailscale funnel` enabling its listening port on the public internet, run
-- | on (and so ssh-wrapped to) the service's host. Idempotent (`--bg` persists),
-- | so it rides every Start/Restart harmlessly. Only fires when there is BOTH a
-- | Published address and a concrete listening port to proxy to.
publishCommands :: TargetMap -> Change -> Service -> Array Command
publishCommands tmap change svc = case change of
  Start _ -> funnel
  Restart _ _ -> funnel
  _ -> []
  where
  target = resolveTarget tmap svc.host
  addrs = A.fromFoldable (addresses svc.reachability)
  published = A.any isPublished addrs
  listenPort = A.head (A.mapMaybe listenPortOf addrs)
  funnel = case published, listenPort of
    true, Just port ->
      [ wrap target (Shell
          { cwd: Nothing
          , line: envExports target.envPrefix <> "tailscale funnel --bg " <> show (unPort port)
          }) ]
    _, _ -> []

-- | Non-command advisories emitted alongside a launch — surfaced as `Manual`
-- | notes (the exec edge logs, never runs them). A Container Start whose artifact
-- | is a `SourceBuild` (built per host) gets a build-once-ship nudge: the launch
-- | still runs (we cannot do better without a shipped image), but the script
-- | records that this host is building from source rather than running shipped
-- | bytes — the drift `docs/ARTIFACTS.md` warns about, made visible at apply time.
advisoryCommands :: Change -> Service -> Array Command
advisoryCommands change svc = case change, svc.launch.executor, svc.launch.artifact of
  Start _, Container _, Just (SourceBuild (ArtifactRef r)) ->
    [ Manual ("build-once-ship: " <> unServiceId svc.id <> " builds from source ("
        <> r.source <> ") on the host — run `quartermaster build` to ship a prebuilt image instead (docs/PROVISIONING-SEAM.md)") ]
  _, _, _ -> []

isPublished :: Address -> Boolean
isPublished = case _ of
  Published _ -> true
  _ -> false

listenPortOf :: Address -> Maybe Port
listenPortOf = case _ of
  Listening l -> Just l.port
  _ -> Nothing

-- ssh-wrap only real shell commands bound for a remote target; Manual notes and
-- already-remote commands pass through unchanged. The ssh login comes from the
-- resolved `Target`, not a host string baked in here.
wrap :: Target -> Command -> Command
wrap target cmd = case cmd of
  Shell _ -> case target.exec of
    RemoteSsh dest -> Ssh (unSshDest dest) cmd
    LocalExec -> cmd
  _ -> cmd

manual :: Executor -> Command
manual = case _ of
  StaticCDN _ -> Manual "static-CDN publish — run `quartermaster publish <compose> <registry>` to ship the site (docs/PROVISIONING-SEAM.md)"
  SystemdUnit u -> Manual ("systemctl start " <> u.unit)
  LaunchdJob j -> Manual ("launchctl load " <> j.label)
  Remote _ -> Manual "remote (ssh) launch (not automated)"
  Unmanaged s -> Manual ("unmanaged: " <> s)
  _ -> Manual "no launch command for this executor yet"

-- A Process's typed launch `env` rendered as leading `KEY=VAL ` assignments,
-- which `daemonize`'s `nohup env <cmd>` (Bosun.Substrate) then applies (same
-- shell mechanism the `ATLAS_PORT=3210 julia …` startCommand already relies
-- on). Empty ⇒ "" (a transparent passthrough). Each VALUE is `shellQuote`d —
-- paths/ports/identifiers pass through verbatim (so the common case, and every
-- conformance snapshot, is unchanged), but a value with a SPACE is single-
-- quoted so `env` sees one assignment rather than splitting it into an
-- assignment plus a spurious command (the `SUPERDIRT_DEVICE="BlackHole 2ch"`
-- bug — note #398).
envAssign :: Array (Tuple EnvVar String) -> String
envAssign = foldMap \(Tuple k v) -> unEnvVar k <> "=" <> shellQuote v <> " "

-- Render a target's env prefix as leading `export K=V && …` clauses, so the
-- assignments take effect for the (non-interactive, remote) shell that runs the
-- command. Empty prefix ⇒ empty string (transparent). Values are NOT quoted
-- here (unlike `envAssign`): a target's `envPrefix` is author-controlled shell,
-- not literal data, and legitimately contains expansions that must survive —
-- e.g. the macmini `PATH=/usr/local/bin:…:$PATH` deliberately references the
-- existing `$PATH`, which single-quoting would neuter.
envExports :: Array (Tuple String String) -> String
envExports = foldMap \(Tuple k v) -> "export " <> k <> "=" <> v <> " && "
