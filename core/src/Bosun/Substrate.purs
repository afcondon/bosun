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
  , reapPrior
  , pidStop
  , TeardownVerdict(..)
  , allTeardownVerdicts
  , teardownTag
  , teardownSettled
  , TeardownEvidence
  , readTeardown
  , releaseBudgetSecs
  , killMaxPolls
  , pidPath
  , pidLease
  , leaseEveryMs
  , logPath
  , shellQuote
  ) where

import Prelude

import Bosun.Atoms (ServiceId, unServiceId)
import Data.Array as Array
import Data.Generic.Rep (class Generic)
import Data.Maybe (fromMaybe, isJust)
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..), Replacement(..))
import Data.String as String
import Data.String.CodeUnits as SCU

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
-- | so a later `pidStop` reaps the whole tree. EVERY Process is tracked — see
-- | `dropBackgrounding` for the case that used not to be. The OS selects only
-- | the *launch* dialect; the reap is POSIX-portable so both share it:
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
daemonize os sid cmd = reapPrior sid <> launch
  where
  runnable = dropBackgrounding cmd
  -- Kill any prior recorded generation, then BLOCK until its group is
  -- actually gone, before binding the new one (release-before-bind). A fixed
  -- `sleep` under-waits a slow-dying server — e.g. the BEAM holding a UDP
  -- listener past 300ms — so the relaunch loses the bind race and comes up
  -- degraded (the Atlantis 57121 anchor-listener incident, docs/RESTART-
  -- BARRIER.md). Polling group-existence instead waits exactly as long as
  -- the corpse takes and no longer. POSIX-portable, so OS-independent.
  --
  -- NEVER LAUNCH OVER A LIVING GROUP (2026-11-17). `reapPrior` ends with the
  -- old group either gone or, rarely, alive after TERM and KILL. In the second
  -- case launching would overwrite the pidfile with the new group and leave
  -- the old one an orphan that nothing names: that is how an Infovore stuck
  -- in a request outlived two restarts on the Mini (worklog 2026-11-16). So
  -- the launch is the right-hand side of `stillHeld ||`: it runs only when
  -- the old group is gone, and otherwise the pidfile is left naming it and
  -- the service's log says why nothing was launched. On macOS the `&` at the
  -- end backgrounds the whole `stillHeld || ( … )` list, so the line still
  -- ends in `&`, which is how the exec edge knows a launch.
  stillHeld =
    "{ [ -n \"$p\" ] && " <> groupAlive <> " && echo \"bosun: not launched: the previous "
      <> "process group $p is still alive after TERM and KILL\" >>" <> logPath sid <> "; } || "
  launch = stillHeld <> case os of
    MacOS ->
      "( nohup env " <> runnable <> " >" <> logPath sid <> " 2>&1 & "
        <> macRecordPgid sid <> " ) &"
    Linux ->
      -- setsid makes the server a session+group leader ⇒ `$!` == its pgid.
      "{ setsid env " <> runnable <> " >" <> logPath sid <> " 2>&1 & "
        <> "echo $! > " <> pidPath sid <> "; }"

-- | Drop a start command's OWN trailing `&`, so `daemonize` can do the
-- | backgrounding and record what it backgrounded.
-- |
-- | This replaces an `alreadyBackgrounds` guard that returned such a command
-- | VERBATIM — no reap, no release barrier, and no pidfile. The passthrough was
-- | deliberate ("Bosun opts out of tracking it") but the consequence was not
-- | stated anywhere the operator could see it: the service's Stop rendered a
-- | group-kill against a pidfile that never existed, `cat` failed, and the
-- | old `2>/dev/null || true` turned that into a green tick. `bosun down` over
-- | `fixtures/hello` reported success with both servers still listening.
-- |
-- | Opting out is not a thing a registry row should be able to do by accident,
-- | and a trailing `&` is exactly an accident — it is how you write a start
-- | command for a terminal, not a declaration that this service is unmanaged
-- | (`Executor.Unmanaged` is how you say that, and it is honest about it).
-- | Dropping the `&` costs nothing: `daemonize` immediately re-backgrounds the
-- | command inside the subshell whose group it records, so a grandchild that
-- | goes on to background ITSELF still lands in that group and still gets
-- | reaped (measured 2026-08-25: `sh -c` → `npm exec` → `http-server` shared
-- | one pgid and one `kill -- -<pgid>` took all three).
-- |
-- | LIMIT, stated because the next person will meet it: this drops ONE trailing
-- | `&`, which is the whole of the shape that occurs (`… >log 2>&1 &`). A
-- | command that backgrounds something MID-line (`a & b &`) is left with `a &
-- | b`, and `b` then runs in the launch subshell's foreground. No such command
-- | exists in this repo; the same is already true of `cmd1 && cmd2`, which the
-- | `nohup env` prefix has always only applied to `cmd1`.
dropBackgrounding :: String -> String
dropBackgrounding cmd =
  let t = String.trim cmd
  in String.trim (fromMaybe t (String.stripSuffix (Pattern "&") t))

-- macOS/BSD: the backgrounded server ($!) sits in the detached sh's group; BSD
-- `ps -o pgid=` reads that group id (leading spaces trimmed).
macRecordPgid :: ServiceId -> String
macRecordPgid sid = "ps -o pgid= -p $! | tr -d ' ' > " <> pidPath sid

-- | REAP-BEFORE-LAUNCH: stop the recorded process GROUP for a service
-- | (`-<pgid>`, so the whole launch tree) and block until it is gone, so the
-- | kernel has released its ports before the new generation binds.
-- |
-- | TERM, then up to `releaseMaxPolls` × 100ms for the group to exit; if it is
-- | still there, KILL, then up to `killMaxPolls` × 100ms. Until 2026-11-17 the
-- | line stopped at TERM and the launch went ahead regardless, so a service
-- | that ignored TERM for five seconds was launched over and orphaned. Docker,
-- | launchd and systemd all escalate the same way, and so did Bosun itself for
-- | strangers on a port (`Holding.reapStrangers`).
-- |
-- | Leaves `$p` set to the recorded group id (empty when there is no usable
-- | pidfile, as on a first-ever Start), for `daemonize` to look at once more
-- | before it launches. POSIX `sh`, the same on BSD and GNU, so it takes no
-- | `OS`. Silent: the line is fire-and-forget, with no reader for a verdict.
-- | The teardown form, which a human or the Chair is waiting on, is `pidStop`.
-- |
-- | NB best-effort against pgid reuse — the resident `supervise` daemon,
-- | holding live state, is the reuse-safe authority.
reapPrior :: ServiceId -> String
reapPrior sid =
  recordedGroup sid
    <> "if [ -n \"$p\" ]; then kill -- -\"$p\" 2>/dev/null; "
    <> awaitGone releaseMaxPolls
    <> "if " <> groupAlive <> "; then kill -KILL -- -\"$p\" 2>/dev/null; "
    <> awaitGone killMaxPolls <> "fi; fi; "

-- | `p=<the recorded group id>`: digits only, so a missing, empty or garbled
-- | pidfile leaves it empty.
recordedGroup :: ServiceId -> String
recordedGroup sid = "p=$(cat " <> pidPath sid <> " 2>/dev/null | tr -dc 0-9); "

-- | Does group `$p` exist? Signal 0 tests existence without signalling.
groupAlive :: String
groupAlive = "kill -0 -\"$p\" 2>/dev/null"

-- | RELEASE BARRIER. Block until group `$p` is fully gone — every member
-- | exited, so the kernel has released all its ports and sockets — or the
-- | given number of 100ms polls elapse.
awaitGone :: Int -> String
awaitGone polls =
  "i=0; while " <> groupAlive <> " && [ \"$i\" -lt " <> show polls
    <> " ]; do sleep 0.1; i=$((i+1)); done; "

-- | Release-barrier budget: 100ms × this. 50 ⇒ up to 5s for a slow-dying group
-- | (a BEAM's graceful shutdown + socket teardown fits comfortably); a corpse
-- | that dies promptly costs only one poll.
releaseMaxPolls :: Int
releaseMaxPolls = 50

-- | The same budget in whole seconds, for the sentences that quote it. Derived,
-- | not restated, so a change to the budget cannot leave the message lying.
releaseBudgetSecs :: Int
releaseBudgetSecs = releaseMaxPolls / 10

-- | How long a group gets to disappear after KILL: 100ms × this. KILL cannot
-- | be caught, so this only covers the kernel tearing the processes down.
killMaxPolls :: Int
killMaxPolls = 20

-- ── what a teardown actually did ─────────────────────────────────────────────

-- | What one Process Stop established. This is a TAXONOMY where there used to
-- | be nothing at all: the old teardown line ended `2>/dev/null || true`, so
-- | every outcome — reaped a live group, found no pidfile, found a corpse, was
-- | refused by the kernel — arrived at the operator as the same silent exit 0.
-- | `POST /control/down` over `fixtures/hello` answered `{"ok":true}` with both
-- | servers still listening, and nothing anywhere could have said otherwise.
-- |
-- | Same discipline as `Serve`'s `StopVerdict`: the shell gathers evidence, the
-- | pure core weighs it (`readTeardown`), so the verdict is unit-testable and
-- | the same on every runtime.
-- |
-- | The brief asked for three — signalled, nothing to signal, cannot tell — and
-- | said to say so if there was a fourth. There are seven, because "nothing to
-- | signal" is two different facts with two different remedies, and so is
-- | "did not die":
-- |
-- |   * `NoRecord` vs `AlreadyGone` — no pgid recorded at all (bosun did not
-- |     launch this generation, or `/tmp` was swept: something may well still be
-- |     running and bosun cannot see it) versus a pgid that was recorded and has
-- |     already exited (nothing is running; nothing to do). Collapsing these is
-- |     exactly the old bug: it reports the dangerous case as the harmless one.
-- |   * `Survived` vs `Refused` — still alive after TERM and KILL (something
-- |     the kernel cannot tear down) versus the kernel would not deliver the
-- |     signal (it is not ours to kill; find the owner). Different next command.
-- |   * `Reaped` vs `Killed` (2026-11-17) — both mean the service is down. One
-- |     exited when asked; the other ignored TERM for the whole release window
-- |     and was killed, so whatever it would have saved on the way out it did
-- |     not. An operator needs to know which.
data TeardownVerdict
  = Reaped       -- ^ signalled the recorded group; it is gone
  | Killed       -- ^ ignored TERM for the release window; KILL took it
  | AlreadyGone  -- ^ a group was recorded and had already exited; nothing to signal
  | NoRecord     -- ^ no usable pgid recorded; NOTHING was signalled
  | Survived     -- ^ still alive after TERM, the release window, and KILL
  | Refused      -- ^ the group is alive and the kernel refused the signal
  | Unreadable   -- ^ the stop reported nothing: the shell never got that far
derive instance Eq TeardownVerdict
derive instance Ord TeardownVerdict
derive instance Generic TeardownVerdict _
instance Show TeardownVerdict where show = genericShow

-- | Every constructor, for the readers that must consider all of them.
allTeardownVerdicts :: Array TeardownVerdict
allTeardownVerdicts = [ Reaped, Killed, AlreadyGone, NoRecord, Survived, Refused, Unreadable ]

-- | The bare wire word. `pidStop` echoes it behind `teardownPrefix`; the
-- | summary line prints it plain.
teardownTag :: TeardownVerdict -> String
teardownTag = case _ of
  Reaped -> "reaped"
  Killed -> "killed"
  AlreadyGone -> "already-gone"
  NoRecord -> "no-record"
  Survived -> "survived"
  Refused -> "refused"
  Unreadable -> "unreadable"

-- | Is the service known to be down? Only the three verdicts that establish it.
-- | `NoRecord` is deliberately NOT settled even though it is the commonest and
-- | most innocent-looking: "we signalled nothing" is not "it stopped", and
-- | treating it as success is the whole of the bug this type exists to end.
teardownSettled :: TeardownVerdict -> Boolean
teardownSettled = case _ of
  Reaped -> true
  Killed -> true
  AlreadyGone -> true
  _ -> false

-- | The prefix that makes the token findable in output that may also carry a
-- | remote shell's own chatter (an ssh banner, a stray warning).
teardownPrefix :: String
teardownPrefix = "bosun-stop:"

-- | What the exec edge can say about one Stop without being asked to judge it:
-- | whether the shell ran at all, and what it printed. Nothing more is
-- | available at that seam, and nothing more is needed.
type TeardownEvidence = { ran :: Boolean, output :: String }

-- | Weigh it. A command that never ran tells us nothing about the service —
-- | `Unreadable`, NOT "already gone" — and so does a command that ran and
-- | printed no token we know (a shell too old for the script, output eaten
-- | somewhere in an ssh pipeline). Both cases used to be indistinguishable from
-- | success; neither is success now.
readTeardown :: TeardownEvidence -> TeardownVerdict
readTeardown ev
  | not ev.ran = Unreadable
  | otherwise = fromMaybe Unreadable (Array.find spoken allTeardownVerdicts)
  where
  spoken v = String.contains (Pattern (teardownPrefix <> teardownTag v)) ev.output

-- | TEARDOWN FORM of the group kill: establish which `TeardownVerdict` holds and
-- | say so on stdout, in one POSIX `sh` line, exiting 0 whatever it finds — a
-- | service that cannot be stopped must not abort the teardown of the rest.
-- |
-- | Ordered so that each branch runs only when the previous one has been ruled
-- | out, because the interesting distinctions are all races:
-- |
-- |   1. no digits in the pidfile (missing, empty, or garbage) ⇒ `NoRecord`.
-- |   2. the group does not exist ⇒ `AlreadyGone` — checked BEFORE signalling,
-- |      so a corpse is never reported as a kill.
-- |   3. the signal fails ⇒ re-check existence, because the group may simply
-- |      have exited between (2) and (3). Alive ⇒ `Refused`; gone ⇒
-- |      `AlreadyGone`. Without the re-check that race reads as EPERM and sends
-- |      the operator hunting for an owner who does not exist.
-- |   4. otherwise poll the same release barrier `daemonize` uses, then look
-- |      once more: gone ⇒ `Reaped`.
-- |   5. still alive ⇒ KILL, poll again: gone ⇒ `Killed`, alive ⇒ `Survived`.
-- |
-- | CONTAINS NO SINGLE QUOTES, and must not grow any: `Report.renderCommand`
-- | wraps a remote command as `ssh dest '<inner>'`, so one apostrophe in here
-- | would close that quote and hand the rest of the script to the local shell.
pidStop :: ServiceId -> String
pidStop sid =
  recordedGroup sid
    <> "if [ -z \"$p\" ]; then " <> say NoRecord
    <> "elif ! " <> groupAlive <> "; then " <> say AlreadyGone
    <> "elif ! kill -- -\"$p\" 2>/dev/null; then "
    <> "if " <> groupAlive <> "; then " <> say Refused
    <> "else " <> say AlreadyGone <> "fi; "
    <> "else " <> awaitGone releaseMaxPolls
    <> "if ! " <> groupAlive <> "; then " <> say Reaped
    <> "else kill -KILL -- -\"$p\" 2>/dev/null; " <> awaitGone killMaxPolls
    <> "if " <> groupAlive <> "; then " <> say Survived
    <> "else " <> say Killed <> "fi; fi; fi"
  where
  say v = "echo " <> teardownPrefix <> teardownTag v <> "; "

-- | Where a launched Process's process-group id is recorded; `Stop`/`Restart`
-- | and the supervisor's liveness probe read it. (Path only — OS-independent.)
pidPath :: ServiceId -> String
pidPath sid = "/tmp/bosun-apply-" <> sanitizeId sid <> ".pid"

-- | THE LEASE on a pidfile, renewed by the supervisor that owns it.
-- |
-- | macOS's `com.apple.tmp_cleaner` deletes, every midnight, anything in `/tmp`
-- | whose atime, mtime and ctime are ALL over three days old — and a pidfile is
-- | written once, at launch, and reading it does not refresh its atime here. So
-- | a service that ran three days without a relaunch lost its pidfile, and its
-- | supervisor lost it: `restart` replaced nothing, `down` signalled nothing,
-- | and a `probe: process` service read Down and was relaunched into its own
-- | running copy (docs/FINDINGS-restart-ok-on-orphan.md, "the root cause").
-- |
-- | `/tmp` itself is RIGHT for a pidfile and stays: it is cleared at boot, so a
-- | pgid recorded before a reboot can never be trusted after one and signal
-- | some unrelated group that inherited the number. A persistent directory
-- | would trade the sweep for that. What was missing is only that the owner
-- | says, while the group lives, that the record is still in use — `touch -c`
-- | refreshes all three times and never creates a file, so a service that has
-- | gone keeps no lease.
pidLease :: Array ServiceId -> String
pidLease sids = "touch -c " <> String.joinWith " " (map pidPath sids)

-- | How often the lease is renewed: often enough to be far inside the
-- | three-day sweep, rarely enough to cost nothing.
leaseEveryMs :: Number
leaseEveryMs = 600000.0

logPath :: ServiceId -> String
logPath sid = "/tmp/bosun-apply-" <> sanitizeId sid <> ".log"

sanitizeId :: ServiceId -> String
sanitizeId sid =
  ( String.replaceAll (Pattern ":") (Replacement "-")
      >>> String.replaceAll (Pattern "/") (Replacement "-")
  ) (unServiceId sid)

-- | POSIX single-quote a value for safe inclusion in a rendered shell command
-- | (the `shlex.quote` convention). A value composed ENTIRELY of shell-safe
-- | characters — the alnum plus the path / port / identifier punctuation that
-- | env assignments have always carried (`/ . _ - : = @ % + ,`) — is returned
-- | VERBATIM. That keeps the unquoted `KEY=VAL` form for the paths, ports, and
-- | identifiers that are the overwhelming common case (`ATLAS_PORT=3210`,
-- | `ERL_LIBS=_build/default/lib`) and so leaves every existing conformance
-- | snapshot byte-identical.
-- |
-- | Anything else — most importantly a value containing a SPACE
-- | (`BlackHole 2ch`, the CoreAudio device name that shipped this bug: an
-- | unquoted `env SUPERDIRT_DEVICE=BlackHole 2ch …` split into an assignment
-- | plus a bogus `2ch` COMMAND) — is wrapped in SINGLE quotes so nothing inside
-- | is re-interpreted (no `$var`, no `` `cmd` ``, no backslash escapes). Any
-- | embedded single quote is rendered with the classic `'\''` break-out
-- | (close-quote, escaped-quote, reopen-quote). Pure, so it rides go-conformance
-- | like the rest of the command generation.
shellQuote :: String -> String
shellQuote s
  | s /= "" && Array.all shellSafeChar (SCU.toCharArray s) = s
  | otherwise =
      "'" <> String.replaceAll (Pattern "'") (Replacement "'\\''") s <> "'"

-- A character that needs no shell quoting inside a `KEY=VAL` assignment: alnum
-- plus the path / port / identifier punctuation env values have always used.
shellSafeChar :: Char -> Boolean
shellSafeChar c =
  (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || isJust (String.indexOf (Pattern (SCU.singleton c)) "_-./:=@%+,")
