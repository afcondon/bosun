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
  , pidPath
  ) where

import Prelude

import Bosun.Artifact (Artifact(..), ArtifactRef(..))
import Bosun.Atoms (EnvVar, Port, ServiceId, unAbsPath, unEnvVar, unPort, unServiceId)
import Bosun.Executor (Executor(..))
import Bosun.Plan (Change(..), Plan, changeRef, planSteps)
import Bosun.Reachability (Address(..), addresses)
import Bosun.Service (Service, ValidatedDeployment, unBootOrder, unServiceRef, unValidatedDeployment)
import Bosun.Target (ExecLoc(..), Target, TargetMap, resolveTarget, unSshDest)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Foldable (foldMap)
import Data.Map as Map
import Data.Maybe (Maybe(..), isJust)
import Data.String (Pattern(..), Replacement(..))
import Data.String as String
import Data.Tuple (Tuple(..))

-- | A launch action. `Shell` is a local command (optionally in a cwd); `Ssh`
-- | runs an inner command on a remote login target; `Manual` is a documented
-- | action Bosun does not (yet) automate — never silently dropped.
data Command
  = Shell { cwd :: Maybe String, line :: String }
  | Ssh String Command
  | Manual String
derive instance Eq Command

type StagedCommand = { stage :: Int, service :: ServiceId, command :: Command }

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
        map (\command -> { stage: step.stage, service: svc.id, command })
          ( A.fromFoldable (commandFor tmap step.change svc)
              <> publishCommands tmap step.change svc
              <> advisoryCommands step.change svc
          )
  where
  svcs = (unValidatedDeployment vd).services

-- | The teardown script: a `Stop` for every service, in REVERSE boot order
-- | (dependents before their dependencies — the D-E5 stop ordering), so a
-- | `Container` group comes down cleanly. A `Process` Stop is still an honest
-- | `# MANUAL` note (an unmanaged local process has no handle to kill — task
-- | #8; the resident `supervise` mode or a recorded-PID `down` closes that). No
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
          Just command -> Just { stage, service: svc.id, command }

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

  -- A named service is started/stopped explicitly, so no `--profile` flags are
  -- needed (docker compose acts on a service named on the command line even when
  -- its profile is inactive). Bosun has no profile-*selection* concept yet — it
  -- enacts every service in the ingested deployment — so emitting the union of a
  -- service's profile tags would be noise, not fidelity.
  docker :: String -> Command
  docker verb = Shell
    { cwd: map unAbsPath target.workdir
    , line: envExports target.envPrefix <> "docker compose " <> verb <> " " <> name
    }

  -- Build-once-ship (docs/ARTIFACTS.md): a service whose artifact is a PREBUILT
  -- image is PULLED, never built per host — `--no-build` refuses a local build
  -- even if the host compose declares one, so the shipped bytes are what runs.
  dockerPullUp :: Command
  dockerPullUp = Shell
    { cwd: map unAbsPath target.workdir
    , line: envExports target.envPrefix
        <> "docker compose pull " <> name
        <> " && docker compose up -d --no-build " <> name
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
  -- server). `daemonize` backgrounds + log-redirects the command unless it
  -- already backgrounds itself (so a fixture that bakes in `… &` is untouched).
  processLaunch pr = Shell { cwd: Just (unAbsPath pr.cwd), line: daemonize svc.id (envAssign pr.env <> pr.command) }

  -- Stop a Process by killing the PID `daemonize` recorded for it — Bosun's own
  -- record of what it launched, NOT "whatever holds the port". A missing PID
  -- file (never launched by Bosun, or an already-`&` command) ⇒ a harmless
  -- no-op (`|| true`), never an error that aborts the teardown.
  processStop = Shell { cwd: Nothing, line: pidKill svc.id }

  -- Restart = stop the recorded PID, then relaunch (recording the new PID).
  processRestart pr = Shell
    { cwd: Just (unAbsPath pr.cwd)
    , line: pidKill svc.id <> "; sleep 0.3; " <> daemonize svc.id (envAssign pr.env <> pr.command)
    }

  raw :: Change -> Maybe Command
  raw = case _ of
    NoOp _ -> Nothing
    Start _ -> Just case svc.launch.executor of
      Process pr -> processLaunch pr
      Container _ -> containerStart
      ex -> manual ex
    Restart _ _ -> Just case svc.launch.executor of
      Process pr -> processRestart pr
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
        <> r.source <> ") on the host — ship a prebuilt image instead (docs/ARTIFACTS.md)") ]
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
  StaticCDN _ -> Manual "static-CDN publish (not automated)"
  SystemdUnit u -> Manual ("systemctl start " <> u.unit)
  LaunchdJob j -> Manual ("launchctl load " <> j.label)
  Remote _ -> Manual "remote (ssh) launch (not automated)"
  Unmanaged s -> Manual ("unmanaged: " <> s)
  _ -> Manual "no launch command for this executor yet"

-- Detach a long-running Process launch: `nohup env <cmd> >/tmp/bosun-apply-<id>.log
-- 2>&1 & echo $! > <pidpath>`, so the exec edge fires it and returns AND records
-- the launched PID — Bosun's own record of what it started, the on-disk form of
-- `WorldState.recorded`, which `Stop`/`Restart` read to kill the right process
-- (NOT a port-kill heuristic). A command that already backgrounds itself (ends
-- in `&`) is left as-is (no PID captured — a `Stop` then no-ops harmlessly).
--
-- The `env` is load-bearing: a `startCommand` may carry a leading env-var
-- assignment (e.g. `ATLAS_PORT=3210 julia …`), which is shell syntax `nohup`
-- does NOT honour — bare `nohup VAR=val prog` makes `nohup` try to exec the
-- string `VAR=val` as a program. `env` parses the leading `VAR=val` assignments
-- and execs the real program; with no prefix it is a transparent passthrough.
daemonize :: ServiceId -> String -> String
daemonize sid cmd
  | isJust (String.stripSuffix (Pattern "&") (String.trim cmd)) = cmd
  | otherwise =
      -- Wrap in `( … ) &` so the whole launch+record ENDS in `&`: the exec edge
      -- detects a backgrounded launch and spawns it DETACHED (a new session/group
      -- via setsid), which isolates the launched group from the caller's. That
      -- makes the recorded PGID the server's own group, so a later group-kill is
      -- precise and can NEVER hit the shell/Chair that invoked Bosun. (Without
      -- the wrap the line ends in the pidfile redirect, runs synchronously in the
      -- caller's group, and the group-kill would reap the caller — the footgun.)
      "( nohup env " <> cmd <> " >" <> logPath sid <> " 2>&1 & " <> recordPgid sid <> " ) &"

-- A Process's typed launch `env` rendered as leading `KEY=VAL ` assignments,
-- which `daemonize`'s `nohup env <cmd>` then applies (same shell mechanism the
-- `ATLAS_PORT=3210 julia …` startCommand already relies on). Empty ⇒ "" (a
-- transparent passthrough). Values are unquoted, matching that precedent — these
-- are paths/ports/identifiers; a value with spaces would need quoting (and would
-- also trip the known ssh single-quote papercut for remote Process commands).
envAssign :: Array (Tuple EnvVar String) -> String
envAssign = foldMap \(Tuple k v) -> unEnvVar k <> "=" <> v <> " "

logPath :: ServiceId -> String
logPath sid = "/tmp/bosun-apply-" <> sanitizeId sid <> ".log"

-- Where `daemonize` records a launched Process's process-GROUP id; `Stop`/
-- `Restart` read it. We record the PGID, not the bare PID, because `nohup`/`env`
-- fork on macOS — `$!` is the wrapper, and the real server is a child in the
-- same process group. Killing the group reaps the whole tree (the DeepStar A6
-- wrapper-hides-the-daemon problem).
pidPath :: ServiceId -> String
pidPath sid = "/tmp/bosun-apply-" <> sanitizeId sid <> ".pid"

-- Record the backgrounded job's process-group id (the whole launch tree).
recordPgid :: ServiceId -> String
recordPgid sid = "ps -o pgid= -p $! | tr -d ' ' > " <> pidPath sid

-- Kill the recorded process GROUP for a service (`-<pgid>`), reaping the whole
-- tree. Tolerant of a missing file (never launched by Bosun, or an already-`&`
-- command) so a teardown stage never aborts on a service that wasn't ours to
-- stop. NB best-effort: a recorded PGID can be stale (macOS id reuse) — the
-- resident `supervise` daemon, holding the live handle, is the reuse-safe
-- authority (ROADMAP Stage 2).
pidKill :: ServiceId -> String
pidKill sid = "kill -- -\"$(cat " <> pidPath sid <> " 2>/dev/null)\" 2>/dev/null || true"

sanitizeId :: ServiceId -> String
sanitizeId sid =
  ( String.replaceAll (Pattern ":") (Replacement "-")
      >>> String.replaceAll (Pattern "/") (Replacement "-")
  ) (unServiceId sid)

-- Render a target's env prefix as leading `export K=V && …` clauses, so the
-- assignments take effect for the (non-interactive, remote) shell that runs the
-- command. Empty prefix ⇒ empty string (transparent).
envExports :: Array (Tuple String String) -> String
envExports = foldMap \(Tuple k v) -> "export " <> k <> "=" <> v <> " && "
