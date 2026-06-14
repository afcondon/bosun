-- | The reconcile facet model (DECISIONS D-E3/E2) against the *real* §7 case:
-- | the registry's tilted-radio (`uniform-romeo-romeo-juliet:frontend`, mbp,
-- | native) and compose's `tidal-frontend` (macmini, container) are ONE
-- | logical service with TWO facets — that is divergence (informational), not
-- | a conflict. A within-facet port disagreement IS a conflict (B9). A
-- | single-facet service is quiet (D-E2). Plus the report renderer.
module Test.Bosun.ReconcileSpec where

import Prelude

import Bosun.Atoms (AbsPath, Port, ServiceId, mkAbsPath, mkHost, mkPort, mkProjectSlug, mkServiceId)
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderReport)
import Bosun.Service (Source(..), ServiceInstance, mkRole)
import Data.Array (length)
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
import Data.String (Pattern(..), contains)
import Partial.Unsafe (unsafePartial)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- ── builders ────────────────────────────────────────────────────────────────

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

inst :: ServiceInstance
inst =
  { source: FromRegistry
  , project: Nothing
  , localName: "svc"
  , role: mkRole "frontend"
  , host: Just (mkHost "mbp")
  , executor: Unmanaged "svc"
  , exposure: NoNetwork
  , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

container :: String -> Executor
container image = Container (ContainerSpec { source: Left (ImageRef image), internalPort: Nothing, publish: Nothing })

-- ── the §7 fixtures ─────────────────────────────────────────────────────────

-- registry: tilted-radio, slug uniform-romeo-romeo-juliet, mbp-native @3013
tiltedRegistry :: ServiceInstance
tiltedRegistry = inst
  { source = FromRegistry
  , project = Just (mkProjectSlug "uniform-romeo-romeo-juliet")
  , localName = "psd3-tilted-radio"
  , role = mkRole "frontend"
  , host = Just (mkHost "mbp")
  , executor = Process { cwd: absPath "/Users/afc/work/afc-work/purescript-hylograph-showcases/psd3-tilted-radio", command: "npx serve", env: [] }
  , exposure = HostPort (port_ 3013)
  }

-- compose: tidal-frontend, macmini, container, no host port
tiltedCompose :: ServiceInstance
tiltedCompose = inst
  { source = FromCompose
  , project = Nothing
  , localName = "tidal-frontend"
  , role = mkRole "frontend"
  , host = Just (mkHost "macmini")
  , executor = container "tidal-frontend"
  , exposure = NoNetwork
  }

-- the alias bridges compose's name to the registry-derived id
aliases :: Map.Map String ServiceId
aliases = Map.singleton "tidal-frontend" (mkServiceId "uniform-romeo-romeo-juliet:frontend")

spec :: Spec Unit
spec = describe "Bosun.Reconcile" do

  it "§7 tilted-radio: two facets => 1 divergence, 0 conflicts (NOT drift)" do
    let r = reconcile aliases [ tiltedRegistry, tiltedCompose ]
    length r.divergences `shouldEqual` 1
    length r.conflicts `shouldEqual` 0

  it "B9 within-facet port disagreement => 1 conflict, 0 divergences" do
    let
      a = inst { source = FromRegistry, project = Just (mkProjectSlug "p"), role = mkRole "api", exposure = HostPort (port_ 3013) }
      b = inst { source = FromCompose, project = Just (mkProjectSlug "p"), role = mkRole "api", exposure = HostPort (port_ 3014) }
      r = reconcile Map.empty [ a, b ]
    length r.conflicts `shouldEqual` 1
    length r.divergences `shouldEqual` 0

  it "single-facet service is quiet (D-E2: absence is not drift)" do
    let r = reconcile Map.empty [ inst { project = Just (mkProjectSlug "solo"), role = mkRole "api" } ]
    length r.conflicts `shouldEqual` 0
    length r.divergences `shouldEqual` 0

  describe "renderReport (entry-73 display)" do
    it "renders the §7 divergence under FACET DIVERGENCE" do
      let
        r = reconcile aliases [ tiltedRegistry, tiltedCompose ]
        out = renderReport { conflicts: r.conflicts, divergences: r.divergences } []
      contains (Pattern "FACET DIVERGENCE") out `shouldEqual` true
      contains (Pattern "uniform-romeo-romeo-juliet:frontend has 2") out `shouldEqual` true

    it "renders a within-facet conflict under CONFLICTS" do
      let
        a = inst { project = Just (mkProjectSlug "p"), role = mkRole "api", exposure = HostPort (port_ 3013) }
        b = inst { source = FromCompose, project = Just (mkProjectSlug "p"), role = mkRole "api", exposure = HostPort (port_ 3014) }
        r = reconcile Map.empty [ a, b ]
        out = renderReport { conflicts: r.conflicts, divergences: r.divergences } []
      contains (Pattern "CONFLICTS") out `shouldEqual` true
      contains (Pattern "drift on p:api.exposure") out `shouldEqual` true

    it "a clean pass renders OK" do
      renderReport { conflicts: [], divergences: [] } [] `shouldEqual` "bosun check: OK — no problems found."
