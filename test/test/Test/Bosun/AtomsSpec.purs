module Test.Bosun.AtomsSpec where

import Prelude

import Bosun.Atoms (mkAbsPath, mkPort, unAbsPath, unPort)
import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- | Phase 1 reality-check: the refined atoms reject the illegal and admit the
-- | legal — the front line of MISU (DESIGN §3.1).
spec :: Spec Unit
spec = describe "Bosun.Atoms" do
  describe "mkPort (1..65535)" do
    it "rejects 0 (below range)" do
      mkPort 0 `shouldEqual` Nothing
    it "rejects 65536 (above range)" do
      mkPort 65536 `shouldEqual` Nothing
    it "rejects negatives" do
      mkPort (-1) `shouldEqual` Nothing
    it "admits the boundaries 1 and 65535" do
      map unPort (mkPort 1) `shouldEqual` Just 1
      map unPort (mkPort 65535) `shouldEqual` Just 65535
    it "admits a typical port" do
      map unPort (mkPort 3000) `shouldEqual` Just 3000

  describe "mkAbsPath (leading '/')" do
    it "rejects the SDI footgun 'node router.mjs' — no cd /abs anchor" do
      mkAbsPath "node router.mjs" `shouldEqual` Nothing
    it "rejects a relative path" do
      mkAbsPath "minard/server" `shouldEqual` Nothing
    it "rejects the empty string" do
      mkAbsPath "" `shouldEqual` Nothing
    it "admits an absolute path" do
      map unAbsPath (mkAbsPath "/Users/afc/work") `shouldEqual` Just "/Users/afc/work"
