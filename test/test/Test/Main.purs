module Test.Main where

import Prelude

import Effect (Effect)
import Test.Bosun.AdapterSpec as AdapterSpec
import Test.Bosun.ApplySpec as ApplySpec
import Test.Bosun.ArtifactSpec as ArtifactSpec
import Test.Bosun.AtomsSpec as AtomsSpec
import Test.Bosun.DockerPsSpec as DockerPsSpec
import Test.Bosun.PBTSpec as PBTSpec
import Test.Bosun.PlanSpec as PlanSpec
import Test.Bosun.ReachabilitySpec as ReachabilitySpec
import Test.Bosun.ReconcileSpec as ReconcileSpec
import Test.Bosun.ServeSpec as ServeSpec
import Test.Bosun.SupervisorSpec as SupervisorSpec
import Test.Bosun.ValidateSpec as ValidateSpec
import Test.Bosun.ViewSpec as ViewSpec
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
    ArtifactSpec.spec
    DockerPsSpec.spec
    ValidateSpec.spec
    ReachabilitySpec.spec
    ReconcileSpec.spec
    PlanSpec.spec
    ApplySpec.spec
    ServeSpec.spec
    SupervisorSpec.spec
    ViewSpec.spec
    PBTSpec.spec
