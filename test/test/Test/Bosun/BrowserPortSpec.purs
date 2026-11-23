-- | `Bosun.BrowserPort`: keep the registry off ports a browser may refuse.
module Test.Bosun.BrowserPortSpec where

import Prelude

import Bosun.BrowserPort (isBrowserBlocked, nextFreePort, portRefusal)
import Data.Array as A
import Data.Maybe (isJust, isNothing)
import Data.Set as Set
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = describe "Bosun.BrowserPort" do

  describe "the list" do
    it "holds the ports above 1024 that the Fetch standard names" do
      let fromSpec = [ 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566, 6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080 ]
      A.filter isBrowserBlocked fromSpec `shouldEqual` fromSpec
    it "does not hold the ports either side of them" do
      A.filter isBrowserBlocked [ 3658, 3660, 4189, 4191, 4195, 6664, 6670 ] `shouldEqual` []

  describe "nextFreePort (what /api/ports/suggest answers)" do
    it "skips 3659 when it is the next free port" do
      let used = Set.fromFoldable (A.range 3000 3658)
      nextFreePort 3000 used `shouldEqual` 3660
    it "skips a listed port and a used one in a row" do
      nextFreePort 4190 (Set.singleton 4191) `shouldEqual` 4192
    it "answers the first free port when none is listed" do
      nextFreePort 3000 (Set.fromFoldable [ 3000, 3001 ]) `shouldEqual` 3002

  describe "portRefusal (registration)" do
    it "refuses a listed port, whatever the row's role, and names the reason" do
      isJust (portRefusal 4190) `shouldEqual` true
      isJust (portRefusal 3659) `shouldEqual` true
    it "admits any other port" do
      isNothing (portRefusal 4195) `shouldEqual` true
      isNothing (portRefusal 57130) `shouldEqual` true
