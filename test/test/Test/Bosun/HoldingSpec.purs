-- | `Bosun.Holding` — whose process holds a service's port.
-- |
-- | The failure these pin (docs/FINDINGS-restart-ok-on-orphan.md): a restart of
-- | `friends-of-itajara` answered `ok` twice while pid 94743, started five days
-- | earlier from the service's own directory, went on serving :3029. The
-- | evidence below is shaped exactly like what the host printed for it.
module Test.Bosun.HoldingSpec where

import Prelude

import Bosun.Atoms (Port, ServiceId, mkPort, mkServiceId)
import Bosun.Holding (Holding(..), ReapVerdict(..), holdingJson, holdingScript, holdingTag, jsonString, judgeHolding, mkPid, readHoldingEvidence, readReap, reapScript, settleTeardown, strangers)
import Bosun.Substrate (TeardownVerdict(..))
import Data.Array as A
import Data.Maybe (Maybe(..), fromJust)
import Partial.Unsafe (unsafePartial)
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..), snd)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- Every port used here is valid.
port :: Int -> Port
port n = unsafePartial (fromJust (mkPort n))

sid :: String -> ServiceId
sid = mkServiceId

itajaraDir :: String
itajaraDir = "/Users/afc/work/afc-work/music/friends-of-itajara"

-- What the evidence script printed on 2026-09-25, give or take: the orphan on
-- :3029 (pid 94743, its own group), our fresh launch on :3030 (pgid 77380,
-- matching the pidfile), and a split bind on :3040 — our process on IPv4, a
-- stranger from another directory on IPv6.
sample :: String
sample = String.joinWith "\n"
  [ "#listen"
  , "p94743"
  , "f21"
  , "n127.0.0.1:3029"
  , "p77387"
  , "n*:3030"
  , "p5001"
  , "n127.0.0.1:3040"
  , "p6002"
  , "n[::1]:3040"
  , "#ps"
  , "94743 94743 Sun Sep 20 11:34:15 2026 node server.mjs"
  , "77387 77380 Fri Sep 25 18:55:32 2026 node server.mjs --port 3030"
  , " 5001  5000 Fri Sep 25 10:00:00 2026 python3 -m http.server 3040"
  , " 6002  6002 Tue Sep 01 09:00:00 2026 python3 -m http.server 3040"
  , "#cwd"
  , "p94743"
  , "fcwd"
  , "n" <> itajaraDir
  , "p77387"
  , "n" <> itajaraDir
  , "p5001"
  , "n/srv/site"
  , "p6002"
  , "n/somewhere/else"
  , "#recorded"
  , "friends-of-itajara\t77380"
  , "friend-b\t77380"
  , "site\t5000"
  , "nobody\t"
  , "#end"
  ]

judge :: { sid :: ServiceId, ports :: Array Port, cwd :: Maybe String } -> Holding
judge = judgeHolding (readHoldingEvidence { ran: true, output: sample })

spec :: Spec Unit
spec = describe "Bosun.Holding" do

  describe "judgeHolding" do

    it "the 2026-09-25 case: an orphan from the service's own directory is a CLAIMABLE stranger" do
      let h = judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Just itajaraDir }
      holdingTag h `shouldEqual` "stranger"
      map _.pid (strangers h) `shouldEqual` [ mkPid 94743 ]
      claimable h `shouldEqual` Just true

    it "the same orphan seen from a service in another directory is NOT claimable" do
      let h = judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Just "/elsewhere" }
      claimable h `shouldEqual` Just false

    it "a service with no registered directory can claim nothing" do
      claimable (judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Nothing })
        `shouldEqual` Just false

    it "compares the PHYSICAL directory: /tmp/x registered, /private/tmp/x reported, is the same place" do
      let
        ev = readHoldingEvidence
          { ran: true
          , output: String.joinWith "\n"
              [ "#listen", "p4242", "n*:8771", "#ps", "4242 4242 Fri Sep 25 23:40:00 2026 python3 -m http.server 8771"
              , "#cwd", "p4242", "n/private/tmp/bosun-hello", "#recorded", "#physical", "greeter\t/private/tmp/bosun-hello", "#end"
              ]
          }
      claimable (judgeHolding ev { sid: sid "greeter", ports: [ port 8771 ], cwd: Just "/tmp/bosun-hello" })
        `shouldEqual` Just true

    it "a trailing slash on the registered directory does not change the answer" do
      claimable (judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Just (itajaraDir <> "/") })
        `shouldEqual` Just true

    it "a listener in the recorded process group is ours" do
      holdingTag (judge { sid: sid "friend-b", ports: [ port 3030 ], cwd: Just itajaraDir })
        `shouldEqual` "ours"

    it "a split bind is a stranger even though our own process is there too" do
      let h = judge { sid: sid "site", ports: [ port 3040 ], cwd: Just "/srv/site" }
      holdingTag h `shouldEqual` "stranger"
      map _.pid (strangers h) `shouldEqual` [ mkPid 6002 ]
      oursOf h `shouldEqual` [ mkPid 5001 ]
      claimable h `shouldEqual` Just false

    it "nothing on the port is Unheld" do
      holdingTag (judge { sid: sid "nobody", ports: [ port 3999 ], cwd: Nothing }) `shouldEqual` "none"

    it "a service with no TCP port is not judged" do
      holdingTag (judge { sid: sid "nobody", ports: [], cwd: Nothing }) `shouldEqual` "no-port"

    it "a script that never reached its end marker is unobservable, never Unheld" do
      let
        cut = String.joinWith "\n" (A.takeWhile (_ /= "#recorded") (String.split (Pattern "\n") sample))
        h = judgeHolding (readHoldingEvidence { ran: true, output: cut })
          { sid: sid "nobody", ports: [ port 3999 ], cwd: Nothing }
      holdingTag h `shouldEqual` "unobservable"

    it "a host without lsof is unobservable" do
      holdingTag (judgeHolding (readHoldingEvidence { ran: true, output: "#no-lsof" }) { sid: sid "x", ports: [ port 3029 ], cwd: Nothing })
        `shouldEqual` "unobservable"

    it "a script that did not run is unobservable" do
      holdingTag (judgeHolding (readHoldingEvidence { ran: false, output: sample }) { sid: sid "x", ports: [ port 3029 ], cwd: Nothing })
        `shouldEqual` "unobservable"

  describe "holdingScript" do

    it "asks lsof about every port, in both address families, and reads each pidfile" do
      let s = holdingScript [ port 3029, port 3040 ] [ { sid: sid "friends-of-itajara", cwd: Just itajaraDir }, { sid: sid "a:b", cwd: Nothing } ]
      A.all (\needle -> String.contains (Pattern needle) s)
        [ "-iTCP:3029", "-iTCP:3040", "-sTCP:LISTEN", "#end"
        , "/tmp/bosun-apply-friends-of-itajara.pid", "printf '%s\\t%s\\n' a:b"
        , "#physical", "pwd -P"
        ] `shouldEqual` true

    it "resolves each registered directory, but only for services that have one" do
      let s = holdingScript [ port 3029 ] [ { sid: sid "friends-of-itajara", cwd: Just itajaraDir }, { sid: sid "a:b", cwd: Nothing } ]
      A.length (A.filter (String.contains (Pattern "pwd -P")) (String.split (Pattern "\n") s)) `shouldEqual` 1

  describe "reap" do

    it "reads each stranger's verdict back by pid" do
      let
        hs = strangers (judge { sid: sid "site", ports: [ port 3040 ], cwd: Nothing })
          <> strangers (judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Nothing })
      map snd (readReap "bosun-reap:6002:reaped\nbosun-reap:94743:refused" hs)
        `shouldEqual` [ StrangerReaped, StrangerRefused ]

    it "a stranger the script said nothing about is unreadable, not reaped" do
      let hs = strangers (judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Nothing })
      map snd (readReap "" hs) `shouldEqual` [ ReapUnreadable ]

    it "never signals the supervisor's own process group" do
      let s = reapScript (strangers (judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Nothing }))
      String.contains (Pattern "!= \"$me\"") s `shouldEqual` true

  describe "settleTeardown (down, with the port looked at)" do

    let
      orphan = judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Just itajaraDir }
      elsewhere = judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Just "/elsewhere" }
      reapedWith v = map (\h -> Tuple h v) (strangers orphan)

    it "the 09-08 case: no record, a claimable orphan stopped — the service IS down" do
      (settleTeardown NoRecord orphan (reapedWith StrangerReaped)).verdict `shouldEqual` Reaped

    it "our group reaped and an orphan stopped too is still reaped" do
      (settleTeardown Reaped orphan (reapedWith StrangerReaped)).verdict `shouldEqual` Reaped

    it "if OUR group would not die, that stays the answer even when the orphan went" do
      (settleTeardown Survived orphan (reapedWith StrangerReaped)).verdict `shouldEqual` Survived

    it "an orphan the kernel refused to signal makes the service refused" do
      (settleTeardown AlreadyGone orphan (reapedWith StrangerRefused)).verdict `shouldEqual` Refused

    it "an orphan that outlived TERM and KILL makes the service survived" do
      (settleTeardown Reaped orphan (reapedWith StrangerSurvived)).verdict `shouldEqual` Survived

    it "a foreign holder is untouched: no-record stays unsettled, and the note names it" do
      let r = settleTeardown NoRecord elsewhere []
      r.verdict `shouldEqual` NoRecord
      map (String.contains (Pattern "not touched")) r.note `shouldEqual` Just true

    it "a free port changes nothing and says nothing" do
      let r = settleTeardown Reaped Unheld []
      r.verdict `shouldEqual` Reaped
      r.note `shouldEqual` Nothing

  describe "holdingJson" do

    it "names the stranger, and says whether it may be claimed" do
      holdingJson (judge { sid: sid "friends-of-itajara", ports: [ port 3029 ], cwd: Just itajaraDir })
        `shouldEqual`
          ( "{ \"verdict\": \"stranger\", \"claimable\": true, \"pids\": [94743], \"ours\": [], \"detail\": "
              <> "\"pid 94743 (node server.mjs, since Sun Sep 20 11:34:15 2026, in " <> itajaraDir <> ")\" }"
          )

    it "escapes what a command line can contain" do
      jsonString "say \"hi\"\\now\n" `shouldEqual` "\"say \\\"hi\\\"\\\\now\\n\""

  where
  claimable = case _ of
    Stranger st -> Just st.claimable
    _ -> Nothing
  oursOf = case _ of
    Stranger st -> map _.pid st.ours
    _ -> []
