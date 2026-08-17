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

import Bosun.Atoms (AbsPath, ServiceId, mkAbsPath, mkHost, unPort, unServiceId)
import Bosun.Edge (Requirement(..), Gate(..))
import Bosun.Error (DeployError)
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Reachability (classify, hostPort, noNetwork)
import Bosun.Health (Probe(..))
import Bosun.Serve (PortClaim, internalOffset, planDrift, serveDiff, servePlan)
import Bosun.Service (Deployment, LooseDep, LooseService, deploymentServices, mkDeployment, unBootOrder, unServiceRef, unValidatedDeployment)
import Bosun.Validate (validate)
import Data.Array (all, filter, length, mapMaybe, mapWithIndex, modifyAt, range, zip)
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Foldable (any)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, fromMaybe)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Data.Validation.Semigroup (isValid, toEither)
import Partial.Unsafe (unsafePartial)
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
      , reachability = hostPort (port_ (3000 + i))
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
  collide s = s { host = Just (mkHost "collide"), reachability = hostPort (port_ 9999) }

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

-- ── serve admission, property-based (STRESS-TEST-PLAN §1) ────────────────────

-- | A registry of 1..8 services, each one of six kinds spanning every `admit`
-- | branch — so all three buckets (route / redirect / reject) get populated and
-- | the partition properties bite. Distinct public port per service (keeps the
-- | port-keyed `serveDiff` well-defined). No rule-knowledge in the generator: it
-- | just emits shapes; `servePlan` does the classifying.
genServeRegistry :: Gen Deployment
genServeRegistry = do
  n <- chooseInt 1 8
  svcs <- traverse serveSvc (range 0 (n - 1))
  pure (mkDeployment svcs)

serveSvc :: Int -> Gen LooseService
serveSvc i = build <$> chooseInt 0 5
  where
  name = "s" <> show i
  port = 3000 + i
  proc h cmd = (leaf name)
    { host = Just (mkHost h)
    , reachability = hostPort (port_ port)
    , launch = { executor: Process { cwd: absPath ("/srv/" <> name), command: cmd, env: [] }, localName: name, artifact: Nothing }
    }
  build = case _ of
    0 -> proc "mbp" ("run -p " <> show port)                 -- ADMIT (local, port in cmd)
    1 -> proc "macmini" ("run -p " <> show port)             -- REDIRECT (remote)
    2 -> proc "mbp" "run without a numeric flag"             -- REJECT (port not in command)
    3 -> (leaf name) { host = Just (mkHost "mbp"), reachability = hostPort (port_ port) } -- REJECT (Unmanaged ⇒ no abs cwd)
    4 -> (proc "mbp" ("run -p " <> show port)) { reachability = noNetwork }               -- REJECT (no host port)
    _ -> (leaf name)
      { host = Just (mkHost "mbp")
      , reachability = hostPort (port_ port)
      , launch = { executor: Container (ContainerSpec { source: Left (ImageRef name), internalPort: Nothing, publish: Nothing }), localName: name, artifact: Nothing }
      } -- REJECT (not a Process)

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

-- every service lands in exactly one bucket
prop_servePartition :: Gen Result
prop_servePartition = do
  dep <- genServeRegistry
  let p = servePlan dep
  pure ((length p.routes + length p.redirects + length p.rejected == length (deploymentServices dep))
    <?> "servePlan partition did not cover every service exactly once")

-- every admitted route moved its backend to public+offset and the rewrite landed
prop_rewriteLanded :: Gen Result
prop_rewriteLanded = do
  dep <- genServeRegistry
  let p = servePlan dep
  pure (all sound p.routes <?> "an admitted route's port rewrite did not land")
  where
  sound r = r.internalPort == r.publicPort + internalOffset
    && String.contains (Pattern (show r.internalPort)) r.launchCommand

-- every redirect points at a tailnet URL carrying its public port
prop_redirectFormat :: Gen Result
prop_redirectFormat = do
  dep <- genServeRegistry
  let p = servePlan dep
  pure (all ok p.redirects <?> "a redirect target was not a well-formed URL")
  where
  ok d = String.contains (Pattern "http://") d.target
    && String.contains (Pattern (show d.publicPort)) d.target

-- diffing a plan against itself is a no-op (reflexive)
prop_diffReflexive :: Gen Result
prop_diffReflexive = do
  dep <- genServeRegistry
  let p = servePlan dep
      d = serveDiff p p
  pure ((length d.unbind == 0 && length d.bindRoutes == 0 && length d.bindRedirects == 0)
    <?> "serveDiff of a plan against itself was not empty")

-- applying serveDiff old→new to old's bound port-set yields new's port-set
prop_diffComplete :: Gen Result
prop_diffComplete = do
  oldP <- servePlan <$> genServeRegistry
  newP <- servePlan <$> genServeRegistry
  let
    d = serveDiff oldP newP
    bound = Set.fromFoldable (map _.publicPort d.bindRoutes <> map _.publicPort d.bindRedirects)
    applied = Set.union (Set.difference (boundPorts oldP) (Set.fromFoldable d.unbind)) bound
  pure ((applied == boundPorts newP) <?> "applying serveDiff did not reproduce the new port-set")
  where
  boundPorts p = Set.fromFoldable (map _.publicPort p.routes <> map _.publicPort p.redirects)

-- The property that makes the drift indicator trustworthy: a reload FIXES it.
-- Whatever two plans you compare, the router that has re-planned from the fresh
-- registry is in agreement with it — so "drift" can never be a state the
-- offered remedy fails to clear.
prop_driftClearedByReplan :: Gen Result
prop_driftClearedByReplan = do
  dep <- genServeRegistry
  let fresh = servePlan dep
  -- a reload replaces the held plan with `fresh`; agreement is then reflexivity.
  -- The claims are the generator's own services, so every claimed port has a
  -- verdict and nothing shows as Unaccounted either.
  pure ((length (planDrift (claimsOf dep) fresh fresh) == 0)
    <?> "drift survived re-planning from the fresh registry")

-- Drift is strictly WIDER than serveDiff: every port serveDiff would touch is a
-- drifting port. (Not the converse — a row whose refusal reason changed drifts
-- without any bind changing, which is the case serveDiff is blind to.)
prop_driftCoversDiff :: Gen Result
prop_driftCoversDiff = do
  oldP <- servePlan <$> genServeRegistry
  newP <- servePlan <$> genServeRegistry
  let
    d = serveDiff oldP newP
    touched = Set.fromFoldable (d.unbind <> map _.publicPort d.bindRoutes <> map _.publicPort d.bindRedirects)
    drifting = Set.fromFoldable (map _.publicPort (planDrift [] oldP newP))
  pure (Set.subset touched drifting <?> "a port serveDiff would rebind was not reported as drift")

-- The claims `registryClaims` would return for a generated deployment: every
-- service's canonical id and the port it asks for.
claimsOf :: Deployment -> Array PortClaim
claimsOf dep = mapMaybe claim (deploymentServices dep)
  where
  claim s = case classify s.reachability of
    HostPort p -> Just { serviceId: unServiceId s.id, publicPort: unPort p }
    _ -> Nothing

-- ── the suite ─────────────────────────────────────────────────────────────────

spec :: Spec Unit
spec = do
  describe "Bosun.Validate (property-based)" do
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
  describe "Bosun.Serve (property-based)" do
    it "servePlan partitions every service exactly once" $
      quickCheck prop_servePartition
    it "admitted routes rewrite public→internal and the rewrite lands in the command" $
      quickCheck prop_rewriteLanded
    it "redirects carry a well-formed tailnet URL" $
      quickCheck prop_redirectFormat
    it "serveDiff is reflexive (a plan vs itself is empty)" $
      quickCheck prop_diffReflexive
    it "applying serveDiff old→new reproduces the new port-set (completeness)" $
      quickCheck prop_diffComplete
    it "planDrift is cleared by re-planning (the offered remedy always works)" $
      quickCheck prop_driftClearedByReplan
    it "planDrift covers every port serveDiff would rebind (and more)" $
      quickCheck prop_driftCoversDiff
