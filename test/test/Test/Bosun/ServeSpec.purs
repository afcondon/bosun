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
import Bosun.Health (Probe(..))
import Bosun.Reachability (hostPort, unixSocket)
import Bosun.Serve (DriftKind(..), Mediation(..), RejectReason(..), StopVerdict(..), brokerStopVerdict, planDrift, readMediation, serveDiff, servePlan, servePlanWith, stopVerdictTag)
import Bosun.Service (LooseService, mkDeployment)
import Data.Array (head)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromJust)
import Data.Tuple (Tuple(..), fst, snd)
import Partial.Unsafe (unsafePartial)
import Test.Bosun.ValidateSpec (leaf)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual, shouldNotEqual)

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
    , launch = { executor: Process { cwd: absPath cwd, command: cmd, env: [] }, localName: name, artifact: Nothing }
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
    -- the port the row CLAIMED travels with the refusal, so /state can join it to
    -- the registry row (itajara @3028: the real 2026-08-14 case)
    map _.publicPort p.rejected `shouldEqual` [ Just 3050 ]

  it "rejects a cd-less (Unmanaged) row as the SDI no-absolute-cwd footgun" do
    let
      svc = (leaf "x")
        { host = Just (mkHost "mbp")
        , reachability = hostPort (port_ 3060)
        , launch = { executor: Unmanaged "flask run -p 3060", localName: "x", artifact: Nothing }
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
        , launch = { executor: Process { cwd: absPath "/srv/w", command: "run", env: [] }, localName: "w", artifact: Nothing }
        }
      p = servePlan (mkDeployment [ svc ])
    p.routes `shouldEqual` []
    map _.reason p.rejected `shouldEqual` [ NoHostPort ]
    -- the ONE refusal that claims no port, so it cannot key by one
    map _.publicPort p.rejected `shouldEqual` [ Nothing ]

  it "rejects a container — P1 spawns local processes only" do
    let
      svc = (leaf "c")
        { host = Just (mkHost "mbp")
        , reachability = hostPort (port_ 3070)
        , launch =
            { executor: Container (ContainerSpec { source: Left (ImageRef "c"), internalPort: Nothing, publish: Nothing })
            , localName: "c"
            , artifact: Nothing
            }
        }
      p = servePlan (mkDeployment [ svc ])
    p.routes `shouldEqual` []
    map _.reason p.rejected `shouldEqual` [ NotAProcess ]

  it "two services on the same public port: first wins, the later is a PortCollision reject (the single-binder guarantee SDI gave implicitly)" do
    let
      p = servePlan (mkDeployment
            [ procSvc "alpha" 3050 "mbp" "/srv/a" "npx serve -p 3050"
            , procSvc "bravo" 3050 "mbp" "/srv/b" "npx serve -p 3050"
            ])
    -- exactly one binds, exactly one is rejected for the collision — and the
    -- partition still covers both services exactly once.
    map _.publicPort p.routes `shouldEqual` [ 3050 ]
    map _.reason p.rejected `shouldEqual` [ PortClaimed 3050 ]

  -- BROKER MODE (BOSUN-SERVE.md §3c). The question the registry's `serveMode`
  -- answers is "does bosun belong in the data path at all", and these pin the
  -- two things that follow from answering `broker`: the router stops relaying,
  -- and the plan starts being able to describe services a proxy cannot reach.
  describe "broker mode (serveMode: broker)" do
    let
      broker sid = { serviceId: sid, mediation: Broker, scheme: Nothing }
      brokerAs sid sch = { serviceId: sid, mediation: Broker, scheme: Just sch }

    it "an unhinted service is proxied exactly as before — the default is the status quo" do
      let
        svc = procSvc "web" 3050 "mbp" "/srv/web" "npx serve -p 3050"
        p = servePlanWith [] (mkDeployment [ svc ])
        q = servePlan (mkDeployment [ svc ])
      map _.serviceId p.brokered `shouldEqual` []
      map _.publicPort p.routes `shouldEqual` [ 3050 ]
      -- and `servePlan` IS `servePlanWith []`, so no existing caller moves
      map _.launchCommand p.routes `shouldEqual` map _.launchCommand q.routes

    it "a hint of `proxy` (or an unrecognised value) is also the status quo" do
      let
        svc = procSvc "web" 3050 "mbp" "/srv/web" "npx serve -p 3050"
        hint m = servePlanWith [ { serviceId: "web", mediation: readMediation m, scheme: Nothing } ] (mkDeployment [ svc ])
      map _.publicPort (hint "proxy").routes `shouldEqual` [ 3050 ]
      map _.publicPort (hint "brokerr").routes `shouldEqual` [ 3050 ]
      (hint "broker").routes `shouldEqual` []

    it "brokers a rewritable listener: holds the public port for a 307, service on the internal one" do
      let
        p = servePlanWith [ brokerAs "loop" "ws" ]
              (mkDeployment [ procSvc "loop" 3028 "mbp" "/srv/loop" "itajara --ws-port 3028" ])
      p.routes `shouldEqual` []
      p.rejected `shouldEqual` []
      case head p.brokered of
        Nothing -> fail "expected one brokered service"
        Just b -> do
          b.publicPort `shouldEqual` Just 3028
          b.launchCommand `shouldEqual` "itajara --ws-port 23028"
          b.at.transport `shouldEqual` "tcp"
          b.at.port `shouldEqual` Just 23028
          -- the row's own scheme travels through, so the answer is dialable as
          -- written rather than reassembled by every client
          b.at.url `shouldEqual` Just "ws://127.0.0.1:23028"
          (b.probe == TcpConnect (port_ 23028)) `shouldEqual` true

    it "brokers a listener it CANNOT rewrite — a refusal under proxy rules, a fine broker" do
      let
        p = servePlanWith [ broker "rig" ]
              (mkDeployment [ procSvc "rig" 3080 "mbp" "/srv/rig" "./rig --serve" ])
      -- the literal-port rule exists only so the router can move the backend off
      -- the public port; a broker that cannot simply leaves it where it is
      p.rejected `shouldEqual` []
      case head p.brokered of
        Nothing -> fail "expected one brokered service"
        Just b -> do
          b.publicPort `shouldEqual` Nothing      -- binds nothing
          b.launchCommand `shouldEqual` "./rig --serve"
          b.at.port `shouldEqual` Just 3080

    it "brokers a UNIX-SOCKET daemon — a service the proxy model cannot represent at all" do
      let
        svc = (leaf "es9")
          { host = Just (mkHost "mbp")
          , reachability = unixSocket (absPath "/Users/afc/.es9/control.sock")
          , launch = { executor: Process { cwd: absPath "/srv/es9", command: "es9-daemon", env: [] }, localName: "es9", artifact: Nothing }
          }
        p = servePlanWith [ broker "es9" ] (mkDeployment [ svc ])
      -- under proxy rules this is NoHostPort, i.e. invisible to the router
      (servePlan (mkDeployment [ svc ])).rejected `shouldEqual`
        [ { serviceId: "es9", publicPort: Nothing, reason: NoHostPort } ]
      case head p.brokered of
        Nothing -> fail "expected one brokered service"
        Just b -> do
          b.at.transport `shouldEqual` "unix"
          b.at.path `shouldEqual` Just "/Users/afc/.es9/control.sock"
          (b.probe == SocketReady (absPath "/Users/afc/.es9/control.sock")) `shouldEqual` true

    it "a UDP endpoint is located but NOT probed — a connect proves nothing there" do
      let
        p = servePlanWith [ brokerAs "link" "udp" ]
              (mkDeployment [ procSvc "link" 20808 "mbp" "/srv/link" "link-spike --port 20808" ])
      case head p.brokered of
        Nothing -> fail "expected one brokered service"
        Just b -> do
          b.at.transport `shouldEqual` "udp"
          -- `NoProbe` reports as "not checked", never as "down" — the whole
          -- point of not inventing a TCP probe for a datagram socket
          (b.probe == NoProbe) `shouldEqual` true

    it "a broker still has to be spawnable: a cd-less row is refused as it always was" do
      let
        svc = (leaf "x")
          { host = Just (mkHost "mbp")
          , reachability = hostPort (port_ 3060)
          , launch = { executor: Unmanaged "flask run -p 3060", localName: "x", artifact: Nothing }
          }
        p = servePlanWith [ broker "x" ] (mkDeployment [ svc ])
      map _.serviceId p.brokered `shouldEqual` []
      -- the WHOLE rejection, not just its reason: the port a refusal claimed is
      -- what lets it be correlated with the registry row that produced it, and
      -- asserting `_.reason` alone let a brokered refusal quietly drop it.
      p.rejected `shouldEqual` [ { serviceId: "x", publicPort: Just 3060, reason: Sdi NoAbsoluteCwd } ]

    -- The three below all fail the same way if a broker's verdict is filed
    -- under the port it BINDS rather than the port the ROW CLAIMED. A broker
    -- that binds nothing is the normal case, so keyed by `publicPort` the
    -- healthiest services in the deployment reported as `Unaccounted` — the one
    -- drift kind a reload cannot fix, whose remedy is "go and fix the row".
    it "a broker that binds nothing still ACCOUNTS FOR its registry claim (no drift)" do
      let
        p = servePlanWith [ broker "rig" ]
              (mkDeployment [ procSvc "rig" 3080 "mbp" "/srv/rig" "./rig --serve" ])
      map _.publicPort p.brokered `shouldEqual` [ Nothing ]
      map _.declaredPort p.brokered `shouldEqual` [ Just 3080 ]
      planDrift [ { serviceId: "rig", publicPort: 3080 } ] p p `shouldEqual` []

    it "a UDP broker accounts for its port too — located, unmoved, and not drift" do
      let
        p = servePlanWith [ brokerAs "link" "udp" ]
              (mkDeployment [ procSvc "link" 20808 "mbp" "/srv/link" "link-spike --port 20808" ])
      -- deliberately left where it is (there is no 307 over UDP), so it binds
      -- nothing while still being the plan's answer for :20808
      map _.publicPort p.brokered `shouldEqual` [ Nothing ]
      planDrift [ { serviceId: "link", publicPort: 20808 } ] p p `shouldEqual` []

    it "a brokered REFUSAL is agreement, not drift — the operator reads the reason" do
      let
        svc = (leaf "x")
          { host = Just (mkHost "mbp")
          , reachability = hostPort (port_ 3060)
          , launch = { executor: Unmanaged "flask run -p 3060", localName: "x", artifact: Nothing }
          }
        p = servePlanWith [ broker "x" ] (mkDeployment [ svc ])
      -- a row the router REFUSES is accounted for: `rejected` says why, and
      -- sending the operator to chase a reload instead would change nothing
      planDrift [ { serviceId: "x", publicPort: 3060 } ] p p `shouldEqual` []

    it "a brokered service on ANOTHER machine is still a 421 — we cannot spawn it here" do
      let
        p = servePlanWith [ broker "web" ]
              (mkDeployment [ procSvc "web" 3050 "macmini" "/srv/web" "npx serve -p 3050" ])
      map _.serviceId p.brokered `shouldEqual` []
      map _.target p.redirects `shouldEqual` [ "http://andrews-mac-mini:3050" ]

    it "a broker's public port is a binder: two claimants still collide" do
      let
        p = servePlanWith [ broker "alpha" ]
              (mkDeployment
                [ procSvc "alpha" 3050 "mbp" "/srv/a" "run -p 3050"
                , procSvc "bravo" 3050 "mbp" "/srv/b" "run -p 3050"
                ])
      map _.publicPort p.brokered `shouldEqual` [ Just 3050 ]
      map _.reason p.rejected `shouldEqual` [ PortClaimed 3050 ]

    it "flipping proxy↔broker on one port reads as a CHANGE, so the listener is rebuilt" do
      let
        dep = mkDeployment [ procSvc "loop" 3028 "mbp" "/srv/loop" "itajara --ws-port 3028" ]
        asProxy = servePlanWith [] dep
        asBroker = servePlanWith [ broker "loop" ] dep
        d = serveDiff asProxy asBroker
      d.unbind `shouldEqual` [ 3028 ]
      d.bindRoutes `shouldEqual` []
      map _.serviceId d.bindBrokers `shouldEqual` [ "loop" ]

  -- `POST /control/stop` on a BROKERED service. Broker mode shipped able to
  -- START one (`/where` lazy-spawns it) and not to stop it: the control handler
  -- consulted only the proxy table, so every brokered row answered `no proxy
  -- route`. These pin the rule the fix adopted — which is the PROXY path's
  -- rule, not a second one — and the case a boolean would have hidden.
  describe "brokerStopVerdict (POST /control/stop on a broker)" do
    let
      tcp = TcpConnect (port_ 23028)
      sock = SocketReady (absPath "/Users/afc/.es9/control.sock")

    it "holds the child ⇒ signal it: a service bosun started is bosun's to stop" do
      brokerStopVerdict true false tcp `shouldEqual` Signal

    it "holds the child while the probe still says down ⇒ still signal it" do
      -- A daemon that is slow to bind must not be unstoppable for the window in
      -- which it is starting; the handle is better evidence than the probe.
      brokerStopVerdict true false sock `shouldEqual` Signal

    it "no child, but it IS running ⇒ adopted: bosun did not start it, so it must not kill it" do
      -- The same refusal `adoptedBackend && not child` makes on the proxy side.
      brokerStopVerdict false true tcp `shouldEqual` Adopted

    it "no child, no probe that could say ⇒ unknown, never a blanket ok" do
      -- link-spike over UDP multicast: neither "I stopped it" nor "nothing was
      -- running" is supportable, and an `ok` reads to an operator as "it's down".
      brokerStopVerdict false false NoProbe `shouldEqual` Unknown

    it "no child, and the probe says nothing is there ⇒ absent, which stops cleanly" do
      brokerStopVerdict false false tcp `shouldEqual` Absent

    it "a probe that ANSWERED down and a probe that could not be made are different findings" do
      brokerStopVerdict false false tcp `shouldNotEqual` brokerStopVerdict false false NoProbe

    it "the wire tags the shim answers with are the four, distinctly" do
      map stopVerdictTag [ Signal, Adopted, Unknown, Absent ]
        `shouldEqual` [ "signal", "adopted", "unknown", "absent" ]

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

  -- The registry⇄router disagreement `serveDiff` cannot express: it answers
  -- "what would I bind differently", which is silent about a row the router
  -- refuses. `planDrift` answers "do these two agree at all", which is what
  -- "registered but never routed" needs.
  describe "planDrift (registry on disk vs the plan the router holds)" do
    let
      planOf = servePlan <<< mkDeployment
      -- the raw registry claims matching a set of services (what
      -- `registryClaims` would return for the rows behind them)
      claims = map (\s -> { serviceId: fst s, publicPort: snd s })

    it "a plan against itself: no drift" do
      let p = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]
      planDrift (claims [ Tuple "a" 3050 ]) p p `shouldEqual` []

    it "a row registered since the router planned is Unrouted (THE itajara case)" do
      let
        held = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]
        fresh = planOf
          [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050"
          , procSvc "itajara" 3028 "mbp" "/srv/i" "run -p 3028"
          ]
      planDrift (claims [ Tuple "a" 3050, Tuple "itajara" 3028 ]) held fresh `shouldEqual`
        [ { publicPort: 3028, serviceId: "itajara", kind: Unrouted } ]

    it "a row the router REFUSED is agreement, not drift — the reason is the answer" do
      let
        -- no literal port in the command ⇒ refused, and refusal counts as SEEN
        fresh = planOf [ procSvc "web" 3050 "mbp" "/srv/web" "npx serve" ]
      map _.reason fresh.rejected `shouldEqual` [ Sdi PortNotInStartCommand ]
      planDrift (claims [ Tuple "web" 3050 ]) fresh fresh `shouldEqual` []

    it "a row that BECAME unroutable while resident drifts as Altered" do
      let
        held = planOf [ procSvc "web" 3050 "mbp" "/srv/web" "npx serve -p 3050" ]
        fresh = planOf [ procSvc "web" 3050 "mbp" "/srv/web" "npx serve" ]
      planDrift (claims [ Tuple "web" 3050 ]) held fresh `shouldEqual`
        [ { publicPort: 3050, serviceId: "web", kind: Altered } ]

    it "a row deleted from the registry drifts as Departed (the router still holds the port)" do
      let held = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]
      planDrift [] held (planOf []) `shouldEqual`
        [ { publicPort: 3050, serviceId: "a", kind: Departed } ]

    -- The claims argument earns its place here: BOTH plans agree (neither has a
    -- verdict on :3033), so a two-plan comparison would call this agreement. Only
    -- the raw rows reveal that the registry asked for a port nothing serves.
    it "a claimed port no plan accounts for is Unaccounted — reload cannot fix it" do
      let p = planOf [ procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050" ]
      planDrift (claims [ Tuple "a" 3050, Tuple "swallowed" 3033 ]) p p `shouldEqual`
        [ { publicPort: 3033, serviceId: "swallowed", kind: Unaccounted } ]

    it "sorted by port, so two surfaces reporting drift report it identically" do
      let
        fresh = planOf
          [ procSvc "c" 3052 "mbp" "/srv/c" "run -p 3052"
          , procSvc "a" 3050 "mbp" "/srv/a" "run -p 3050"
          , procSvc "b" 3051 "mbp" "/srv/b" "run -p 3051"
          ]
        cs = claims [ Tuple "a" 3050, Tuple "b" 3051, Tuple "c" 3052 ]
      map _.publicPort (planDrift cs (planOf []) fresh) `shouldEqual` [ 3050, 3051, 3052 ]
