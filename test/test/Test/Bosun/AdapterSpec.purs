-- | The ingestion edge: parsing `startCommand` strings into `Executor`s, and
-- | decoding the registry `/api/ports` JSON into loose `ServiceInstance`s.
module Test.Bosun.AdapterSpec where

import Prelude

import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Adapters.StartCommand (parseStartCommand)
import Bosun.Atoms (unAbsPath)
import Bosun.Executor (Executor(..), ExecutorMechanism(..), mechanism)
import Bosun.Reconcile (exposureLabel)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (length)
import Data.Either (Either(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

spec :: Spec Unit
spec = describe "Bosun.Adapters" do

  describe "parseStartCommand" do
    it "parses 'cd /abs && cmd' into a Process with that cwd and command" do
      case parseStartCommand "cd /Users/afc/work/x && npx serve public -p 3013" of
        Process p -> do
          unAbsPath p.cwd `shouldEqual` "/Users/afc/work/x"
          p.command `shouldEqual` "npx serve public -p 3013"
        _ -> fail "expected a Process"

    it "keeps a multi-&& tail as the command" do
      case parseStartCommand "cd /a && make build && make start" of
        Process p -> p.command `shouldEqual` "make build && make start"
        _ -> fail "expected a Process"

    it "the SDI footgun 'node router.mjs' (no cd) is Unmanaged, not a Process" do
      case parseStartCommand "node router.mjs" of
        Unmanaged _ -> pure unit
        _ -> fail "expected Unmanaged (no absolute cwd anchor)"

    it "an empty/NULL command is Unmanaged" do
      case parseStartCommand "" of
        Unmanaged _ -> pure unit
        _ -> fail "expected Unmanaged"

  describe "ingestRegistry" do
    let
      fixture =
        """{"servers":[
          {"role":"frontend","projectSlug":"urj","projectName":"tilted-radio","port":3013,"host":"mbp","startCommand":"cd /x && npx serve"},
          {"role":"api","projectSlug":"minard","projectName":"minard","port":3000,"host":"mbp","startCommand":""}
        ]}"""

    it "decodes each server row into a ServiceInstance" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let svcs = ingestRegistry j
          length svcs `shouldEqual` 2
          map _.localName svcs `shouldEqual` [ "tilted-radio", "minard" ]
          map (exposureLabel <<< _.exposure) svcs `shouldEqual` [ "host:3013", "host:3000" ]
          map (mechanism <<< _.executor) svcs `shouldEqual` [ MechProcess, MechUnmanaged ]
