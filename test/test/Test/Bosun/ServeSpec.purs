-- | BUILD-PLAN Phase 7 (P1) — `servePlan` admission control as example tests.
-- |
-- | `servePlan` is the pure heart of `bosun serve`: each reconciled service is
-- | either an admitted `Route` (with the public port rewritten to the internal
-- | port, the SDI convention) or a typed `Rejection`. These assert the admit /
-- | reject decision and the rewrite — the part with the value; the resident
-- | proxy shim is mechanical and lives at the CLI edge.
module Test.Bosun.ServeSpec where

import Prelude

import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkHost, mkPort)
import Bosun.Error (SdiViolation(..))
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Reachability (hostPort)
import Bosun.Serve (RejectReason(..), serveDiff, servePlan)
import Bosun.Service (LooseService, mkDeployment)
import Data.Array (head)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromJust)
import Partial.Unsafe (unsafePartial)
import Test.Bosun.ValidateSpec (leaf)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

-- a local (mbp) Process service exposing a host port
procSvc :: String -> Int -> String -> String -> String -> LooseService
procSvc name port host cwd cmd =
  (leaf name)
    { host = Just (mkHost host)
    , reachability = hostPort (port_ port)
    , launch = { executor: Process { cwd: absPath cwd, command: cmd, env: [] }, localName: name }
    }

spec :: Spec Unit
spec = describe "Bosun.Serve.servePlan" do

  it "admits a local Process with the literal port in its command, rewriting it +20000" do
    let p = servePlan (mkDeployment [ procSvc "web" 3050 "mbp" "/srv/web" "npx serve -p 3050" ])
    p.rejected `shouldEqual` []
    case head p.routes of
      Nothing -> fail "expected one admitted route"
      Just r -> do
        r.publicPort `shouldEqual` 3050
        r.internalPort `shouldEqual` 23050
        r.cwd `shouldEqual` "/srv/web"
        r.launchCommand `shouldEqual` "npx serve -p 23050"

  it "rejects a Process whose command lacks the literal port (SDI PortNotInStartCommand)" do
    let p = servePlan (mkDeployment [ procSvc "web" 3050 "mbp" "/srv/web" "npx serve" ])
    p.routes `shouldEqual` []
    map _.reason p.rejected `shouldEqual` [ Sdi PortNotInStartCommand ]

  it "rejects a cd-less (Unmanaged) row as the SDI no-absolute-cwd footgun" do
    let
      svc = (leaf "x")
        { host = Just (mkHost "mbp")
        , reachability = hostPort (port_ 3060)
        , launch = { executor: Unmanaged "flask run -p 3060", localName: "x" }
        }
      p = servePlan (mkDeployment [ svc ])
    p.routes `shouldEqual` []
    map _.reason p.rejected `shouldEqual` [ Sdi NoAbsoluteCwd ]

  it "redirects a remote (macmini) service with a 421 to its tailnet URL" do
    let p = servePlan (mkDeployment [ procSvc "web" 3050 "macmini" "/srv/web" "npx serve -p 3050" ])
    p.routes `shouldEqual` []
    p.rejected `shouldEqual` []
    case head p.redirects of
      Nothing -> fail "expected one redirect"
      Just d -> do
        d.publicPort `shouldEqual` 3050
        d.host `shouldEqual` "macmini"
        d.target `shouldEqual` "http://andrews-mac-mini:3050"

  it "rejects a service with no host port to bind" do
    let
      svc = (leaf "w")
        { host = Just (mkHost "mbp")
        , launch = { executor: Process { cwd: absPath "/srv/w", command: "run", env: [] }, localName: "w" }
        }
      p = servePlan (mkDeployment [ svc ])
    p.routes `shouldEqual` []
    map _.reason p.rejected `shouldEqual` [ NoHostPort ]

  it "rejects a container — P1 spawns local processes only" do
    let
      svc = (leaf "c")
        { host = Just (mkHost "mbp")
        , reachability = hostPort (port_ 3070)
        , launch =
            { executor: Container (ContainerSpec { source: Left (ImageRef "c"), internalPort: Nothing, publish: Nothing })
            , localName: "c"
            }
        }
      p = servePlan (mkDeployment [ svc ])
    p.routes `shouldEqual` []
    map _.reason p.rejected `shouldEqual` [ NotAProcess ]

  describe "serveDiff (SIGHUP hot-reload)" do
    let planOf = servePlan <<< mkDeployment

    it "identical plans → no changes" do
      let p = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]
      let d = serveDiff p p
      d.unbind `shouldEqual` []
      map _.publicPort d.bindRoutes `shouldEqual` []

    it "added route → bind it, nothing to unbind" do
      let d = serveDiff (planOf []) (planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ])
      d.unbind `shouldEqual` []
      map _.publicPort d.bindRoutes `shouldEqual` [ 3050 ]

    it "removed route → unbind its port" do
      let d = serveDiff (planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]) (planOf [])
      d.unbind `shouldEqual` [ 3050 ]
      map _.publicPort d.bindRoutes `shouldEqual` []

    it "changed command at the same port → unbind + rebind" do
      let
        old = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]
        new = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run --fast -p 3050" ]
        d = serveDiff old new
      d.unbind `shouldEqual` [ 3050 ]
      map _.publicPort d.bindRoutes `shouldEqual` [ 3050 ]

    it "untouched port alongside a change is left bound (not in the diff)" do
      let
        old = planOf
          [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050"
          , procSvc "b" 3051 "mbp" "/srv/b" "run -p 3051"
          ]
        new = planOf
          [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050"
          , procSvc "b" 3051 "mbp" "/srv/b" "run --fast -p 3051"
          ]
        d = serveDiff old new
      d.unbind `shouldEqual` [ 3051 ]
      map _.publicPort d.bindRoutes `shouldEqual` [ 3051 ]
