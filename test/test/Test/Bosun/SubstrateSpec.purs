-- | The supervision substrate's TEARDOWN half — `TeardownVerdict` and the two
-- | pure functions that surround the one shell line that can establish it.
-- |
-- | The bug these exist to close: `bosun down` rendered
-- | `kill -- -"$(cat …)" 2>/dev/null || true`, so a missing pidfile made `cat`
-- | fail, `kill -- -""` error, and `|| true` swallow it — and the stage
-- | "succeeded" having signalled nothing. `POST /control/down` over
-- | `fixtures/hello` answered `{"ok":true}` with both servers still listening.
-- |
-- | Same shape as `ServeSpec`'s `brokerStopVerdict` cases: the evidence is what
-- | the exec edge can see (did the shell run, what did it print), the weighing
-- | is pure, so it is testable here AND lowers to the Go column unchanged.
module Test.Bosun.SubstrateSpec where

import Prelude

import Bosun.Atoms (ServiceId, mkServiceId)
import Bosun.Report (renderTeardown, renderTeardownSummary)
import Bosun.Substrate (TeardownVerdict(..), allTeardownVerdicts, daemonize, OS(..), pidStop, readTeardown, teardownSettled, teardownTag)
import Data.Array as A
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

sid :: String -> ServiceId
sid = mkServiceId

-- what the exec edge saw, with the shell having run
spoke :: String -> TeardownVerdict
spoke out = readTeardown { ran: true, output: out }

spec :: Spec Unit
spec = describe "Bosun.Substrate (teardown)" do

  describe "readTeardown" do

    -- Each verdict must survive the round trip through the token the shell
    -- prints. A token that no reader recognises would silently become
    -- `Unreadable` — an honest answer, but the wrong one.
    it "reads back every token pidStop can print" $
      map (spoke <<< ("bosun-stop:" <> _) <<< teardownTag) allTeardownVerdicts
        `shouldEqual` allTeardownVerdicts

    -- The tokens travel through whatever a remote shell prepends. Matching on a
    -- substring rather than the whole of stdout is what makes that survivable.
    it "finds the token amid a remote shell's own chatter" $
      spoke "Warning: no tty present\nbosun-stop:reaped\n" `shouldEqual` Reaped

    -- THE CASE THE OLD CODE GOT WRONG. A stop that produced nothing readable is
    -- not a stop that worked; it is a stop about which nothing is known.
    it "silence is Unreadable, never success" $
      spoke "" `shouldEqual` Unreadable

    it "a shell that never ran is Unreadable whatever it printed" $
      readTeardown { ran: false, output: "bosun-stop:reaped" } `shouldEqual` Unreadable

  describe "teardownSettled" do

    -- Two verdicts, and only two, mean the service is down. `NoRecord` looks
    -- innocent and is the commonest of the failures, which is exactly why it
    -- must not be here.
    it "only Reaped and AlreadyGone establish that the service is down" $
      A.filter teardownSettled allTeardownVerdicts `shouldEqual` [ Reaped, AlreadyGone ]

  describe "renderTeardownSummary" do

    it "an all-clear reads as a count" $
      renderTeardownSummary [ Tuple (sid "a") Reaped, Tuple (sid "b") AlreadyGone ]
        `shouldEqual` "2 stopped"

    it "nothing to stop says so rather than claiming a success" $
      renderTeardownSummary [] `shouldEqual` "nothing to stop"

    -- The failures come FIRST and are named. "1 of 2 stopped" is the shape of
    -- sentence an operator reads as "fine".
    it "a partial teardown leads with what did NOT stop, by name" $
      renderTeardownSummary [ Tuple (sid "hello:greeter") NoRecord, Tuple (sid "hello:echoer") Reaped ]
        `shouldEqual` "1 NOT STOPPED (hello:greeter: no-record); 1 stopped"

  describe "renderTeardown" do

    -- Three of the six are not a stop, and an operator scanning a teardown log
    -- must be able to see that without reading a sentence.
    it "every verdict that is not a stop says so in capitals" $
      map (\v -> String.contains (Pattern "NOT STOPPED") (renderTeardown (sid "a") v)
                   || String.contains (Pattern "UNKNOWN") (renderTeardown (sid "a") v))
          (A.filter (not <<< teardownSettled) allTeardownVerdicts)
        `shouldEqual` [ true, true, true, true ]

    -- A message that names no next command leaves the operator where the old
    -- silent `|| true` did.
    it "each failure names the pidfile or an instrument to find the holder with" $
      map (\v -> String.contains (Pattern "/tmp/bosun-apply-a.pid") (renderTeardown (sid "a") v)
                   || String.contains (Pattern "lsof") (renderTeardown (sid "a") v))
          [ NoRecord, Survived, Refused ]
        `shouldEqual` [ true, true, true ]

  describe "pidStop" do

    -- `Report.renderCommand` wraps a remote command as `ssh dest '<inner>'`, so
    -- one apostrophe in this script would close that quote and hand the rest to
    -- the LOCAL shell.
    it "renders no single quote (it is ssh-wrapped in them)" $
      String.contains (Pattern "'") (pidStop (sid "a")) `shouldEqual` false

    -- It must exit 0 whatever it finds: one service that cannot be stopped is a
    -- reason to keep going and stop the rest. That is why the exit code carries
    -- no information and the printed token does.
    it "carries no `|| true` — the verdict is the report, not the exit code" $
      String.contains (Pattern "|| true") (pidStop (sid "a")) `shouldEqual` false

  describe "daemonize" do

    -- The `alreadyBackgrounds` passthrough that used to short-circuit this is
    -- gone: a trailing `&` is dropped and the command tracked like any other,
    -- so its Stop has a group to kill.
    it "a self-backgrounding command renders identically to the same command without the &" $
      daemonize MacOS (sid "a") "run-a &" `shouldEqual` daemonize MacOS (sid "a") "run-a"

    it "still records a pgid for a self-backgrounding command" $
      String.contains (Pattern "/tmp/bosun-apply-a.pid") (daemonize MacOS (sid "a") "run-a &")
        `shouldEqual` true

    -- `2>&1 &` ends in two ampersands one character apart; only the last is the
    -- backgrounding one.
    it "drops only the trailing & and leaves 2>&1 intact" $
      String.contains (Pattern "2>&1 >/tmp/bosun-apply-a.log") (daemonize MacOS (sid "a") "srv >s.log 2>&1 &")
        `shouldEqual` true
