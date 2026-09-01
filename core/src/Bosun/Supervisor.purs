-- | The supervisor's pure tick-transition — the `recorded` state DESIGN D-7
-- | always reserved, made concrete for the live `bosun supervise` daemon.
-- |
-- | `bosun supervise` is "`plan` on a loop", but a stateless loop storms: a
-- | slow-boot service (a BEAM, a `spago run`) is observed `Down` on its
-- | readiness probe for several ticks while it binds, so the planner re-`Start`s
-- | it every tick — `beam.smp`×4, `spago`×6, the port never bound (the bug the
-- | Chair session hit, HANDOFF-ENGINE.md). The fix is launch *memory*: once we
-- | launch a service its process GROUP is alive (we hold its pgid) long before
-- | its port binds, and "group alive but not ready" is `Starting`, which the
-- | planner already turns into `NoOp`. This module threads that memory across
-- | ticks and folds it back into the `Snapshot` the planner sees.
-- |
-- | It is PURE and time is a *parameter* (`Millis` passed in at the seam), so the
-- | whole transition is deterministic and rides go-conformance byte-identically
-- | — exactly like `plan` / `applyScript`. The effectful loop (clock, timer,
-- | HTTP) stays in the CLI shim.
-- |
-- | Two states drive two behaviours:
-- |   * boot-grace — a launched service whose group is alive but isn't ready is
-- |     `Starting` until `bootGraceMs` elapses (then `Failed`: wedged, relaunch).
-- |   * backoff — after a crash relaunch we arm `suspendedUntil`; while suspended
-- |     the service reads `InBackoff` (the planner `NoOp`s it), so a fast-crash
-- |     loop is throttled exponentially rather than piled on.
-- |
-- | `restarts` (cumulative) and `since` (last transition) are the same
-- | bookkeeping ADR D-S1 wants for the Chair's `↻ N` badge — built once, used
-- | twice. `SupConfig` is deliberately the seed of a future per-service typed
-- | policy: it mirrors `Bosun.Health.RestartPolicy` (`backoff { minSec,
-- | maxRetries }`), so when the validated `Service` carries its own
-- | `RestartPolicy` the knobs resolve per service instead of one for the group.
module Bosun.Supervisor
  ( Millis
  , Observation
  , SvcState
  , SupState
  , SupConfig
  , Launch
  , defaultConfig
  , emptySupState
  , initialSvc
  , lookupSvc
  , backoffMs
  , refine
  , recordLaunches
  , SuperviseDiff
  , superviseDiff
  , forgetLaunches
  , AddressMiss(..)
  , addressService
  ) where

import Prelude

import Bosun.Atoms (ServiceId, unServiceId)
import Bosun.Plan (Snapshot, Status(..))
import Bosun.Service (Service)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldr)
import Data.Generic.Rep (class Generic)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Set as Set
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..))

-- | Milliseconds since some fixed epoch — supplied by the caller's clock at the
-- | seam, never read here, so the transition stays pure/deterministic.
type Millis = Number

-- | One service's live-edge reading this tick: its readiness probe result, plus
-- | whether the process GROUP `apply` launched is still alive (the pgid signal,
-- | `kill(-pgid, 0)`). A service we launched whose group is alive but whose
-- | readiness hasn't passed is BOOTING, not Down — the distinction the
-- | relaunch-storm fix turns on.
type Observation =
  { ready :: Status
  , groupAlive :: Boolean
  }

-- | Per-service bookkeeping threaded across ticks. `restarts` is the cumulative
-- | badge the Chair renders (ADR D-S1); `fails` is the consecutive-failure count
-- | that drives exponential backoff and resets the moment the service is healthy
-- | again. `since` is the last-transition timestamp (the badge's "Xs ago").
type SvcState =
  { restarts       :: Int
  , fails          :: Int
  , launchedAt     :: Maybe Millis
  , suspendedUntil :: Maybe Millis
  , status         :: Status
  , since          :: Millis
  }

type SupState = Map ServiceId SvcState

-- | The supervisor's knobs — a deliberate seed for a future per-service typed
-- | `Bosun.Health.RestartPolicy` (`base :: BaseRestart`, `backoff { minSec,
-- | maxRetries }`). Today one policy for the whole group; later, resolve one of
-- | these per service from its `RestartPolicy` at validate.
type SupConfig =
  { bootGraceMs   :: Millis    -- a launched-but-not-ready process is Starting this long
  , backoffBaseMs :: Millis    -- first backoff window after a crash
  , backoffMaxMs  :: Millis    -- exponential cap
  , maxRetries    :: Maybe Int -- give up (stop relaunching) past this; Nothing = forever
  }

-- | Conservative defaults: a 60s boot grace fits a `spago run` / BEAM cold start;
-- | 5s→60s exponential backoff; retry forever (a daemon should come back).
defaultConfig :: SupConfig
defaultConfig =
  { bootGraceMs: 60000.0
  , backoffBaseMs: 5000.0
  , backoffMaxMs: 60000.0
  , maxRetries: Nothing
  }

emptySupState :: SupState
emptySupState = Map.empty

initialSvc :: Millis -> SvcState
initialSvc now =
  { restarts: 0
  , fails: 0
  , launchedAt: Nothing
  , suspendedUntil: Nothing
  , status: Down
  , since: now
  }

lookupSvc :: Millis -> ServiceId -> SupState -> SvcState
lookupSvc now sid = fromMaybe (initialSvc now) <<< Map.lookup sid

-- | Exponential backoff window for the `n`th consecutive failure (1-based),
-- | capped at `backoffMaxMs`: base · 2^(n-1).
-- |
-- | DO NOT "simplify" this by dropping the `min maxExp` on the EXPONENT. It
-- | looks redundant beside the `min cfg.backoffMaxMs` on the result, and it is
-- | not: that outer `min` caps the VALUE, and PureScript is strict, so it
-- | cannot cap the WORK. `pow2` is not tail-recursive — `2.0 * pow2 (n-1)`
-- | leaves a multiply pending — so without the clamp the doubling costs ONE
-- | STACK FRAME PER CONSECUTIVE FAILURE, to compute a number the outer `min`
-- | was always going to throw away.
-- |
-- | That is not theoretical. On 2026-08-31 the MBP was unplugged from the ES-9
-- | overnight; `es9-daemon`, `fh2-daemon` and `link-spike` failed continuously
-- | for ten hours, `fails` reached ~8,200, and `pow2` overflowed the stack.
-- | `Resident.js` catches the throw and re-fires the timer, so the tick never
-- | completed, group state never converged, and every reconcile relaunched all
-- | eleven services — 6,309 SuperCollider boots and a 33 MB log before anyone
-- | noticed. `fails` resets when a service goes healthy, which is why this is
-- | unreachable in normal operation and inevitable for a daemon whose hardware
-- | went away.
-- |
-- | Clamping the exponent is the honest fix rather than making `pow2`
-- | stack-safe: past n ≈ 1024 the doubling is `Infinity` anyway, so every frame
-- | beyond `maxExp` was buying nothing even when the stack held.
backoffMs :: SupConfig -> Int -> Millis
backoffMs cfg fails = min cfg.backoffMaxMs (cfg.backoffBaseMs * pow2 (min maxExp (fails - 1)))
  where
  -- Enough doublings to blow past any cap expressible in milliseconds; beyond
  -- this the outer `min` decides the answer, so further doubling is dead work.
  maxExp = 64
  pow2 n = if n <= 0 then 1.0 else 2.0 * pow2 (n - 1)

-- | The pure tick-transition. Given the live observations and the prior state,
-- | decide the `Status` the planner should see for each service — folding launch
-- | memory in (boot-grace → `Starting`, active backoff → `InBackoff`) — and carry
-- | each service's bookkeeping forward (`status`/`since` for the badge; `fails`
-- | and `suspendedUntil` reset on a healthy reading). Restart *counting* and
-- | arming the next backoff happen AFTER the plan, in `recordLaunches` — only the
-- | planner knows what it actually relaunched (incl. D-E5 coupled co-restart).
refine
  :: SupConfig
  -> Millis
  -> SupState
  -> Map ServiceId Observation
  -> { snapshot :: Snapshot, state :: SupState }
refine cfg now prev obs =
  { snapshot: Map.fromFoldable (map (\(Tuple sid r) -> Tuple sid r.refined) stepped)
  , state: Map.fromFoldable (map (\(Tuple sid r) -> Tuple sid r.svc) stepped)
  }
  where
  stepped :: Array (Tuple ServiceId { refined :: Status, svc :: SvcState })
  stepped =
    (Map.toUnfoldable obs :: Array (Tuple ServiceId Observation))
      # map \(Tuple sid o) ->
          let
            s = lookupSvc now sid prev
            refined = decide cfg now s o
          in
            Tuple sid { refined, svc: transition now s refined }

-- | The refined status one service reports to the planner this tick.
decide :: SupConfig -> Millis -> SvcState -> Observation -> Status
decide cfg now s o = case o.ready of
  Running -> Running
  CompletedOk -> CompletedOk
  -- No probe could read it, but its group is alive — best signal we have is
  -- "process exists" (the launchd KeepAlive philosophy). Treat as up.
  Unknown _ | o.groupAlive -> Running
  _
    | suspended -> InBackoff
    | o.groupAlive -> if wedged then Failed else Starting
    -- Launched inside the grace, no group visible yet, and NEVER SEEN UP. The
    -- clause below used to collect this together with a genuine crash, but they
    -- are different facts and `s.status` is what tells them apart:
    --
    --   seen Running, group now gone  ⇒ it died. Failed, at once.
    --   never seen up, group not there yet ⇒ it may still be spawning.
    --
    -- Boot grace is the period in which we agreed not to judge, so for the
    -- second case it has to start at the LAUNCH rather than at the moment the
    -- group becomes observable — otherwise the grace is granted only to
    -- services that have already stopped needing it. Nothing noticed while
    -- nothing observed a rig in the same instant it was launched; `reconcile`
    -- on entry to `raised` does exactly that, and read every specimen as
    -- crashed.
    | booting -> Starting
    | exhausted -> InBackoff
    | isJust s.launchedAt -> Failed   -- launched, grace spent, group gone ⇒ crashed
    | otherwise -> Down               -- never launched ⇒ bring it up
  where
  suspended = case s.suspendedUntil of
    Just t -> now < t
    Nothing -> false
  wedged = case s.launchedAt of
    Just l -> now - l >= cfg.bootGraceMs
    Nothing -> false
  -- Seen up since its launch, so a vanished group is a death, not a slow start.
  wasUp = case s.status of
    Running -> true
    CompletedOk -> true
    _ -> false
  booting = isJust s.launchedAt && not wedged && not wasUp
  exhausted = case cfg.maxRetries of
    Just m -> s.fails >= m
    Nothing -> false

-- | Carry bookkeeping forward: stamp the new refined status (and `since` if it
-- | changed), and reset the backoff/consecutive-fail counters once healthy.
transition :: Millis -> SvcState -> Status -> SvcState
transition now s refined =
  let
    reset = case refined of
      Running -> s { fails = 0, suspendedUntil = Nothing }
      CompletedOk -> s { fails = 0, suspendedUntil = Nothing }
      _ -> s
  in
    reset
      { status = refined
      , since = if s.status == refined then s.since else now
      }

-- | A service the planner decided to launch this tick. `isRestart` distinguishes
-- | a crash relaunch (a `Restart` change — bumps the badge + arms backoff) from a
-- | first bring-up (a `Start` of a `Down` service — sets `launchedAt`, no backoff).
type Launch = { id :: ServiceId, isRestart :: Boolean }

-- | After the plan enacts, stamp launch memory: every launch sets `launchedAt`
-- | (so boot-grace starts ticking) and marks the service `Starting`. A `Restart`
-- | also bumps the cumulative `restarts` badge and the consecutive `fails`, and
-- | arms the next exponential backoff window.
recordLaunches :: SupConfig -> Millis -> Array Launch -> SupState -> SupState
recordLaunches cfg now launches st = foldr stamp st launches
  where
  stamp l acc =
    let
      s = lookupSvc now l.id acc
      since' = if s.status == Starting then s.since else now
      s' =
        if l.isRestart then
          let f = s.fails + 1
          in s
            { restarts = s.restarts + 1
            , fails = f
            , launchedAt = Just now
            , suspendedUntil = Just (now + backoffMs cfg f)
            , status = Starting
            , since = since'
            }
        else
          s
            { launchedAt = Just now
            , suspendedUntil = Nothing
            , status = Starting
            , since = since'
            }
    in
      Map.insert l.id s' acc

-- ── hot-reload: what a resident `supervise` must do when its spec is re-read ──

-- | What a hot-reload must do to the RUNNING group when `supervise` re-reads the
-- | compose/registry while resident — the supervise analogue of
-- | `Bosun.Serve.serveDiff`. Keyed by `ServiceId` (stable across a reload), it
-- | partitions the union of old+new services by their RESTART SIGNATURE — the
-- | launch spec + host that determine the actual running process. A change to a
-- | service's deps / routes / probe alone does NOT appear here: those change what
-- | the planner *observes* or *orders*, not the process that is running, so they
-- | need no kill.
-- |
-- |   * `removed`   — in old, gone from new ⇒ stop it, forget its launch memory.
-- |   * `changed`   — in both, signature differs ⇒ stop the old generation and
-- |                   forget its memory, so the next keep-alive tick relaunches it
-- |                   with the new spec (a native Process has no cheaper restart;
-- |                   `Substrate.daemonize` reaps-before-launch regardless).
-- |   * `added`     — new only ⇒ nothing to stop; the next tick brings it up
-- |                   (no launch memory ⇒ observed `Down` ⇒ `Start`).
-- |   * `unchanged` — in both, identical signature ⇒ LEAVE IT RUNNING and, above
-- |                   all, KEEP its launch memory. This is the double-launch
-- |                   guard (note #397 part b): a reload that forgot memory would
-- |                   re-read a live UDP/socket daemon (es9-daemon on OSC 57130,
-- |                   link-spike) — which a TCP probe cannot see — as "never
-- |                   launched" and `Start` a SECOND copy, colliding on the
-- |                   CoreAudio device / OSC port. The pgid the supervisor holds
-- |                   is the honest liveness signal; preserving it across the
-- |                   reload is precisely what makes re-observe safe.
-- |
-- | Pure and order-deterministic (ids walked in sorted-Set order), so it rides
-- | node≡Go conformance like `serveDiff` / `refine`.
type SuperviseDiff =
  { removed   :: Array ServiceId
  , added     :: Array ServiceId
  , changed   :: Array ServiceId
  , unchanged :: Array ServiceId
  }

superviseDiff :: Map ServiceId Service -> Map ServiceId Service -> SuperviseDiff
superviseDiff old new =
  foldr bucket { removed: [], added: [], changed: [], unchanged: [] } allIds
  where
  allIds :: Array ServiceId
  allIds = Set.toUnfoldable (Set.union (Map.keys old) (Map.keys new))

  bucket sid acc = case Map.lookup sid old, Map.lookup sid new of
    Just o, Just n
      | sameProcess o n -> acc { unchanged = A.cons sid acc.unchanged }
      | otherwise -> acc { changed = A.cons sid acc.changed }
    Just _, Nothing -> acc { removed = A.cons sid acc.removed }
    Nothing, Just _ -> acc { added = A.cons sid acc.added }
    Nothing, Nothing -> acc   -- unreachable: sid came from old∪new

  -- The restart signature: everything that determines the actual launched
  -- process. `launch` (executor cwd/command/env for a Process, or the container
  -- spec) and `host` (which machine / ssh target). All `Eq`, so this is a plain
  -- structural comparison — no bespoke Show/serialisation to drift.
  sameProcess o n =
    { host: o.host, launch: o.launch } == { host: n.host, launch: n.launch }

-- | Drop launch memory for a set of services — the counterpart to
-- | `recordLaunches`, used on hot-reload for the `removed`/`changed` services so
-- | the next tick sees them as un-launched (a `changed` service then relaunches
-- | with its new spec; a `removed` one, absent from the new deployment, simply
-- | stops being observed). Services NOT in the list keep their memory — the
-- | double-launch guard that `superviseDiff.unchanged` relies on.
forgetLaunches :: Array ServiceId -> SupState -> SupState
forgetLaunches ids st = foldr Map.delete st ids

-- ── addressing a service on the control surface ──────────────────────────────

-- | Why a `?service=<name>` on a group's control surface named nothing the
-- | group holds.
-- |
-- | The trap this exists for (FINDINGS-supervision-blind-spots.md §4): `bosun
-- | serve` addresses routes by PORT and `bosun supervise` addresses services by
-- | ID, and asking the wrong one answered `no service `X` in this group` — true,
-- | and it reads as "that daemon is not running" about a daemon that is running
-- | fine, because it is lazy-spawned by the router and therefore in no group at
-- | all. The operator goes looking for a registry problem. The router's half of
-- | this was fixed in bd28adc, where its 404 learned to distinguish nothing-at
-- | -all from brokered from a 421 to another host; this is the other half.
-- |
-- | Five findings were sharing one sentence, and two of them were already known
-- | to be in there: `LooksLikePort` is the trap itself, and `Unnamed` is the
-- | missing query parameter the old code commented on as landing in the same
-- | message. `NearMiss` and `Ambiguous` are the ones nobody had named — ids here
-- | are usually `slug:role`, so asking for `itajara` is overwhelmingly a
-- | spelling rather than an absence, and whether the group can tell WHICH
-- | service was meant is a different answer again.
-- |
-- | Note what is deliberately NOT a case: "the router has this one". A group
-- | cannot know that without asking the router, and putting a synchronous HTTP
-- | call to another daemon on a control verb's refusal path buys a maybe-answer
-- | at the cost of a new failure mode (the router being down would make this
-- | refusal slow, or fail). The remedy is structural instead — say that
-- | lazy-spawned services live in no group and name where they do live, which
-- | is true whether or not the router happens to hold this one.
data AddressMiss
  = Unnamed                     -- ^ no `?service=` at all
  | LooksLikePort Int           -- ^ a port: the router's key, never a group's
  | NearMiss ServiceId          -- ^ exactly one id here could be what was meant
  | Ambiguous (Array ServiceId) -- ^ several could, and guessing is not this surface's job
  | NotInGroup                  -- ^ nothing here answers to it under any spelling
derive instance Eq AddressMiss
derive instance Generic AddressMiss _
instance Show AddressMiss where show = genericShow

-- | Read a control verb's `?service=` argument against the ids a group actually
-- | holds. `Right` ⇒ act on it; `Left` ⇒ refuse, and the constructor says which
-- | mistake to explain.
-- |
-- | A `NearMiss` is REPORTED, never acted on. Restarting `itajara:worker`
-- | because someone typed `itajara` would be a control surface guessing which
-- | process to signal, and the whole point of these refusals is that a surface
-- | which acts on something other than what it was asked teaches you to distrust
-- | it. Naming the id costs the operator one retry and no ambiguity.
addressService :: Array ServiceId -> String -> Either AddressMiss ServiceId
addressService ids asked = case A.find (\sid -> unServiceId sid == asked) ids of
  Just sid -> Right sid
  Nothing -> Left miss
  where
  miss
    | asked == "" = Unnamed
    -- Ports before spellings: a port-shaped string can never BE a service id, so
    -- no amount of near-miss matching would help, and the answer wanted is about
    -- the addressing scheme rather than about how the name was typed.
    | otherwise = case Int.fromString asked of
        Just p -> LooksLikePort p
        Nothing -> case near of
          [ sid ] -> NearMiss sid
          [] -> NotInGroup
          several -> Ambiguous several

  -- Case-insensitive, and matching either way across the `slug:role` colon: the
  -- two spellings an operator actually produces are the bare slug of a
  -- `slug:role` id, and a `slug:role` for a group whose ids are bare (a
  -- compose-only group keys by the compose service name).
  key = String.toLower asked
  slugOf = String.toLower <<< fromMaybe "" <<< A.head <<< String.split (Pattern ":")
  near = A.filter candidate ids
  candidate sid =
    let full = String.toLower (unServiceId sid)
    in full == key || slugOf (unServiceId sid) == key || full == slugOf asked
