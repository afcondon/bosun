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
  , commandFor
  ) where

import Prelude

import Bosun.Atoms (ServiceId, unAbsPath, unServiceId)
import Bosun.Executor (Executor(..))
import Bosun.Plan (Change(..), Plan, changeRef, planSteps)
import Bosun.Service (Service, ValidatedDeployment, unServiceRef, unValidatedDeployment)
import Bosun.Target (ExecLoc(..), Target, TargetMap, resolveTarget, unSshDest)
import Data.Array as A
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
  planSteps p # A.mapMaybe \step ->
    case Map.lookup (unServiceRef (changeRef step.change)) svcs of
      Nothing -> Nothing
      Just svc -> case commandFor tmap step.change svc of
        Nothing -> Nothing
        Just command -> Just { stage: step.stage, service: svc.id, command }
  where
  svcs = (unValidatedDeployment vd).services

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

  -- A Process is a long-running service, so a launch must be DETACHED — else
  -- `apply` blocks forever on the first foreground server (flask, julia, a dev
  -- server). `daemonize` backgrounds + log-redirects the command unless it
  -- already backgrounds itself (so a fixture that bakes in `… &` is untouched).
  processLaunch pr = Shell { cwd: Just (unAbsPath pr.cwd), line: daemonize svc.id pr.command }

  raw :: Change -> Maybe Command
  raw = case _ of
    NoOp _ -> Nothing
    Start _ -> Just case svc.launch.executor of
      Process pr -> processLaunch pr
      Container _ -> docker "up -d"
      ex -> manual ex
    Restart _ _ -> Just case svc.launch.executor of
      Process pr -> processLaunch pr
      Container _ -> docker "restart"
      ex -> manual ex
    Stop _ -> Just case svc.launch.executor of
      Container _ -> docker "stop"
      Process _ -> Manual ("stop process (no managed handle): " <> name)
      ex -> manual ex

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
-- 2>&1 &`, so the exec edge fires it and returns. A command that already
-- backgrounds itself (ends in `&`) is left as-is — the exec edge will detach it.
--
-- The `env` is load-bearing: a `startCommand` may carry a leading env-var
-- assignment (e.g. `ATLAS_PORT=3210 julia …`), which is shell syntax `nohup`
-- does NOT honour — bare `nohup VAR=val prog` makes `nohup` try to exec the
-- string `VAR=val` as a program. `env` parses the leading `VAR=val` assignments
-- and execs the real program; with no prefix it is a transparent passthrough.
daemonize :: ServiceId -> String -> String
daemonize sid cmd
  | isJust (String.stripSuffix (Pattern "&") (String.trim cmd)) = cmd
  | otherwise = "nohup env " <> cmd <> " >" <> logPath sid <> " 2>&1 &"

logPath :: ServiceId -> String
logPath sid = "/tmp/bosun-apply-" <> sanitize (unServiceId sid) <> ".log"
  where
  sanitize =
    String.replaceAll (Pattern ":") (Replacement "-")
      >>> String.replaceAll (Pattern "/") (Replacement "-")

-- Render a target's env prefix as leading `export K=V && …` clauses, so the
-- assignments take effect for the (non-interactive, remote) shell that runs the
-- command. Empty prefix ⇒ empty string (transparent).
envExports :: Array (Tuple String String) -> String
envExports = foldMap \(Tuple k v) -> "export " <> k <> "=" <> v <> " && "
