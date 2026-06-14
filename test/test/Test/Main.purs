module Test.Main where

import Prelude

import Effect (Effect)
import Test.Bosun.AtomsSpec as AtomsSpec
import Test.Spec (describe)
import Test.Spec.Reporter.Spec (specReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)

-- | `runSpecAndExitProcess` (spec-node) sets the process exit code, so
-- | `spago test` is a real green/red gate. The scenario corpus and PBT
-- | properties grow alongside `validate` from Phase 2 on.
main :: Effect Unit
main = runSpecAndExitProcess [specReporter] do
  describe "bosun-core" do
    AtomsSpec.spec
