-- | DESIGN §4 / DECISIONS D-E5 — `plan` as example tests + properties.
-- |
-- | Examples pin the base status→change mapping and the two backward-
-- | propagation rules (BindsTo crash-coupling, PartOf reverse-lifecycle).
-- | Properties (reusing the legal-by-construction generator from `PBTSpec`)
-- | pin **convergence**: an all-running rig yields no changes; an unseen rig
-- | yields exactly one `Start` per service.
module Test.Bosun.PlanSpec where

import Prelude

import Bosun.Atoms (mkServiceId)
import Bosun.Edge (Requirement(..))
import Bosun.Plan
  ( Change(..), Plan, Reason(..), Snapshot, Status(..), WorldState
  , changeRef, plan, planSteps, severity
  )
import Bosun.Service
  ( Deployment, LooseDep, ValidatedDeployment
  , deploymentServices, mkDeployment, unServiceRef
  )
import Bosun.Validate (validate)
import Data.Array (all, filter, find, length, null)
import Data.Either (Either(..))
import Data.Foldable (maximum, minimum)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect.Aff (Aff)
import Test.Bosun.PBTSpec (genLegal)
import Test.Bosun.ValidateSpec (leaf)
import Test.QuickCheck (Result, (<?>))
import Test.QuickCheck.Gen (Gen)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Spec.QuickCheck (quickCheck)

-- ── builders ────────────────────────────────────────────────────────────────

dep :: Requirement -> String -> LooseDep
dep req name = { to: mkServiceId name, ordering: Nothing, requirement: Just req }

snap :: Array (Tuple String Status) -> Snapshot
snap = Map.fromFoldable <<< map (\(Tuple n st) -> Tuple (mkServiceId n) st)

worldOf :: ValidatedDeployment -> Snapshot -> WorldState
worldOf vd obs = { desired: vd, recorded: Nothing, observed: obs }

changeFor :: String -> Plan -> Maybe Change
changeFor name p =
  map _.change (find (\s -> unServiceRef (changeRef s.change) == mkServiceId name) (planSteps p))

-- run `f` against the plan of a fixture that must validate
withPlan :: Deployment -> Snapshot -> (Plan -> Aff Unit) -> Aff Unit
withPlan d obs f = case toEither (validate d) of
  Left _ -> fail "fixture was expected to validate"
  Right vd -> f (plan vd (worldOf vd obs))

-- ── the suite ──────────────────────────────────────────────────────────────────

spec :: Spec Unit
spec = describe "Bosun.Plan" do

  describe "base status -> change" do

    it "unseen / down service -> Start" $
      withPlan (mkDeployment [ leaf "a" ]) (snap []) \p ->
        case changeFor "a" p of
          Just (Start _) -> pure unit
          _ -> fail "expected Start for an unseen service"

    it "running service -> NoOp (nothing to do)" $
      withPlan (mkDeployment [ leaf "a" ]) (snap [ Tuple "a" Running ]) \p ->
        null (filter (\s -> severity s.change /= 0) (planSteps p)) `shouldEqual` true

    it "failed service -> Restart (crashed)" $
      withPlan (mkDeployment [ leaf "a" ]) (snap [ Tuple "a" Failed ]) \p ->
        case changeFor "a" p of
          Just (Restart _ Crashed) -> pure unit
          _ -> fail "expected Restart … Crashed for a Failed service"

    it "InBackoff -> NoOp (the ~40s ThrottleInterval gotcha; don't double-restart)" $
      withPlan (mkDeployment [ leaf "a" ]) (snap [ Tuple "a" InBackoff ]) \p ->
        null (filter (\s -> severity s.change /= 0) (planSteps p)) `shouldEqual` true

  describe "D-E5 backward propagation" do

    it "BindsTo: dependent of a Failed upstream is Stopped" $
      let x = leaf "x"
          y = (leaf "y") { deps = [ dep BindsTo "x" ] }
      in withPlan (mkDeployment [ x, y ]) (snap [ Tuple "x" Failed, Tuple "y" Running ]) \p ->
        case changeFor "y" p of
          Just (Stop _) -> pure unit
          _ -> fail "expected y (BindsTo a Failed x) to be Stopped"

    it "PartOf: dependent of a Restarted upstream is Restarted (dependency reason)" $
      let x = leaf "x"
          y = (leaf "y") { deps = [ dep PartOf "x" ] }
      in withPlan (mkDeployment [ x, y ]) (snap [ Tuple "x" Failed, Tuple "y" Running ]) \p ->
        case changeFor "y" p of
          Just (Restart _ (DependencyRestarted sid)) -> sid `shouldEqual` mkServiceId "x"
          _ -> fail "expected y (PartOf a Restarted x) to be Restarted"

    it "stops are staged before starts/restarts (reverse boot order first)" $
      let x = leaf "x"
          y = (leaf "y") { deps = [ dep BindsTo "x" ] }
      in withPlan (mkDeployment [ x, y ]) (snap [ Tuple "x" Failed, Tuple "y" Running ]) \p -> do
        let stops = filter (\s -> severity s.change == 3) (planSteps p)
            others = filter (\s -> let v = severity s.change in v > 0 && v < 3) (planSteps p)
        case maximum (map _.stage stops), minimum (map _.stage others) of
          Just hiStop, Just loOther -> (hiStop < loOther) `shouldEqual` true
          _, _ -> fail "expected both a stop and a start/restart in this plan"

  describe "convergence (property-based, reusing genLegal)" do

    it "an all-running rig yields no changes (plan is a fixpoint there)" $
      quickCheck prop_convergeRunning

    it "an unseen rig yields exactly one Start per service" $
      quickCheck prop_unseenAllStart

-- ── properties ─────────────────────────────────────────────────────────────────

-- Everything Running ⇒ every base change is NoOp and nothing propagates.
prop_convergeRunning :: Gen Result
prop_convergeRunning = do
  d <- genLegal 1
  pure case toEither (validate d) of
    Left _ -> false <?> "a legal-by-construction deployment failed validation"
    Right vd ->
      let
        obs = Map.fromFoldable (map (\s -> Tuple s.id Running) (deploymentServices d))
        changes = map _.change (planSteps (plan vd (worldOf vd obs)))
      in null (filter (\c -> severity c /= 0) changes)
           <?> "an all-running rig should yield no changes"

-- Nothing observed ⇒ exactly one Start per desired service.
prop_unseenAllStart :: Gen Result
prop_unseenAllStart = do
  d <- genLegal 1
  pure case toEither (validate d) of
    Left _ -> false <?> "a legal-by-construction deployment failed validation"
    Right vd ->
      let
        changes = map _.change (planSteps (plan vd (worldOf vd Map.empty)))
        n = length (deploymentServices d)
      in (length changes == n && all (\c -> severity c == 1) changes)
           <?> "an unseen rig should be all-Start, one per service"
