-- | The supervisor's pure tick-transition (`Bosun.Supervisor`). These pin the
-- | relaunch-storm fix (HANDOFF-ENGINE.md): a launched service whose process
-- | GROUP is alive but whose readiness hasn't passed reads `Starting`, NOT
-- | `Down` — so the planner `NoOp`s it instead of re-`Start`ing it every tick.
-- | Plus the boot-grace / crash / backoff / badge state machine, time as a
-- | parameter (the same determinism that lets it ride go-conformance).
module Test.Bosun.SupervisorSpec where

import Prelude

import Bosun.Atoms (ServiceId, mkEnvVar, mkServiceId, unServiceId)
import Bosun.Plan (Reason(..), Status(..))
import Bosun.Service (Deployment, Service, mkDeployment, unValidatedDeployment)
import Bosun.Report (renderAddressMiss)
import Bosun.Serve (controlPort)
import Bosun.Supervisor (AddressMiss(..), Observation, SupConfig, SvcState, addressService, backoffMs, emptySupState, forgetLaunches, initialSvc, recordLaunches, refine, superviseDiff)
import Bosun.Validate (validate)
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Test.Bosun.ApplySpec (procLeaf, procLeafEnv)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldNotEqual)

sid :: String -> ServiceId
sid = mkServiceId

-- Validate a fixture deployment and pull out its ServiceId→Service map — the
-- input `superviseDiff` compares. (These leaf fixtures always validate.)
servicesOf :: Deployment -> Map ServiceId Service
servicesOf d = case toEither (validate d) of
  Left _ -> Map.empty
  Right vd -> (unValidatedDeployment vd).services

names :: Array ServiceId -> Array String
names = map unServiceId

-- `Status` has no `Show` (it's pattern-matched, not printed, in the core); a
-- local token lets these assertions read with `shouldEqual`.
tok :: Status -> String
tok = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"

-- The default-shaped config (60s grace, 5s→60s backoff, retry forever).
cfg :: SupConfig
cfg = { bootGraceMs: 60000.0, backoffBaseMs: 5000.0, backoffMaxMs: 60000.0, maxRetries: Nothing }

-- Refine a single service and read back its refined status (as a token) + state.
one :: SupConfig -> Number -> SvcState -> Observation -> { status :: String, svc :: SvcState }
one c now prev o =
  let r = refine c now (Map.singleton (sid "x") prev) (Map.singleton (sid "x") o)
  in { status: tok (fromMaybe Down (Map.lookup (sid "x") r.snapshot))
     , svc: fromMaybe (initialSvc now) (Map.lookup (sid "x") r.state)
     }

spec :: Spec Unit
spec = describe "Bosun.Supervisor" do

  describe "refine — the launch-memory state machine" do

    it "launched + group alive + not ready ⇒ Starting (the storm fix: no relaunch)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Starting }
      (one cfg 2000.0 prev { ready: Down, groupAlive: true }).status `shouldEqual` "starting"

    it "launched + group GONE ⇒ Failed (a crash ⇒ Restart)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Running }
      (one cfg 2000.0 prev { ready: Down, groupAlive: false }).status `shouldEqual` "failed"

    -- The pair below is the whole of the distinction, and the absence of the
    -- second one is what let the relaunch storm through: `reconcile` runs on
    -- entry to `raised`, i.e. in the same instant `bring-up` ran the launch
    -- scripts, and at that distance no child has a process group yet. Read as
    -- a crash, every specimen was relaunched the moment it was started.
    --
    -- What separates them is not the observation — that is identical — but
    -- whether the service was ever seen up under THIS launch.
    it "launched, group not visible YET, never seen up ⇒ Starting (not a crash)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Down }
      (one cfg 1000.0 prev { ready: Down, groupAlive: false }).status `shouldEqual` "starting"

    it "…and the grace is spent, not indefinite: past it, the same reading is Failed" do
      let prev = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Down }
      (one cfg 61001.0 prev { ready: Down, groupAlive: false }).status `shouldEqual` "failed"

    it "…while a relaunch after a crash gets the grace again (status Failed, not Running)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Failed }
      (one cfg 1500.0 prev { ready: Down, groupAlive: false }).status `shouldEqual` "starting"

    it "never launched + down ⇒ Down (bring it up)" do
      (one cfg 2000.0 (initialSvc 0.0) { ready: Down, groupAlive: false }).status `shouldEqual` "down"

    it "ready ⇒ Running, and recovery resets fails + clears the backoff window" do
      let prev = (initialSvc 0.0) { fails = 3, suspendedUntil = Just 9999.0, status = Failed }
          r = one cfg 2000.0 prev { ready: Running, groupAlive: true }
      r.status `shouldEqual` "running"
      r.svc.fails `shouldEqual` 0
      r.svc.suspendedUntil `shouldEqual` Nothing

    it "within the backoff window ⇒ InBackoff (don't pile on a fast-crash loop)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 500.0, suspendedUntil = Just 5000.0, fails = 1 }
      (one cfg 2000.0 prev { ready: Down, groupAlive: false }).status `shouldEqual` "in-backoff"

    it "alive but past boot-grace without binding ⇒ Failed (wedged)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 0.0, status = Starting }
      (one cfg 61000.0 prev { ready: Down, groupAlive: true }).status `shouldEqual` "failed"

    it "no probe but group alive ⇒ Running (process-exists is the signal)" do
      let prev = (initialSvc 0.0) { launchedAt = Just 1000.0 }
          o = { ready: Unknown (ProbeUnreachable "no probe"), groupAlive: true }
      (one cfg 2000.0 prev o).status `shouldEqual` "running"

    it "since advances only when the refined status actually changes" do
      let downToStarting = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Down, since = 0.0 }
          r1 = one cfg 2000.0 downToStarting { ready: Down, groupAlive: true }
      r1.status `shouldEqual` "starting"
      r1.svc.since `shouldEqual` 2000.0
      let stillStarting = (initialSvc 0.0) { launchedAt = Just 1000.0, status = Starting, since = 2000.0 }
          r2 = one cfg 5000.0 stillStarting { ready: Down, groupAlive: true }
      r2.svc.since `shouldEqual` 2000.0

    it "regression: a slow-boot service does NOT storm — Starting every tick within grace" do
      let
        step now st = (refine cfg now st (Map.singleton (sid "x") { ready: Down, groupAlive: true })).state
        go n now st = if n <= 0 then st else go (n - 1) (now + 3000.0) (step now st)
        seed = Map.singleton (sid "x") ((initialSvc 0.0) { launchedAt = Just 0.0, status = Starting })
        s = fromMaybe (initialSvc 0.0) (Map.lookup (sid "x") (go 5 3000.0 seed))
      -- five 3s ticks (15s, well inside the 60s grace): stays Starting, never relaunched
      tok s.status `shouldEqual` "starting"
      s.restarts `shouldEqual` 0

  describe "recordLaunches — stamping launch memory after the plan" do

    it "a Restart bumps the badge + consecutive fails and arms exponential backoff" do
      let st = recordLaunches cfg 1000.0 [ { id: sid "x", isRestart: true } ] emptySupState
          s = fromMaybe (initialSvc 0.0) (Map.lookup (sid "x") st)
      s.restarts `shouldEqual` 1
      s.fails `shouldEqual` 1
      s.launchedAt `shouldEqual` Just 1000.0
      s.suspendedUntil `shouldEqual` Just 6000.0   -- 1000 + backoff(1)=5000
      tok s.status `shouldEqual` "starting"

    it "a Start (first bring-up) sets launchedAt but no backoff and no badge bump" do
      let st = recordLaunches cfg 1000.0 [ { id: sid "x", isRestart: false } ] emptySupState
          s = fromMaybe (initialSvc 0.0) (Map.lookup (sid "x") st)
      s.restarts `shouldEqual` 0
      s.launchedAt `shouldEqual` Just 1000.0
      s.suspendedUntil `shouldEqual` Nothing
      tok s.status `shouldEqual` "starting"

  describe "backoffMs — exponential, capped" do
    it "doubles per consecutive failure up to the cap" do
      backoffMs cfg 1 `shouldEqual` 5000.0
      backoffMs cfg 2 `shouldEqual` 10000.0
      backoffMs cfg 3 `shouldEqual` 20000.0
      backoffMs cfg 4 `shouldEqual` 40000.0
      backoffMs cfg 5 `shouldEqual` 60000.0    -- 80000 capped
      backoffMs cfg 10 `shouldEqual` 60000.0   -- well past the cap

  -- The hot-reload diff (note #397): what a `POST /control/reload` must do to the
  -- running group. Signature = launch spec + host, so only a real launch change
  -- restarts; an unchanged service is left running (its launch memory preserved,
  -- the double-launch guard).
  describe "superviseDiff — hot-reload partition" do

    it "identical spec ⇒ everything unchanged, nothing stopped" do
      let
        d = mkDeployment [ procLeaf "a" "/srv/a" "run-a", procLeaf "b" "/srv/b" "run-b" ]
        r = superviseDiff (servicesOf d) (servicesOf d)
      names r.unchanged `shouldEqual` [ "a", "b" ]
      r.changed `shouldEqual` []
      r.added `shouldEqual` []
      r.removed `shouldEqual` []

    it "a changed command ⇒ that service is `changed`, the rest unchanged" do
      let
        old = mkDeployment [ procLeaf "a" "/srv/a" "run-a", procLeaf "b" "/srv/b" "run-b" ]
        new = mkDeployment [ procLeaf "a" "/srv/a" "run-a", procLeaf "b" "/srv/b" "run-b --flag" ]
        r = superviseDiff (servicesOf old) (servicesOf new)
      names r.changed `shouldEqual` [ "b" ]
      names r.unchanged `shouldEqual` [ "a" ]

    it "a changed ENV value ⇒ `changed` (the SuperDirt device-name case, #397/#398)" do
      let
        old = mkDeployment [ procLeafEnv "sd" "/srv/sd" "./boot.sh" [] ]
        new = mkDeployment [ procLeafEnv "sd" "/srv/sd" "./boot.sh" [ Tuple (mkEnvVar "SUPERDIRT_DEVICE") "BlackHole 2ch" ] ]
        r = superviseDiff (servicesOf old) (servicesOf new)
      names r.changed `shouldEqual` [ "sd" ]

    it "added and removed services are classified, not restarted" do
      let
        old = mkDeployment [ procLeaf "a" "/srv/a" "run-a", procLeaf "b" "/srv/b" "run-b" ]
        new = mkDeployment [ procLeaf "a" "/srv/a" "run-a", procLeaf "c" "/srv/c" "run-c" ]
        r = superviseDiff (servicesOf old) (servicesOf new)
      names r.added `shouldEqual` [ "c" ]
      names r.removed `shouldEqual` [ "b" ]
      names r.unchanged `shouldEqual` [ "a" ]
      r.changed `shouldEqual` []

  describe "forgetLaunches — drop memory for stopped services on reload" do
    it "removes exactly the listed services, preserving the rest (the guard)" do
      let
        st = recordLaunches cfg 1000.0
          [ { id: sid "keep", isRestart: false }, { id: sid "drop", isRestart: false } ]
          emptySupState
        st' = forgetLaunches [ sid "drop" ] st
      Map.member (sid "drop") st' `shouldEqual` false
      Map.member (sid "keep") st' `shouldEqual` true

  -- `serve` addresses routes by PORT; a supervise group addresses services by
  -- ID. Asking the wrong one used to answer `no service `X` in this group` for
  -- four different mistakes — true, and it reads as "that daemon is not
  -- running" about a daemon that is running fine somewhere this component
  -- cannot see (FINDINGS-supervision-blind-spots.md §4). The router's half was
  -- fixed in bd28adc; this is the group's half.
  describe "addressService — reading a ?service= argument against a group" do
    let group = [ sid "itajara:worker", sid "continuo:worker", sid "ticker" ]

    it "the exact canonical id is what the surface acts on" do
      addressService group "itajara:worker" `shouldEqual` Right (sid "itajara:worker")

    it "a port is the ROUTER's key and can never be a service id" do
      -- The trap itself: `?service=3028` on a group.
      addressService group "3028" `shouldEqual` Left (LooksLikePort 3028)

    it "a missing ?service= is its own mistake, not an unnamed service" do
      -- It used to land in the same sentence, with empty backticks.
      addressService group "" `shouldEqual` Left Unnamed

    it "a bare slug where the group holds `slug:role` is a near miss, and is NAMED" do
      addressService group "itajara" `shouldEqual` Left (NearMiss (sid "itajara:worker"))

    it "and a `slug:role` where the group holds the bare compose name, the other way" do
      addressService group "ticker:worker" `shouldEqual` Left (NearMiss (sid "ticker"))

    it "a near miss is REPORTED, never acted on — no Right comes back from one" do
      -- A control surface that restarts something other than what it was asked
      -- for is the habit these refusals exist to prevent.
      addressService group "itajara" `shouldNotEqual` Right (sid "itajara:worker")

    it "two services under one slug is a different answer again: name which" do
      let two = [ sid "polyglot:site", sid "polyglot:api" ]
      addressService two "polyglot" `shouldEqual` Left (Ambiguous [ sid "polyglot:site", sid "polyglot:api" ])

    it "nothing under any spelling ⇒ not in this group" do
      addressService group "es9-daemon" `shouldEqual` Left NotInGroup

    it "the five findings are distinct — one sentence for four of them was the bug" do
      map (addressService group) [ "", "3028", "itajara", "es9-daemon" ]
        `shouldEqual` [ Left Unnamed, Left (LooksLikePort 3028), Left (NearMiss (sid "itajara:worker")), Left NotInGroup ]

  describe "renderAddressMiss — the refusal names what to do next" do
    let ctx asked = { verb: "restart", asked, routerPort: controlPort }
        has needle hay = String.contains (String.Pattern needle) hay

    it "a port refusal sends the operator to the router, with the command" do
      let m = renderAddressMiss (ctx "3028") (LooksLikePort 3028)
      has "is a port" m `shouldEqual` true
      has "POST :3997/control/stop?port=3028" m `shouldEqual` true

    it "and it points at `stop`, not `restart`: the router has no restart verb" do
      -- Sending someone to a verb that would 404 would undo the point of the
      -- sentence.
      has "/control/restart?port=" (renderAddressMiss (ctx "3028") (LooksLikePort 3028)) `shouldEqual` false

    it "a near miss prints the full id, so the retry is unambiguous" do
      has "`itajara:worker`" (renderAddressMiss (ctx "itajara") (NearMiss (sid "itajara:worker"))) `shouldEqual` true

    it "an absent service names the lazy-spawn case rather than only the group" do
      let m = renderAddressMiss (ctx "itajara") NotInGroup
      has "LAZY-SPAWNED" m `shouldEqual` true
      has ":3997/state" m `shouldEqual` true

    it "every refusal says where to look, so none of them is only a `no`" do
      let msgs = map (renderAddressMiss (ctx "x"))
            [ Unnamed, LooksLikePort 3028, NearMiss (sid "a:b"), Ambiguous [ sid "a:b", sid "a:c" ], NotInGroup ]
      map (\m -> has "/state" m || has "Name one" m) msgs
        `shouldEqual` [ true, true, true, true, true ]
