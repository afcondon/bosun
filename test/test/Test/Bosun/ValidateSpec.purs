-- | The structural must-fail corpus B1–B6 (SCENARIOS.md §B) as example tests,
-- | plus the A2 happy path. Each B-scenario injects exactly one fault and
-- | asserts `validate` rejects it with the *specific* error; A2 asserts a
-- | clean three-stage boot order.
module Test.Bosun.ValidateSpec where

import Prelude

import Bosun.Atoms (Port, mkHost, mkPort, mkRoutePath, mkServiceId)
import Bosun.Edge (Gate(..), Requirement(..))
import Bosun.Error (DeployError(..))
import Bosun.Executor (Executor(..))
import Bosun.Reachability (hostPort, noNetwork)
import Bosun.Health (Probe(..), defaultRestart)
import Bosun.Selector (Selector(..))
import Bosun.Service (LooseDep, LooseRoute, LooseService, mkDeployment, unBootOrder, unValidatedDeployment)
import Bosun.Validate (validate)
import Data.Array (any, length)
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), fromJust)
import Data.Validation.Semigroup (V, toEither)
import Partial.Unsafe (unsafePartial)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- ── builders ────────────────────────────────────────────────────────────────

leaf :: String -> LooseService
leaf name =
  { id: mkServiceId name
  , host: Nothing
  , reachability: noNetwork
  , readiness: NoProbe
  , restart: defaultRestart
  , deps: []
  , routes: []
  , selectors: []
  , launch: { executor: Unmanaged ("test:" <> name), localName: name, artifact: Nothing }
  }

-- a pure ordering dep (OnStarted needs no readiness, so it never trips a gate)
requires :: String -> LooseDep
requires name = { to: mkServiceId name, ordering: Nothing, requirement: Just (Requires OnStarted) }

requiresGate :: Gate -> String -> LooseDep
requiresGate g name = { to: mkServiceId name, ordering: Nothing, requirement: Just (Requires g) }

routeTo :: String -> String -> LooseRoute
routeTo path name = { to: mkServiceId name, path: mkRoutePath path }

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

-- ── assertions ──────────────────────────────────────────────────────────────

errsOf :: forall a. V (Array DeployError) a -> Array DeployError
errsOf = either identity (const []) <<< toEither

isDependencyCycle :: DeployError -> Boolean
isDependencyCycle = case _ of
  DependencyCycle _ -> true
  _ -> false

isDangling :: DeployError -> Boolean
isDangling = case _ of
  DanglingDependency _ _ -> true
  _ -> false

isPortCollision :: DeployError -> Boolean
isPortCollision = case _ of
  PortCollision _ _ _ -> true
  _ -> false

isSelectorNotClosed :: DeployError -> Boolean
isSelectorNotClosed = case _ of
  SelectorNotClosed _ -> true
  _ -> false

isUncheckableGate :: DeployError -> Boolean
isUncheckableGate = case _ of
  UncheckableGate _ -> true
  _ -> false

isRouteWithoutBacking :: DeployError -> Boolean
isRouteWithoutBacking = case _ of
  RouteWithoutBacking _ -> true
  _ -> false

-- ── the corpus ──────────────────────────────────────────────────────────────

spec :: Spec Unit
spec = describe "Bosun.Validate" do

  describe "B. must-reject (each with its specific error)" do

    it "B1 dependency cycle -> DependencyCycle" do
      let a = (leaf "a") { deps = [ requires "b" ] }
          b = (leaf "b") { deps = [ requires "a" ] }
      any isDependencyCycle (errsOf (validate (mkDeployment [ a, b ]))) `shouldEqual` true

    it "B2 dangling dependency -> DanglingDependency" do
      let fe = (leaf "frontend") { deps = [ requires "bakend" ] }   -- typo, absent
      any isDangling (errsOf (validate (mkDeployment [ fe ]))) `shouldEqual` true

    it "B3 port collision (same host:port) -> PortCollision" do
      let s1 = (leaf "s1") { host = Just (mkHost "mbp"), reachability = hostPort (port_ 3000) }
          s2 = (leaf "s2") { host = Just (mkHost "mbp"), reachability = hostPort (port_ 3000) }
      any isPortCollision (errsOf (validate (mkDeployment [ s1, s2 ]))) `shouldEqual` true

    it "B3' same port, DIFFERENT host -> NOT a collision (facets, A8)" do
      let s1 = (leaf "s1") { host = Just (mkHost "mbp"), reachability = hostPort (port_ 3000) }
          s2 = (leaf "s2") { host = Just (mkHost "macmini"), reachability = hostPort (port_ 3000) }
      any isPortCollision (errsOf (validate (mkDeployment [ s1, s2 ]))) `shouldEqual` false

    it "B4 selector not closed under Requires -> SelectorNotClosed" do
      let fe = (leaf "frontend") { selectors = [ Profile "web" ], deps = [ requires "backend" ] }
          be = leaf "backend"   -- present, but NOT in profile web
      any isSelectorNotClosed (errsOf (validate (mkDeployment [ fe, be ]))) `shouldEqual` true

    it "B5 uncheckable gate (Requires OnHealthy, upstream NoProbe) -> UncheckableGate" do
      let api = (leaf "api") { deps = [ requiresGate OnHealthy "db" ] }
          db = leaf "db"   -- readiness NoProbe
      any isUncheckableGate (errsOf (validate (mkDeployment [ api, db ]))) `shouldEqual` true

    it "B6 route without backing -> RouteWithoutBacking" do
      let edge = (leaf "edge") { routes = [ routeTo "/sankey" "sankey" ] }   -- nothing serves it
      any isRouteWithoutBacking (errsOf (validate (mkDeployment [ edge ]))) `shouldEqual` true

  describe "A. happy path" do

    it "A2 three-tier frontend -> api -> db: valid, BootOrder = 3 stages" do
      let db = (leaf "db") { readiness = TcpConnect (port_ 5432) }
          api = (leaf "api") { readiness = TcpConnect (port_ 3000), deps = [ requiresGate OnReady "db" ] }
          fe = (leaf "frontend") { deps = [ requiresGate OnReady "api" ] }
      case toEither (validate (mkDeployment [ fe, api, db ])) of
        Left errs -> fail ("expected valid, got " <> show (length errs) <> " error(s)")
        Right vd -> length (unBootOrder (unValidatedDeployment vd).bootOrder) `shouldEqual` 3
