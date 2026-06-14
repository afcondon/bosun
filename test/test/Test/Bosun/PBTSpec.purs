-- | SCENARIOS.md §G — the property-based companion to the example corpus.
-- |
-- | The decisive choice (§G): **generate a legal deployment by construction**,
-- | so the generator carries no rule-knowledge it could get wrong — the types
-- | are the spec. `genLegal` builds a DAG (deps only point at lower indices),
-- | gives every node a readiness probe (so gates are checkable) and a distinct
-- | host:port (so there are no collisions). The properties then either confirm
-- | `validate` accepts it, or apply one small typed **fault injector** and
-- | assert the *specific* error — B1/B2/B3/B5 generalised from examples to
-- | populations. Each injector is individually trivial (the antithesis of a
-- | monolithic `Arbitrary`).
module Test.Bosun.PBTSpec where

import Prelude

import Bosun.Atoms (ServiceId, mkHost)
import Bosun.Edge (Requirement(..), Gate(..))
import Bosun.Error (DeployError)
import Bosun.Exposure (Exposure(..))
import Bosun.Health (Probe(..))
import Bosun.Service (Deployment, LooseDep, LooseService, deploymentServices, mkDeployment, unBootOrder, unServiceRef, unValidatedDeployment)
import Bosun.Validate (validate)
import Data.Array (all, filter, length, mapWithIndex, modifyAt, range, zip)
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Foldable (any)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Data.Validation.Semigroup (isValid, toEither)
import Test.Bosun.ValidateSpec
  ( errsOf, isDangling, isDependencyCycle, isPortCollision, isUncheckableGate
  , leaf, port_, requires, requiresGate
  )
import Test.QuickCheck (Result, (<?>))
import Test.QuickCheck.Arbitrary (arbitrary)
import Test.QuickCheck.Gen (Gen, chooseInt, vectorOf)
import Test.Spec (Spec, describe, it)
import Test.Spec.QuickCheck (quickCheck)

-- ── the legal-by-construction generator ─────────────────────────────────────

-- | A legal deployment of `minN..6` services. Service `i` may depend (via
-- | `Requires OnReady`) on any subset of services `0..i-1` — strictly lower
-- | indices, so the graph is acyclic by construction. Distinct host:port per
-- | node ⇒ no collisions; every node has a readiness probe ⇒ every gate is
-- | checkable.
genLegal :: Int -> Gen Deployment
genLegal minN = do
  n <- chooseInt minN 6
  svcs <- traverse genSvc (range 0 (n - 1))
  pure (mkDeployment svcs)
  where
  genSvc i = do
    -- NB: range 0 (-1) == [0,-1] (range counts downward), so guard i == 0,
    -- else s0 would gain a self-dep (cycle) and a dep on "s-1" (dangling).
    targets <- if i == 0 then pure [] else genSubset (range 0 (i - 1))
    pure ((leaf ("s" <> show i))
      { host = Just (mkHost "gen")
      , exposure = HostPort (port_ (3000 + i))
      , readiness = TcpConnect (port_ (4000 + i))
      , deps = map (\j -> requiresGate OnReady ("s" <> show j)) targets
      })

genSubset :: forall a. Array a -> Gen (Array a)
genSubset xs = do
  flags <- vectorOf (length xs) (arbitrary :: Gen Boolean)
  pure (map snd (filter fst (zip flags xs)))

-- ── fault injectors (each introduces exactly one typed break) ────────────────

modifyService :: Int -> (LooseService -> LooseService) -> Deployment -> Deployment
modifyService i f dep =
  let svcs = deploymentServices dep
  in mkDeployment (fromMaybe svcs (modifyAt i f svcs))

addDep :: LooseDep -> LooseService -> LooseService
addDep d s = s { deps = s.deps <> [ d ] }

-- s0 ⇄ s1 (mutual Requires) ⇒ a 2-cycle  (needs minN = 2)
injectBackEdge :: Deployment -> Deployment
injectBackEdge =
  modifyService 0 (addDep (requires "s1")) <<< modifyService 1 (addDep (requires "s0"))

-- s0 Requires an absent service ⇒ DanglingDependency
injectDangle :: Deployment -> Deployment
injectDangle = modifyService 0 (addDep (requires "ghost-zzz"))

-- s0 and s1 forced onto the same host:port ⇒ PortCollision  (needs minN = 2)
injectCollide :: Deployment -> Deployment
injectCollide = modifyService 0 collide <<< modifyService 1 collide
  where
  collide s = s { host = Just (mkHost "collide"), exposure = HostPort (port_ 9999) }

-- s0 Requires(OnReady) s1, but s1's readiness is stripped ⇒ UncheckableGate  (needs minN = 2)
injectDropGatedProbe :: Deployment -> Deployment
injectDropGatedProbe =
  modifyService 0 (addDep (requiresGate OnReady "s1")) <<< modifyService 1 (\s -> s { readiness = NoProbe })

-- ── properties ───────────────────────────────────────────────────────────────

-- | The legal generator's range lies inside `validate`'s accepted set — the
-- | signal-box "every legal state is still reachable" coverage property.
prop_legalValidates :: Gen Result
prop_legalValidates = do
  dep <- genLegal 1
  pure (isValid (validate dep) <?> "a legal-by-construction deployment failed validation")

-- | Topological correctness: a hard dependency's boot stage strictly precedes
-- | its dependent's.
prop_topoCorrect :: Gen Result
prop_topoCorrect = do
  dep <- genLegal 1
  pure case toEither (validate dep) of
    Left _ -> false <?> "a legal-by-construction deployment failed validation"
    Right vd ->
      let
        stages = unBootOrder (unValidatedDeployment vd).bootOrder
        stageOf :: Map ServiceId Int
        stageOf = Map.fromFoldable do
          Tuple i stage <- mapWithIndex Tuple stages
          ref <- NEA.toArray stage
          pure (Tuple (unServiceRef ref) i)
        precedes from d = case d.requirement of
          Just (Requires _) -> lt d.to from
          Just BindsTo -> lt d.to from
          Just Requisite -> lt d.to from
          _ -> true
        lt earlier later = case Map.lookup earlier stageOf, Map.lookup later stageOf of
          Just a, Just b -> a < b
          _, _ -> true
        ok = all (\s -> all (precedes s.id) s.deps) (deploymentServices dep)
      in ok <?> "a dependency's boot stage did not precede its dependent's"

prop_inject :: Int -> (Deployment -> Deployment) -> (DeployError -> Boolean) -> String -> Gen Result
prop_inject minN inject isErr label = do
  dep <- genLegal minN
  pure (any isErr (errsOf (validate (inject dep))) <?> label)

-- ── the suite ─────────────────────────────────────────────────────────────────

spec :: Spec Unit
spec = describe "Bosun.Validate (property-based)" do
  it "legal-by-construction deployments validate (coverage)" $
    quickCheck prop_legalValidates
  it "hard deps precede their dependents in BootOrder (topological)" $
    quickCheck prop_topoCorrect
  it "addBackEdge -> DependencyCycle (B1 population)" $
    quickCheck (prop_inject 2 injectBackEdge isDependencyCycle "back edge did not produce a cycle")
  it "injectDangle -> DanglingDependency (B2 population)" $
    quickCheck (prop_inject 1 injectDangle isDangling "dangling dep was not caught")
  it "injectCollide -> PortCollision (B3 population)" $
    quickCheck (prop_inject 2 injectCollide isPortCollision "port collision was not caught")
  it "injectDropGatedProbe -> UncheckableGate (B5 population)" $
    quickCheck (prop_inject 2 injectDropGatedProbe isUncheckableGate "uncheckable gate was not caught")
