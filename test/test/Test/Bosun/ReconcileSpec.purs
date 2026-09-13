-- | The reconcile facet model (DECISIONS D-E3/E2) against the *real* §7 case:
-- | the registry's tilted-radio (`82:frontend`, mbp,
-- | native) and compose's `tidal-frontend` (macmini, container) are ONE
-- | logical service with TWO facets — that is divergence (informational), not
-- | a conflict. A within-facet port disagreement IS a conflict (B9). A
-- | single-facet service is quiet (D-E2). Plus the report renderer.
module Test.Bosun.ReconcileSpec where

import Prelude

import Bosun.Atoms (AbsPath, Port, RoutePath, ServiceId, mkAbsPath, mkHost, mkPort, mkProjectId, mkRoutePath, mkServiceId)
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Reachability (hostPort, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderReport, renderTopologyDrift)
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
  , artifact: Nothing
  , reachability: noNetwork
  , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

container :: String -> Executor
container image = Container (ContainerSpec { source: Left (ImageRef image), internalPort: Nothing, publish: Nothing })

buildCtx :: String -> Executor
buildCtx ctx = Container (ContainerSpec { source: Right (BuildContext { context: ctx, dockerfile: Nothing }), internalPort: Nothing, publish: Nothing })

-- ── the §7 fixtures ─────────────────────────────────────────────────────────

-- registry: tilted-radio, Marginalia project 82, mbp-native @3013
tiltedRegistry :: ServiceInstance
tiltedRegistry = inst
  { source = FromRegistry
  , project = Just (mkProjectId "82")
  , localName = "psd3-tilted-radio"
  , role = mkRole "frontend"
  , host = Just (mkHost "mbp")
  , executor = Process { cwd: absPath "/Users/afc/work/afc-work/purescript-hylograph-showcases/psd3-tilted-radio", command: "npx serve", env: [] }
  , reachability = hostPort (port_ 3013)
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
  , reachability = noNetwork
  }

-- the alias bridges compose's name to the registry-derived id
aliases :: Map.Map String ServiceId
aliases = Map.singleton "tidal-frontend" (mkServiceId "82:frontend")

spec :: Spec Unit
spec = describe "Bosun.Reconcile" do

  it "§7 tilted-radio: two facets => 1 divergence, 0 conflicts (NOT drift)" do
    let r = reconcile aliases [ tiltedRegistry, tiltedCompose ]
    length r.divergences `shouldEqual` 1
    length r.conflicts `shouldEqual` 0

  it "§7 guard: npx-serve native + prebuilt image is NOT artifact drift" do
    -- neither facet exposes a comparable source dir, so the divergence is benign
    let r = reconcile aliases [ tiltedRegistry, tiltedCompose ]
    length r.artifactDrift `shouldEqual` 0

  it "artifact drift: native -root dir vs container build context of a DIFFERENT dir" do
    let
      webNative = inst
        { source = FromRegistry
        , project = Just (mkProjectId "poly")
        , localName = "polyglot-website"
        , role = mkRole "website"
        , host = Just (mkHost "mbp")
        , executor = Process { cwd: absPath "/Users/afc/work/afc-work/polyglot-deploy", command: "static-httpd -root site/polyglot/public -port 3040", env: [] }
        , reachability = hostPort (port_ 3040)
        }
      webDocker = inst
        { source = FromCompose
        , project = Nothing
        , localName = "website"
        , role = mkRole "website"
        , host = Just (mkHost "macmini")
        , executor = buildCtx "../purescript-polyglot/site/website"
        , reachability = noNetwork
        }
      drifts = reconcile (Map.singleton "website" (mkServiceId "poly:website")) [ webNative, webDocker ]
    length drifts.artifactDrift `shouldEqual` 1

  describe "topology drift (the edge is topology, per-host)" do
    let
      route :: String -> String -> { to :: String, path :: RoutePath }
      route to path = { to, path: mkRoutePath path }
      -- an edge declaring its route table; backends keyed by bare localName
      edgeOn host_ = inst
        { source = FromCompose, localName = "edge", role = mkRole "edge", host = Just (mkHost host_)
        , rawRoutes = [ route "website" "/", route "ee-backend" "/ee" ] }
      backend nm host_ = inst { localName = nm, role = mkRole nm, host = Just (mkHost host_) }

    it "host running routed backends with no co-located edge => 1 TopologyDrift" do
      let
        -- macmini: edge + both backends (satisfied); mbp: both backends, no edge
        r = reconcile Map.empty
          [ edgeOn "macmini", backend "website" "macmini", backend "ee-backend" "macmini"
          , backend "website" "mbp", backend "ee-backend" "mbp" ]
      length r.topologyDrift `shouldEqual` 1            -- only mbp is edge-missing

    it "guard: edge co-located on every host => quiet (Chair's 5th-row fix)" do
      let
        r = reconcile Map.empty
          [ edgeOn "macmini", backend "website" "macmini", backend "ee-backend" "macmini"
          , edgeOn "mbp", backend "website" "mbp", backend "ee-backend" "mbp" ]
      length r.topologyDrift `shouldEqual` 0

    it "guard: a backend with no route to it is not edge-gated (reached directly)" do
      let
        -- ee-backend has a route; a plain unrouted service on mbp must NOT flag
        r = reconcile Map.empty
          [ edgeOn "macmini", backend "ee-backend" "macmini"
          , inst { localName = "loner", role = mkRole "loner", host = Just (mkHost "mbp") } ]
      length r.topologyDrift `shouldEqual` 0

    it "renders the gap under EDGE MISSING" do
      let
        r = reconcile Map.empty
          [ edgeOn "macmini", backend "website" "macmini", backend "ee-backend" "macmini"
          , backend "website" "mbp", backend "ee-backend" "mbp" ]
        out = renderTopologyDrift r.topologyDrift
      contains (Pattern "EDGE MISSING") out `shouldEqual` true
      contains (Pattern "mbp serves none of") out `shouldEqual` true

  it "B9 within-facet port disagreement => 1 conflict, 0 divergences" do
    let
      a = inst { source = FromRegistry, project = Just (mkProjectId "p"), role = mkRole "api", reachability = hostPort (port_ 3013) }
      b = inst { source = FromCompose, project = Just (mkProjectId "p"), role = mkRole "api", reachability = hostPort (port_ 3014) }
      r = reconcile Map.empty [ a, b ]
    length r.conflicts `shouldEqual` 1
    length r.divergences `shouldEqual` 0

  it "single-facet service is quiet (D-E2: absence is not drift)" do
    let r = reconcile Map.empty [ inst { project = Just (mkProjectId "solo"), role = mkRole "api" } ]
    length r.conflicts `shouldEqual` 0
    length r.divergences `shouldEqual` 0

  describe "renderReport (entry-73 display)" do
    it "renders the §7 divergence under FACET DIVERGENCE" do
      let
        r = reconcile aliases [ tiltedRegistry, tiltedCompose ]
        out = renderReport { conflicts: r.conflicts, divergences: r.divergences } []
      contains (Pattern "FACET DIVERGENCE") out `shouldEqual` true
      contains (Pattern "82:frontend has 2") out `shouldEqual` true

    it "renders a within-facet conflict under CONFLICTS" do
      let
        a = inst { project = Just (mkProjectId "p"), role = mkRole "api", reachability = hostPort (port_ 3013) }
        b = inst { source = FromCompose, project = Just (mkProjectId "p"), role = mkRole "api", reachability = hostPort (port_ 3014) }
        r = reconcile Map.empty [ a, b ]
        out = renderReport { conflicts: r.conflicts, divergences: r.divergences } []
      contains (Pattern "CONFLICTS") out `shouldEqual` true
      contains (Pattern "drift on p:api.exposure") out `shouldEqual` true

    it "a clean pass renders OK" do
      renderReport { conflicts: [], divergences: [] } [] `shouldEqual` "bosun check: OK — no problems found."
