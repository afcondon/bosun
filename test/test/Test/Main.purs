module Test.Main where

import Prelude

import Effect (Effect)
import Test.Bosun.AdapterSpec as AdapterSpec
import Test.Bosun.ApplySpec as ApplySpec
import Test.Bosun.AtomsSpec as AtomsSpec
import Test.Bosun.PBTSpec as PBTSpec
import Test.Bosun.PlanSpec as PlanSpec
import Test.Bosun.ReconcileSpec as ReconcileSpec
import Test.Bosun.ValidateSpec as ValidateSpec
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
    AdapterSpec.spec
    ValidateSpec.spec
    ReconcileSpec.spec
    PlanSpec.spec
    ApplySpec.spec
    PBTSpec.spec
