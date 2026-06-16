module Test.Bosun.ViewSpec where

import Prelude

import Bosun.Atoms (mkServiceId)
import Bosun.Error (DeployError(..))
import Bosun.View
  ( AliasOverride(..), AnalyzeRequest, AnalyzeResult, ReconcileView, ServiceInstanceView, ValidatedView, ValidationView(..)
  , analyzeRequestCodec, analyzeResultCodec, errKind, reconcileViewCodec, remediation, serviceInstanceViewCodec
  , validatedViewCodec, validationViewCodec
  )
import Data.Array.NonEmpty as NEA
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- | A codec is faithful when decode ∘ encode is the identity. Compared as a
-- | Boolean so the view types need no `Show` (entry-73: no production `Show`).
rt :: forall a. Eq a => CA.JsonCodec a -> a -> Boolean
rt codec x = CA.decode codec (CA.encode codec x) == Right x

sampleInstance :: ServiceInstanceView
sampleInstance =
  { source: "compose"
  , project: Just "uniform-romeo"
  , localName: "tidal-frontend"
  , role: "frontend"
  , host: Just "macmini"
  , executor: { mechanism: "container", detail: "build ./tidal" }
  , exposure: "host:8193"
  , reachability: [ { kind: "listening", bind: Just "all", port: Just 8193, path: Nothing, proxy: Nothing, domain: Nothing, socket: Nothing, openness: "wide" } ]
  , readiness: "http / :8193"
  , deps: [ { to: "api", ordering: Just "after", requirement: Just "requires(ready)" } ]
  , routes: [ { to: "edge", path: "/tidal" } ]
  , selectors: [ "profile:tidal" ]
  }

-- An instance exercising the Nothing branches (no project, no host, empty arrays).
bareInstance :: ServiceInstanceView
bareInstance =
  { source: "registry", project: Nothing, localName: "worker", role: "worker", host: Nothing
  , executor: { mechanism: "process", detail: "/srv$ run" }, exposure: "none", reachability: [], readiness: "none"
  , deps: [], routes: [], selectors: []
  }

sampleReconcile :: ReconcileView
sampleReconcile =
  { services: [ "tidal:frontend", "tidal:api" ]
  , divergences:
      [ { svc: "tidal:frontend"
        , facets: [ { host: Just "mbp", mechanism: "process" }, { host: Just "macmini", mechanism: "container" } ]
        }
      ]
  , conflicts:
      [ { svc: "tidal:api", field: "exposure"
        , claims: [ { source: "compose", value: "host:9000" }, { source: "registry", value: "host:9001" } ]
        }
      ]
  , aliases: [ { from: "tidal-frontend", to: "tidal:frontend" } ]
  }

sampleValid :: ValidatedView
sampleValid =
  { services: [ { id: "tidal:frontend", host: Just "macmini", exposure: "host:8193", deps: [ "tidal:api" ], selectors: [ "profile:tidal" ] } ]
  , bootOrder: [ [ "tidal:api" ], [ "tidal:frontend" ] ]
  , routes: [ { path: "/tidal", backend: "tidal:frontend" } ]
  }

sampleInvalid :: ValidationView
sampleInvalid = Invalid [ { kind: "DependencyCycle", detail: "cycle: a → b → a", remediation: [ "Break the cycle." ] } ]

sampleRequest :: AnalyzeRequest
sampleRequest =
  { compose: Just "/abs/compose.yml"
  , registry: Just "http://andrews-mac-mini:3100/api/ports"
  , overrides:
      [ Merge { canonical: "tidal:frontend", names: [ "tidal-frontend", "trf" ] }
      , Split { name: "ee-backend" }
      ]
  }

spec :: Spec Unit
spec = describe "Bosun.View" do
  describe "codec round-trips (decode ∘ encode = id — the shared wire contract)" do
    it "ServiceInstanceView (rung 1)" do
      rt serviceInstanceViewCodec sampleInstance `shouldEqual` true
    it "ServiceInstanceView with Nothing / empty fields" do
      rt serviceInstanceViewCodec bareInstance `shouldEqual` true
    it "ReconcileView (rung 2)" do
      rt reconcileViewCodec sampleReconcile `shouldEqual` true
    it "ValidatedView (rung 3, success)" do
      rt validatedViewCodec sampleValid `shouldEqual` true
    it "ValidationView — Valid branch" do
      rt validationViewCodec (Valid sampleValid) `shouldEqual` true
    it "ValidationView — Invalid branch" do
      rt validationViewCodec sampleInvalid `shouldEqual` true
    it "AnalyzeResult — whole envelope, success" do
      rt analyzeResultCodec ({ instances: [ sampleInstance, bareInstance ], reconcile: sampleReconcile, result: Valid sampleValid } :: AnalyzeResult) `shouldEqual` true
    it "AnalyzeResult — whole envelope, failure" do
      rt analyzeResultCodec ({ instances: [ sampleInstance ], reconcile: sampleReconcile, result: sampleInvalid } :: AnalyzeResult) `shouldEqual` true
    it "AnalyzeRequest — with both AliasOverride constructors (the editable-alias contract)" do
      rt analyzeRequestCodec (sampleRequest :: AnalyzeRequest) `shouldEqual` true

  describe "DeployError projection (workstream D)" do
    it "errKind names the variant" do
      errKind (DependencyCycle (NEA.singleton (mkServiceId "a"))) `shouldEqual` "DependencyCycle"
    it "every error carries at least one remediation step" do
      (remediation (DanglingDependency (mkServiceId "web") "ghost") /= []) `shouldEqual` true
      (remediation (CrossSourceDrift { svc: mkServiceId "api", field: "exposure", claims: [] }) /= []) `shouldEqual` true
