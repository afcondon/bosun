-- | DESIGN §4 / DECISIONS D-E5, D-7, D-8 — `plan`, the pure planner.
-- |
-- | `plan :: ValidatedDeployment -> WorldState -> Plan` is **total**: the
-- | tightening in `validate` already proved the graph acyclic and every edge
-- | resolved, so the planner can never trip over a cycle or a dangling ref.
-- | It diffs the *desired* deployment against *observed* runtime status and
-- | emits a reviewable, staged changeset — never an imperative one-pass
-- | reconcile.
-- |
-- | Three-way state (D-7, Terraform): `WorldState` carries `desired`,
-- | `recorded` (Bosun's last-known snapshot) and `observed` (what sync probes
-- | see now). The MVP planner derives each service's change from `observed`
-- | (and proposes `Start` for anything desired-but-unseen); `recorded` is
-- | threaded through for design fidelity and the future verifying-traces
-- | hash-comparison (D-8), which is post-MVP — it is not consulted yet.
-- |
-- | `Status` is a rich enum, not a boolean (PRINCIPLES.md): `InBackoff` is the
-- | "launchd ThrottleInterval looks dead for ~40s" gotcha (don't double-restart
-- | it); `CompletedOk` is success for a one-shot, not "down"; `Unknown` carries
-- | a `Reason` and is never silently coerced to `Down`.
-- |
-- | Stop/restart propagation (D-E5): a `Stop`, or an observed `Failed` (which
-- | the base pass turns into `Restart … Crashed`), propagates *backward* along
-- | reverse `BindsTo`/`PartOf` edges as a transitive closure. It terminates by
-- | acyclicity — and, here, also by monotone `severity` (a service's change
-- | only ever escalates), so the fixpoint is doubly guaranteed to converge.
module Bosun.Plan
  ( Status(..)
  , Reason(..)
  , Snapshot
  , WorldState
  , Change(..)
  , Plan(..)
  , PlanStep
  , plan
  , planSteps
  , changeRef
  , severity
  , baseChange
  ) where

import Prelude

import Bosun.Atoms (ServiceId)
import Bosun.Edge (Requirement(..))
import Bosun.Service
  ( Service, ServiceRef, ValidatedDeployment
  , unBootOrder, unServiceRef, unValidatedDeployment
  )
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Foldable (foldr)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))

-- ── observed reality ─────────────────────────────────────────────────────────

-- | What a synchronous probe (or the lack of one) reports about a service.
-- | `Unknown` is first-class: a probe that *couldn't tell* is not the same as
-- | `Down`, and conflating them would have the planner restart something that
-- | is fine (PRINCIPLES.md, the observation edge).
data Status
  = Running          -- live and ready
  | Starting         -- coming up; leave it alone
  | InBackoff        -- restart-throttled (looks dead ~40s); do NOT pile on
  | Failed           -- crashed / unhealthy
  | Down             -- not running
  | CompletedOk      -- one-shot succeeded (an OnCompleted gate is satisfied)
  | Unknown Reason   -- the probe couldn't determine status
derive instance Eq Status

-- | Why a `Restart` is proposed, or why a `Status` is `Unknown`. Closed
-- | program-logic alternatives (the recompile-test rule): a new way to need a
-- | restart is a code change, not user data.
data Reason
  = Crashed                       -- observed Failed
  | SpecChanged                   -- desired ≠ recorded (reserved for D-8 traces)
  | DependencyRestarted ServiceId -- PartOf propagation: an upstream restarted
  | ProbeUnreachable String       -- the observation edge couldn't reach the probe
derive instance Eq Reason

-- | A point-in-time reading of the rig. Absent ⇒ "not observed" ⇒ treated as
-- | `Down` by the planner (propose `Start`).
type Snapshot = Map ServiceId Status

-- | Three typed values, not two (D-7). `recorded` is reserved for the
-- | verifying-traces pass (D-8) and not yet consulted.
type WorldState =
  { desired  :: ValidatedDeployment
  , recorded :: Maybe Snapshot
  , observed :: Snapshot
  }

-- ── the plan ─────────────────────────────────────────────────────────────────

-- | A reviewable, typed change. `ServiceRef` (mintable only by `validate`)
-- | guarantees every change names a service that is actually in the validated
-- | deployment — D-E5 Stop-propagation only ever touches desired services, so
-- | this stays honest (spec-removal teardown, which would need un-validated
-- | refs, is post-MVP).
data Change
  = Start   ServiceRef
  | Restart ServiceRef Reason
  | NoOp    ServiceRef
  | Stop    ServiceRef
derive instance Eq Change

changeRef :: Change -> ServiceRef
changeRef = case _ of
  Start r -> r
  Restart r _ -> r
  NoOp r -> r
  Stop r -> r

-- | Escalation order. Propagation only ever raises a service's change to a
-- | higher severity, which makes the closure monotone (hence terminating).
severity :: Change -> Int
severity = case _ of
  NoOp _ -> 0
  Start _ -> 1
  Restart _ _ -> 2
  Stop _ -> 3

-- | One staged change. `apply` groups by ascending `stage`; ties within a
-- | stage are independent (the Go-`errgroup` concurrency seam).
type PlanStep = { stage :: Int, change :: Change }

newtype Plan = Plan (Array PlanStep)

planSteps :: Plan -> Array PlanStep
planSteps (Plan ss) = ss

-- | The base change for one service from its observed status, before
-- | propagation. `Starting`/`InBackoff`/`Unknown` are deliberately `NoOp`:
-- | the rig is mid-transition or we can't tell, and acting would do harm.
baseChange :: ServiceRef -> Status -> Change
baseChange ref = case _ of
  Running     -> NoOp ref
  CompletedOk -> NoOp ref
  Starting    -> NoOp ref
  InBackoff   -> NoOp ref
  Failed      -> Restart ref Crashed
  Down        -> Start ref
  Unknown _   -> NoOp ref

plan :: ValidatedDeployment -> WorldState -> Plan
plan vd world = Plan (A.sortWith _.stage steps)
  where
  vr = unValidatedDeployment vd

  -- Every service's canonical `ServiceRef` and boot stage come straight from
  -- the proven `BootOrder` (no need to re-mint refs — and we couldn't, the
  -- minter is private to `validate`).
  staged :: Array (Tuple Int ServiceRef)
  staged = A.concat
    (A.mapWithIndex (\i nea -> map (Tuple i) (NEA.toArray nea)) (unBootOrder vr.bootOrder))

  nStages :: Int
  nStages = A.length (unBootOrder vr.bootOrder)

  stageOf :: Map ServiceId Int
  stageOf = Map.fromFoldable (map (\(Tuple i ref) -> Tuple (unServiceRef ref) i) staged)

  observedOf :: ServiceId -> Status
  observedOf sid = fromMaybe Down (Map.lookup sid world.observed)

  -- canonical ref per service id, for propagation targets
  refOf :: Map ServiceId ServiceRef
  refOf = Map.fromFoldable (map (\(Tuple _ ref) -> Tuple (unServiceRef ref) ref) staged)

  base :: Map ServiceId Change
  base = Map.fromFoldable
    (staged # map \(Tuple _ ref) ->
       Tuple (unServiceRef ref) (baseChange ref (observedOf (unServiceRef ref))))

  propagated :: Map ServiceId Change
  propagated = fixpoint (propagateStep (reverseIndex vr.services) refOf) base

  steps :: Array PlanStep
  steps = (Map.toUnfoldable propagated :: Array (Tuple ServiceId Change))
    # map \(Tuple sid change) ->
        { stage: stageFor change (fromMaybe 0 (Map.lookup sid stageOf)), change }

  -- Stops run first, in *reverse* boot order (tear down dependents before what
  -- they depend on); starts/restarts/noops follow, in boot order. One ascending
  -- Int axis: stops occupy [0, nStages), the rest [nStages, 2·nStages).
  stageFor :: Change -> Int -> Int
  stageFor change s = case change of
    Stop _ -> (nStages - 1) - s
    _ -> nStages + s

-- | Reverse dependency index: for each upstream `X`, the `(Y, requirement)`
-- | pairs of services `Y` that depend on it. The substrate for D-E5's backward
-- | Stop/Restart propagation.
reverseIndex
  :: Map ServiceId Service
  -> Map ServiceId (Array (Tuple ServiceId (Maybe Requirement)))
reverseIndex svcs =
  foldr insertDeps Map.empty (Map.toUnfoldable svcs :: Array (Tuple ServiceId Service))
  where
  insertDeps (Tuple yid svc) acc =
    foldr (\d -> Map.insertWith (<>) (unServiceRef d.to) [ Tuple yid d.requirement ]) acc svc.deps

-- | One propagation pass (D-E5). For every service `X` whose current change
-- | warrants it, escalate its reverse-`BindsTo`/`PartOf` dependents:
-- |
-- |   * `Stop(X)`            → BindsTo & PartOf dependents `Stop`.
-- |   * `Restart(X) Crashed` → BindsTo dependents `Stop` (X failed unexpectedly,
-- |     so the crash-coupled go down), PartOf dependents `Restart`.
-- |   * other `Restart(X)`   → PartOf dependents `Restart` (a propagated restart
-- |     is not a failure, so it does not crash-couple).
-- |
-- | Each escalation only takes effect if it raises the dependent's `severity`,
-- | so iterating to a fixpoint converges.
propagateStep
  :: Map ServiceId (Array (Tuple ServiceId (Maybe Requirement)))
  -> Map ServiceId ServiceRef
  -> Map ServiceId Change
  -> Map ServiceId Change
propagateStep rev refs m =
  foldr propagateFrom m (Map.toUnfoldable m :: Array (Tuple ServiceId Change))
  where
  propagateFrom (Tuple xid cx) acc =
    foldr (applyEffect xid cx) acc (fromMaybe [] (Map.lookup xid rev))

  applyEffect xid cx (Tuple yid req) acc =
    case effect xid cx req, Map.lookup yid refs of
      Just mk, Just yref -> bump yid (mk yref) acc
      _, _ -> acc

  effect :: ServiceId -> Change -> Maybe Requirement -> Maybe (ServiceRef -> Change)
  effect xid cx = case _ of
    Just BindsTo -> case cx of
      Stop _ -> Just Stop
      Restart _ Crashed -> Just Stop
      _ -> Nothing
    Just PartOf -> case cx of
      Stop _ -> Just Stop
      Restart _ _ -> Just \yref -> Restart yref (DependencyRestarted xid)
      _ -> Nothing
    _ -> Nothing

  bump yid newC acc = case Map.lookup yid acc of
    Just oldC | severity newC > severity oldC -> Map.insert yid newC acc
    _ -> acc

-- | Iterate a step to a fixpoint. Safe here: `propagateStep` is monotone in
-- | `severity` over a finite service set, so it reaches a fixed point.
fixpoint :: forall a. Eq a => (a -> a) -> a -> a
fixpoint f x = let x' = f x in if x' == x then x else fixpoint f x'
