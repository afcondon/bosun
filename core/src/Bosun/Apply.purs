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

import Bosun.Atoms (Host, ServiceId, unAbsPath, unHost, unServiceId)
import Bosun.Executor (Executor(..))
import Bosun.Plan (Change(..), Plan, changeRef, planSteps)
import Bosun.Selector (Selector(..))
import Bosun.Service (Service, ValidatedDeployment, unServiceRef, unValidatedDeployment)
import Data.Array as A
import Data.Foldable (foldMap)
import Data.Map as Map
import Data.Maybe (Maybe(..), isJust)
import Data.String (Pattern(..), Replacement(..))
import Data.String as String

-- | A launch action. `Shell` is a local command (optionally in a cwd); `Ssh`
-- | runs an inner command on a remote login target; `Manual` is a documented
-- | action Bosun does not (yet) automate — never silently dropped.
data Command
  = Shell { cwd :: Maybe String, line :: String }
  | Ssh String Command
  | Manual String
derive instance Eq Command

type StagedCommand = { stage :: Int, service :: ServiceId, command :: Command }

-- | The ordered command script for a plan. `NoOp`s contribute nothing.
applyScript :: ValidatedDeployment -> Plan -> Array StagedCommand
applyScript vd p =
  planSteps p # A.mapMaybe \step ->
    case Map.lookup (unServiceRef (changeRef step.change)) svcs of
      Nothing -> Nothing
      Just svc -> case commandFor step.change svc of
        Nothing -> Nothing
        Just command -> Just { stage: step.stage, service: svc.id, command }
  where
  svcs = (unValidatedDeployment vd).services

-- | The command for one change on one service, `ssh`-wrapped for remote hosts.
-- | `Nothing` ⇒ a `NoOp` (no command needed).
commandFor :: Change -> Service -> Maybe Command
commandFor change svc = map (wrap svc.host) (raw change)
  where
  name = svc.launch.localName

  docker :: String -> Command
  docker verb = Shell { cwd: Nothing, line: "docker compose" <> profileFlags svc <> " " <> verb <> " " <> name }

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

-- ssh-wrap only real shell commands bound for a remote host; Manual notes and
-- already-remote commands pass through unchanged.
wrap :: Maybe Host -> Command -> Command
wrap mh cmd = case cmd of
  Shell _ -> case map unHost mh of
    Just "macmini" -> Ssh "andrew@andrews-mac-mini" cmd
    _ -> cmd
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

profileFlags :: Service -> String
profileFlags svc = foldMap flag svc.selectors
  where
  flag = case _ of
    Profile p -> " --profile " <> p
    _ -> ""
