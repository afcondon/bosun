-- | ADDRESS-TYPE.md — the `Reachability`/`Address`/`BindScope` experiment.
-- |
-- | These tests pin the three claims the proposal must make good on:
-- |   1. `classify` reproduces the old `Exposure` sum exactly (§3 table) — so
-- |      every pass-through consumer is genuinely behaviour-preserving.
-- |   2. The new axes carry real information: bind scope distinguishes
-- |      `0.0.0.0` from `127.0.0.1` (gap 1), and `openness` grades the spectrum.
-- |   3. Composition (`Set Address`) is LOAD-BEARING — it catches a collision
-- |      the singular `Exposure` literally could not represent (§9 falsifier 4
-- |      rebuttal), and `Set` dedups identical addresses for free (§5).
module Test.Bosun.ReachabilitySpec where

import Prelude

import Bosun.Atoms (Host, Port, mkHost, mkPort, mkServiceId)
import Bosun.Error (DeployError(..))
import Bosun.Executor (Executor(..))
import Bosun.Health (Probe(..), defaultRestart)
import Bosun.Reachability
  ( Address(..), BindScope(..), Openness(..), Reachability(..)
  , addresses, classify, hostPort, internalPort, loopbackPort, maxOpenness, noNetwork, openness
  )
import Bosun.Reconcile (exposureLabel)
import Bosun.Service (LooseService, mkDeployment)
import Bosun.Validate (validate)
import Data.Array (any)
import Data.Either (either)
import Data.Maybe (Maybe(..), fromJust)
import Data.Set as Set
import Data.Validation.Semigroup (V, toEither)
import Partial.Unsafe (unsafePartial)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

-- compare an Exposure by its documented label (Exposure has no Show instance)
label :: Reachability -> String
label = exposureLabel <<< classify

errsOf :: forall a. V (Array DeployError) a -> Array DeployError
errsOf = either identity (const []) <<< toEither

isPortCollision :: DeployError -> Boolean
isPortCollision = case _ of
  PortCollision _ _ _ -> true
  _ -> false

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

-- a service publishing several host ports — unrepresentable under old `Exposure`
publishing :: String -> Host -> Array Port -> LooseService
publishing name h ports = (leaf name)
  { host = Just h
  , reachability = Reachability (Set.fromFoldable (map (\p -> Listening { bind: AllIfaces, port: p }) ports))
  }

spec :: Spec Unit
spec = describe "Bosun.Reachability" do

  describe "classify reproduces the old Exposure sum (§3 mapping table)" do
    it "AllIfaces listener -> HostPort label" do
      label (hostPort (port_ 3000)) `shouldEqual` "host:3000"
    it "Internal listener -> InternalPort label" do
      label (internalPort (port_ 3000)) `shouldEqual` "internal:3000"
    it "Loopback listener -> InternalPort label (not host-published)" do
      label (loopbackPort (port_ 3000)) `shouldEqual` "internal:3000"
    it "empty reachability -> NoNetwork label" do
      label noNetwork `shouldEqual` "none"
    it "a composite collapses to its MOST-exposed member (lossy, by design)" do
      -- internal:5432 AND host:8080 -> the host port wins the projection
      let r = Reachability (Set.fromFoldable
                [ Listening { bind: Internal, port: port_ 5432 }
                , Listening { bind: AllIfaces, port: port_ 8080 } ])
      label r `shouldEqual` "host:8080"

  describe "the new axes carry real information" do
    it "0.0.0.0 and 127.0.0.1 on the same port are DISTINCT addresses (gap 1)" do
      -- the headline gap: old HostPort 8080 could not tell these apart
      let r = Reachability (Set.fromFoldable
                [ Listening { bind: AllIfaces, port: port_ 8080 }
                , Listening { bind: Loopback, port: port_ 8080 } ])
      Set.size (addresses r) `shouldEqual` 2
    it "openness grades the spectrum Loopback < Internal < HostIface < AllIfaces < Published" do
      let ranked =
            [ openness (Listening { bind: Loopback, port: port_ 1 }) < openness (Listening { bind: Internal, port: port_ 1 })
            , openness (Listening { bind: Internal, port: port_ 1 }) < openness (Listening { bind: HostIface (mkHost "mbp"), port: port_ 1 })
            , openness (Listening { bind: HostIface (mkHost "mbp"), port: port_ 1 }) < openness (Listening { bind: AllIfaces, port: port_ 1 })
            ]
      any identity (map not ranked) `shouldEqual` false   -- all strictly increasing
    it "maxOpenness of a composite is its widest member" do
      let r = Reachability (Set.fromFoldable
                [ Listening { bind: Loopback, port: port_ 1 }
                , Listening { bind: AllIfaces, port: port_ 2 } ])
      (maxOpenness r == WideOpen) `shouldEqual` true
    it "maxOpenness of no-network is NoneOpen" do
      (maxOpenness noNetwork == NoneOpen) `shouldEqual` true

  describe "Set dedups identical addresses for free (§5 gained-back)" do
    it "two identical listeners collapse to one address" do
      let r = Reachability (Set.fromFoldable
                [ Listening { bind: AllIfaces, port: port_ 3000 }
                , Listening { bind: AllIfaces, port: port_ 3000 } ])
      Set.size (addresses r) `shouldEqual` 1

  describe "composition is load-bearing for validate (§9 falsifier 4 rebuttal)" do
    let mbp = mkHost "mbp"
    it "a service's SECOND published port still collides — old Exposure could not see it" do
      let a = publishing "a" mbp [ port_ 8080, port_ 5432 ]   -- two host ports
          b = publishing "b" mbp [ port_ 5432 ]               -- contends on 5432
      any isPortCollision (errsOf (validate (mkDeployment [ a, b ]))) `shouldEqual` true
    it "control: with only the first port modelled there is NO collision" do
      let a = publishing "a" mbp [ port_ 8080 ]               -- the old single-value view
          b = publishing "b" mbp [ port_ 5432 ]
      any isPortCollision (errsOf (validate (mkDeployment [ a, b ]))) `shouldEqual` false
    it "loopback/internal binds do not contend for the host's published ports" do
      -- consistent with the OLD InternalPort (which never collided); the richer
      -- type now makes a same-host loopback contention FIXABLE, but that is a
      -- pre-existing imprecision, deliberately not changed here.
      let a = (leaf "a") { host = Just mbp, reachability = loopbackPort (port_ 9000) }
          b = (leaf "b") { host = Just mbp, reachability = loopbackPort (port_ 9000) }
      any isPortCollision (errsOf (validate (mkDeployment [ a, b ]))) `shouldEqual` false
