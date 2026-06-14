module Test.Main where

import Prelude

import Bosun.Version (version)
import Effect (Effect)
import Test.Spec (describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter.Spec (specReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

-- | Phase 0: one trivial passing test that also proves cross-package
-- | wiring — the test package imports the core package. The scenario
-- | corpus and PBT properties grow here from Phase 2 on.
-- |
-- | `runSpecAndExitProcess` (spec-node) sets the process exit code, so
-- | `spago test` is a real green/red gate.
main :: Effect Unit
main = runSpecAndExitProcess [specReporter] do
  describe "Bosun scaffold" do
    it "exposes a core version string" do
      version `shouldEqual` "0.0.0"
