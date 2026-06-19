-- | DESIGN — the **supervision substrate**: how a service's lifecycle is
-- | launched, tracked, and torn down. Modelled the way the container executor
-- | is (per Andrew, 2026-06-19): there is not one substrate but a family, along
-- | TWO orthogonal dimensions, and Bosun scales across all of them —
-- |
-- |   * **process substrate — `OS`** : native-process supervision. The detach /
-- |     record-a-killable-identity / group-kill primitives differ by OS userland
-- |     (BSD vs GNU). Bosun owns keep-alive here.
-- |   * **container substrate — `ContainerEngine`** : `docker` is one of several
-- |     (`podman`, `nerdctl`/containerd…). A foreign supervisor owns keep-alive;
-- |     Bosun observes + relays control (EXECUTORS.md "Bosun over a supervisor").
-- |
-- | The point of naming them is that the *command strings differ*, and which
-- | OS's / engine's semantics a given command relies on must be **explicit in the
-- | code**, not implicit — so the macOS-only assumptions that shipped first
-- | become one labelled case among many as Linux (and podman, …) land. The
-- | command generation stays PURE (rides go-conformance); only the substrate
-- | parameter selects the dialect.
module Bosun.Substrate
  ( OS(..)
  , osLabel
  , ContainerEngine(..)
  , engineLabel
  , composeCmd
  , Platform
  , defaultPlatform
  , daemonize
  , pidKill
  , pidPath
  , logPath
  ) where

import Prelude

import Bosun.Atoms (ServiceId, unServiceId)
import Data.Generic.Rep (class Generic)
import Data.Maybe (isJust)
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..), Replacement(..))
import Data.String as String

-- | The OS whose **native-process** supervision semantics a process substrate
-- | models. Each constructor names a DISTINCT set of detach / pgid-capture /
-- | group-kill behaviours; this is the dimension Andrew's "be explicit which
-- | OS's semantics where" steer is about.
data OS
  = MacOS
    -- ^ BSD userland (Darwin). NO `setsid(1)` binary. `ps -o pgid=` is the
    -- BSD format. A non-interactive `sh -c` has job control OFF, so a
    -- backgrounded child stays in the caller's process group — and the caller
    -- here is the `sh` Node spawned with `{detached:true}` (which DID setsid),
    -- so the whole launch shares that one fresh group, which we record + kill.
  | Linux
    -- ^ GNU userland. `setsid(1)` IS present, so the server can be made its OWN
    -- session+group leader directly — then `$!` is exactly its pgid, with no
    -- `ps` round-trip (reuse-safer, simpler). NB: NOT yet live-exercised — the
    -- homelab is all Darwin today; this is the modelled-and-ready Linux case.

derive instance Eq OS
derive instance Ord OS
derive instance Generic OS _
instance Show OS where show = genericShow

osLabel :: OS -> String
osLabel = case _ of
  MacOS -> "macos"
  Linux -> "linux"

-- | The **container** supervision engine. `docker` shipped first; podman and
-- | nerdctl speak a compatible `compose` surface, so they slot in by swapping
-- | only the CLI prefix (`composeCmd`).
data ContainerEngine
  = Docker   -- `docker compose …`
  | Podman   -- `podman compose …` (Podman ≥ 4 / podman-compose)
  | Nerdctl  -- `nerdctl compose …` (containerd)

derive instance Eq ContainerEngine
derive instance Ord ContainerEngine
derive instance Generic ContainerEngine _
instance Show ContainerEngine where show = genericShow

engineLabel :: ContainerEngine -> String
engineLabel = case _ of
  Docker -> "docker"
  Podman -> "podman"
  Nerdctl -> "nerdctl"

-- | The compose CLI invocation for a host's container substrate. Primarily a
-- | function of the ENGINE — but it takes the whole `Platform` ON PURPOSE: we do
-- | NOT assume an engine behaves identically across OSes (Andrew, 2026-06-19).
-- | That uniformity is the engines' raison d'être, but it is not guaranteed —
-- | Docker Desktop on macOS differs from native Docker on Linux in socket/PATH
-- | details, podman is rootless-by-default on Linux, etc. Today every
-- | `(os, engine)` yields the same `compose` prefix, so this switches on engine
-- | alone; the point is that the SEAM admits per-OS divergence rather than baking
-- | in the hoped-for sameness. (Host-specific PATH/socket env rides
-- | `Target.envPrefix`, the orthogonal knob.)
composeCmd :: Platform -> String
composeCmd p = case p.containerEngine of
  Docker -> "docker compose"
  Podman -> "podman compose"
  Nerdctl -> "nerdctl compose"

-- | A host's platform: the two substrate dimensions resolved for it. Lives on
-- | the `Target` (a host runs one OS and provides one container engine).
type Platform = { os :: OS, containerEngine :: ContainerEngine }

-- | The homelab default: every host today is macOS with Docker.
defaultPlatform :: Platform
defaultPlatform = { os: MacOS, containerEngine: Docker }

-- ── the native-process lifecycle (OS-parameterised) ──────────────────────────

-- | (Re)launch a long-running Process: REAP any prior recorded generation, THEN
-- | detach a fresh launch recording a KILLABLE identity (the process-GROUP id)
-- | so a later `pidKill` reaps the whole tree. A command that already
-- | backgrounds itself (ends in `&`) is left untouched (Bosun opts out of
-- | tracking it: no reap, no id captured; a later `pidKill` then no-ops). The OS
-- | selects only the *launch* dialect; the reap is POSIX-portable so both share
-- | it:
-- |
-- |   * **macOS/BSD** — Node's `spawn(detached)` already `setsid`'d the `sh`, so
-- |     the launch shares that fresh group. We `( … ) &` so the whole line ends
-- |     in `&` (the exec edge then spawns it detached, isolating it from the
-- |     caller's group — never reaping the Chair that invoked Bosun), and record
-- |     the server's pgid via BSD `ps -o pgid=`.
-- |   * **Linux/GNU** — `setsid` the server into its OWN session/group leader, so
-- |     `$!` IS its pgid; record that directly (no `ps`, reuse-safer).
-- |
-- | **Reap-before-launch is load-bearing — it is the fix for the `down` no-op
-- | orphan bug.** Without it, relaunching over a still-bound port (the server is
-- | slow to die, or never reaped) makes the fresh launch hit `EADDRINUSE` and
-- | exit, while the pidfile is overwritten with that dead generation's group —
-- | so the live orphan survives and every later group-kill `|| true`-succeeds
-- | against a corpse. Reaping first makes a (re)launch idempotent: the prior
-- | generation is gone before the new one binds, and the recorded id always
-- | tracks the live process. A first-ever Start finds no pidfile and the reap
-- | `|| true`-no-ops. This is why a Process Start and a Process Restart render
-- | the SAME command — on a native process there is no cheaper "restart".
-- |
-- | The `env` is load-bearing on both launch dialects: a `startCommand` may
-- | carry leading `VAR=val` assignments (e.g. `ATLAS_PORT=3210 julia …`,
-- | `ERL_LIBS=… erl …`), which `env` parses and applies before exec'ing the real
-- | program (bare `nohup VAR=val prog` would try to exec `VAR=val`). With no
-- | prefix `env` is a transparent passthrough.
daemonize :: OS -> ServiceId -> String -> String
daemonize os sid cmd
  | alreadyBackgrounds cmd = cmd
  | otherwise = reapPrior <> launch
  where
  -- Kill any prior recorded generation before binding the new one. POSIX
  -- (`kill -- -<pgid>` is identical on BSD and GNU), so OS-independent; the
  -- small settle lets the freed port/socket close before the relaunch binds.
  reapPrior = pidKill sid <> "; sleep 0.3; "
  launch = case os of
    MacOS ->
      "( nohup env " <> cmd <> " >" <> logPath sid <> " 2>&1 & "
        <> macRecordPgid sid <> " ) &"
    Linux ->
      -- setsid makes the server a session+group leader ⇒ `$!` == its pgid.
      "setsid env " <> cmd <> " >" <> logPath sid <> " 2>&1 & "
        <> "echo $! > " <> pidPath sid

alreadyBackgrounds :: String -> Boolean
alreadyBackgrounds cmd = isJust (String.stripSuffix (Pattern "&") (String.trim cmd))

-- macOS/BSD: the backgrounded server ($!) sits in the detached sh's group; BSD
-- `ps -o pgid=` reads that group id (leading spaces trimmed).
macRecordPgid :: ServiceId -> String
macRecordPgid sid = "ps -o pgid= -p $! | tr -d ' ' > " <> pidPath sid

-- | Kill the recorded process GROUP for a service (`-<pgid>`), reaping the whole
-- | launch tree. POSIX-portable (`kill -- -<pgid>` is the same on BSD and GNU),
-- | so it takes no `OS` — annotated rather than forced into false symmetry; the
-- | OS divergence is all in `daemonize`'s capture. Tolerant of a missing file
-- | (never launched by Bosun, or an already-`&` command) so a teardown stage
-- | never aborts. NB best-effort against pgid reuse — the resident `supervise`
-- | daemon, holding live state, is the reuse-safe authority.
pidKill :: ServiceId -> String
pidKill sid = "kill -- -\"$(cat " <> pidPath sid <> " 2>/dev/null)\" 2>/dev/null || true"

-- | Where a launched Process's process-group id is recorded; `Stop`/`Restart`
-- | and the supervisor's liveness probe read it. (Path only — OS-independent.)
pidPath :: ServiceId -> String
pidPath sid = "/tmp/bosun-apply-" <> sanitizeId sid <> ".pid"

logPath :: ServiceId -> String
logPath sid = "/tmp/bosun-apply-" <> sanitizeId sid <> ".log"

sanitizeId :: ServiceId -> String
sanitizeId sid =
  ( String.replaceAll (Pattern ":") (Replacement "-")
      >>> String.replaceAll (Pattern "/") (Replacement "-")
  ) (unServiceId sid)
