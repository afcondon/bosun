-- | DESIGN §7 / BOSUN-SERVE.md — `servePlan`, the PURE heart of `bosun serve`,
-- | the typed lazy-spawn router that replaces SDI.
-- |
-- | The reconciler and the router are the *same* typed model, seen as **batch**
-- | (`apply` once) vs **resident** (`serve` forever). A lazy-spawn is just
-- | "`apply` one service, on demand." So the interesting part of `serve` — the
-- | part with the value — is pure and total: given the reconciled `Deployment`,
-- | decide which services are *routable* and, for each, the rewritten launch
-- | command + the internal port the backend should bind. The resident HTTP front
-- | (bind / spawn / poll / proxy / idle-reap) is a thin foreign shim driven by
-- | this plan (`Bosun.CLI.Serve`), exactly as `applyScript` (pure) drives
-- | `execLine` (effectful).
-- |
-- | This is the **admission control** win over SDI: a service gets a bound port
-- | only if it can actually be routed. The SDI contract (§7.2 — a spawnable row
-- | needs an absolute `cd` anchor and must embed its literal public port so the
-- | rewrite has somewhere to land) becomes a typed `Rejection` *at startup* with
-- | a clear reason, not a silent skip (SDI) or a 3am failure on first request.
-- |
-- | P1 scope (the node-column MVP): local `Process` services with a `HostPort`.
-- | Remote hosts, containers, and the WebSocket/421/hot-reload refinements are
-- | P2/P3 (BOSUN-SERVE.md §5).
module Bosun.Serve
  ( Route
  , Redirect
  , Mediation(..)
  , mediationTag
  , readMediation
  , ServeHint
  , Broker
  , StopVerdict(..)
  , stopVerdictTag
  , brokerStopVerdict
  , BrokerDoor(..)
  , DoorFacts
  , doorTag
  , brokerDoor
  , RejectReason(..)
  , Rejection
  , ServePlan
  , servePlan
  , servePlanWith
  , ServeDiff
  , serveDiff
  , DriftKind(..)
  , PortDrift
  , PortClaim
  , planDrift
  , internalOffset
  , internalPort
  , defaultIdleMs
  ) where

import Prelude

import Bosun.Atoms (Host, Port, mkHost, mkPort, unAbsPath, unHost, unPort, unServiceId)
import Bosun.Error (SdiViolation(..))
import Bosun.Executor (Executor(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Health (Probe(..))
import Bosun.Protocol (Locator)
import Bosun.Reachability (classify)
import Bosun.Service (Deployment, LooseService, deploymentServices)
import Bosun.Target (defaultTargets, networkAddr)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Generic.Rep (class Generic)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..), Replacement(..))
import Data.String as String
import Data.Tuple (Tuple(..))

-- | The internal-port convention carried over from SDI unchanged: the router
-- | owns the *public* port and moves the backend onto `public + 20000`
-- | (e.g. `3007 → 23007`). Something must hold the public port to catch the very
-- | first request, and a backend cannot bind a port the router already holds —
-- | so the backend lives on the internal port and the router proxies to it.
internalOffset :: Int
internalOffset = 20000

internalPort :: Int -> Int
internalPort public = public + internalOffset

-- | SDI's 10-minute idle timeout (`SDI_IDLE_TIMEOUT_MS`), carried over.
defaultIdleMs :: Int
defaultIdleMs = 600_000

-- | An admitted service: everything the resident front needs to lazy-spawn and
-- | proxy it. All fields are primitive so the record marshals cleanly to the
-- | foreign shim (JS today, Go in P3) with no decoding.
-- |
-- | `launchCommand` is the registry command with the public port rewritten to
-- | the internal port — but NOT daemonised: unlike `apply` (fire-and-forget),
-- | `serve` *manages* each child's lifetime (it holds the spawn handle to
-- | SIGTERM on idle), so detaching it would be wrong. The shim spawns it,
-- | redirects its output to a log, and keeps the handle.
type Route =
  { serviceId     :: String
  , publicPort    :: Int
  , internalPort  :: Int
  , cwd           :: String
  , launchCommand :: String
  , idleTimeoutMs :: Int
  }

-- | **Does Bosun belong in the data path for this service at all?**
-- |
-- | That is the whole question, and it is deliberately NOT "does it speak HTTP".
-- | The registry field is called `serveMode` and its two values are `proxy` and
-- | `broker`, because the distinction an operator is making is about the ROUTER,
-- | not about the protocol:
-- |
-- | * `Proxy` (the default, and what every existing row means) — the router owns
-- |   the public port and relays the bytes. Right for an ordinary dev server:
-- |   you type the registered port and it works, spawn included.
-- | * `Broker` — the router ensures the service is running and says WHERE it is,
-- |   then has nothing to do with the traffic. Right for anything that (a) owns
-- |   a hardware resource, (b) is long-lived and started deliberately rather
-- |   than per-request, or (c) carries timing-critical traffic.
-- |
-- | For a whole class of this rig's daemons `Broker` is not an optimisation but
-- | the only thing that can work: es9-daemon and the fh2 daemon are reached over
-- | UNIX DOMAIN SOCKETS and link-spike over UDP MULTICAST, and none of those can
-- | be relayed through a TCP reverse proxy in any meaningful sense. itajara —
-- | a 30 Hz WebSocket over an audio interface — merely *shouldn't* be.
-- |
-- | The default is `Proxy` so that a registry row which says nothing keeps its
-- | current behaviour exactly: broker mode is opt-in, per service, and no
-- | existing entry changes by being re-read.
data Mediation = Proxy | Broker
derive instance Eq Mediation
derive instance Generic Mediation _
instance Show Mediation where show = genericShow

-- | The wire token, as it appears in the registry's `serveMode`.
mediationTag :: Mediation -> String
mediationTag = case _ of
  Proxy -> "proxy"
  Broker -> "broker"

-- | Read the registry's `serveMode`. Lenient, like the rest of the registry
-- | decode: an absent or unrecognised value is `Proxy`, so a typo degrades to
-- | today's behaviour rather than un-routing a service. The refusal to guess is
-- | somebody else's job — this is an ingest, and the safe reading is the status
-- | quo.
readMediation :: String -> Mediation
readMediation = case _ of
  "broker" -> Broker
  _ -> Proxy

-- | The serve-specific hints one registry ROW carries, read straight from the
-- | raw JSON (`Bosun.Adapters.Registry.registryHints`) rather than through the
-- | IR — the same shape and the same reason as `PortClaim` below: these are
-- | facts about how the ROUTER should treat the row, not facts about the
-- | service, and threading them through reconcile would put a deployment
-- | concern into the deployment IR.
-- |
-- | `scheme` is the scheme of the row's `url` (`ws`, `http`, `udp`, …). It earns
-- | its place twice: it is how a brokered answer can hand back a dialable URL
-- | (`ws://127.0.0.1:23028`, which is what the client actually needs), and it is
-- | the only place the registry says a listener is UDP — `Reachability` has no
-- | transport axis, and inventing one for a single bit would be a much larger
-- | change than reading a scheme that is already written down.
type ServeHint = { serviceId :: String, mediation :: Mediation, scheme :: Maybe String }

-- | A BROKERED service: everything the resident front needs to ensure it is
-- | running and then say where it is. Note what is NOT here — there is no idle
-- | timeout. A brokered service is by definition one that was started
-- | deliberately and holds something (a device, a multicast group, a socket
-- | file); reaping it because no request arrived for ten minutes is precisely
-- | the failure that made WebSocket services unsafe to router-manage in the
-- | first place (2026-08-17). The router starts these and leaves them alone.
-- |
-- | `publicPort` is `Just` only when the router can hold the registered port on
-- | the service's behalf — which needs the same public→internal rewrite the
-- | proxy path needs, so that the service is not fighting the router for it.
-- | When it can, the router binds that port and answers `307` there, so typing
-- | the registered port in a browser still lands on the service; when it
-- | cannot, the service simply keeps its own address and `/where` is the only
-- | way in. Both are legitimate; the difference is only whether Bosun can also
-- | catch a caller who dialled the old address.
-- |
-- | `declaredPort` is the port the REGISTRY ROW named, whether or not we ended
-- | up holding it. The two are equal for a broker we could move off its port
-- | and `Nothing`/`Just` respectively for one we could not — and keeping them
-- | apart is what stops a healthy portless broker being reported as
-- | `Unaccounted` drift (2026-08-23). `publicPort` answers "what does the
-- | router bind"; `declaredPort` answers "which registry claim is this the
-- | verdict on", and only the second can be correlated with the row.
type Broker =
  { serviceId     :: String
  , publicPort    :: Maybe Int
  , declaredPort  :: Maybe Int
  , cwd           :: String
  , launchCommand :: String
  -- where the service actually is, once running — the payload of `/where`
  , at            :: Locator
  -- how to tell that it IS running. Not a new concept: this is
  -- `Bosun.Health.Probe`, chosen by the same rule `Bosun.CLI.Observe`'s
  -- `effectiveProbe` uses (a service with no declared probe but a listening
  -- address is observable by that address), extended to the socket case that
  -- `observe` already implements as `SocketReady`.
  , probe         :: Probe
  }

-- | What `POST /control/stop` is entitled to do to a BROKERED service.
-- |
-- | Broker mode shipped able to START a service and not to stop it: `/where`
-- | lazy-spawns the daemon, so the router holds its child, but the control
-- | surface looked only at the proxy table and answered `no proxy route`. A
-- | surface that can start what it cannot stop teaches an operator to go round
-- | it for the pid, which is the habit it exists to prevent. Note this is a
-- | different act from taking the ROUTE down: unbinding a broker's 307 listener
-- | still does not stop the process, and must not.
-- |
-- | The rule is the proxy path's, not a second one. There, `adoptedBackend &&
-- | not child` refuses with 409 — bosun did not start it, so bosun must not
-- | kill it. A broker keeps no adoption flag to consult, because there is
-- | nothing to write it from: ensure-and-locate probes before it spawns and
-- | reports `started: false` on a survivor without recording the finding. So
-- | the fact is re-derived at the moment it is needed, which is where the proxy
-- | path arrived anyway — a remembered flag has no `exit` event to clear it,
-- | and `recheckAdopted` had to put it back on a clock.
-- |
-- | `Unknown` is the case a boolean would have hidden. A daemon with no
-- | checkable readiness signal (link-spike, UDP multicast) and no child of ours
-- | supports neither "I stopped it" nor "nothing was running": report unknown
-- | WITH the reason, the rule `Bosun.CLI.Observe` follows for a probe it cannot
-- | make, rather than an `ok` an operator reads as "the daemon is down".
data StopVerdict
  = Signal      -- ^ bosun holds the child; SIGTERM it and await the exit
  | Adopted     -- ^ it is running and is not ours — refuse, and name the reason
  | Unknown     -- ^ no child, and no probe that could say whether one is needed
  | Absent      -- ^ no child, and the probe says nothing is there to stop
derive instance Eq StopVerdict
derive instance Generic StopVerdict _
instance Show StopVerdict where show = genericShow

-- | The wire token the resident shim answers with.
stopVerdictTag :: StopVerdict -> String
stopVerdictTag = case _ of
  Signal -> "signal"
  Adopted -> "adopted"
  Unknown -> "unknown"
  Absent -> "absent"

-- | Decide it. `hasChild` is the router's own handle; `alive` is the probe just
-- | made; `probe` is the one the PLAN chose, and `NoProbe` is what separates
-- | `Unknown` from `Absent` — a failed check and an impossible check are not
-- | the same finding.
-- |
-- | Holding the child wins over everything: a service we started is ours to
-- | stop whether or not its probe currently answers, and a daemon that is slow
-- | to bind must not become unstoppable for the window in which it is starting.
brokerStopVerdict :: Boolean -> Boolean -> Probe -> StopVerdict
brokerStopVerdict hasChild alive probe
  | hasChild = Signal
  | alive = Adopted
  | otherwise = case probe of
      NoProbe -> Unknown
      _ -> Absent

-- | The standing of a brokered service's **307 door** — the listener on the
-- | registered public port. Not the daemon behind it: the door only ever
-- | answered "go over there", and everything about it is separate from whether
-- | the service is running (`unbindPort` takes a door down without touching the
-- | process, and it must).
-- |
-- | This exists because `bound :: Boolean` was carrying four situations at once
-- | in `/state`, and the comment beside it claimed two: a broker with no public
-- | port to hold (es9-daemon is a unix socket — the ordinary case, not a
-- | fault), one whose bind failed for a reason a probe will never clear, one
-- | the router stepped aside from because something else already held the port,
-- | and one the router holds. Only the third can be taken back, and until now
-- | nothing did: `recheckAdopted` walked the proxy table only, so a brokered
-- | port adopted at bind time stayed adopted forever — the `:3028` bug of
-- | 2026-08-17 re-appearing in the new bucket (RELAY-STALL-AND-BROKER-MODE.md
-- | §7.4).
-- |
-- | `DoorReclaim` is a verdict, not a state the router rests in: it means the
-- | holder has gone and the listen has not completed yet. It is visible in
-- | `/state` for the moment between, which is honest — "taking it back" is a
-- | different thing to report than "we hold it".
data BrokerDoor
  = NoDoor       -- ^ the row names no public port; there is nothing to hold
  | DoorOpen     -- ^ the router holds it and answers 307 there
  | DoorAside    -- ^ another process holds it and still answers; stay out of the way
  | DoorReclaim  -- ^ we stepped aside and the holder has gone: bind it again
  | DoorBlocked  -- ^ the bind failed for a reason no probe can clear (EACCES, …)
derive instance Eq BrokerDoor
derive instance Generic BrokerDoor _
instance Show BrokerDoor where show = genericShow

-- | The wire token, for `/state`'s `brokered[].door` and for the shim to
-- | compare against when it decides what to re-probe.
doorTag :: BrokerDoor -> String
doorTag = case _ of
  NoDoor -> "none"
  DoorOpen -> "open"
  DoorAside -> "aside"
  DoorReclaim -> "reclaim"
  DoorBlocked -> "blocked"

-- | What the shim can say about one door without being asked to judge it.
-- |
-- | `declaresPort` is closed over from the row by `brokerInfo`, exactly as
-- | `brokerStopVerdict` closes over the row's `Probe` — it is a fact about the
-- | PLAN, and asking the shim to hand it back would be a round-trip through the
-- | edge for something the core already knows.
-- |
-- | `holderAnswers` is the LAST EVIDENCE about the port, not an assumption:
-- | `true` from the `EADDRINUSE` that stood us aside (a bind that failed
-- | because something is there is a probe, of a sort), then `true`/`false` from
-- | each sweep's probe. There is no "we have not looked" case to represent,
-- | because the bind itself looked.
type DoorFacts =
  { declaresPort  :: Boolean
  , bound         :: Boolean
  , bindFailed    :: Boolean
  , holderAnswers :: Boolean
  }

-- | Weigh them. The order matters: a door that does not exist cannot be
-- | blocked, and a bind that failed for a non-`EADDRINUSE` reason is not a
-- | step-aside — re-listening on it every five seconds would be a permanent
-- | no-op dressed as recovery, which is why `DoorBlocked` is reported and left
-- | alone rather than swept.
brokerDoor :: DoorFacts -> BrokerDoor
brokerDoor f
  | not f.declaresPort = NoDoor
  | f.bindFailed = DoorBlocked
  | f.bound = DoorOpen
  | f.holderAnswers = DoorAside
  | otherwise = DoorReclaim

-- | Why a service is not routable (closed alternatives ⇒ ADT, §10). The first
-- | two are P1-scope limits; the `Sdi` cases are genuine contract violations
-- | that SDI would silently skip.
data RejectReason
  = NoHostPort            -- no host port to bind / route
  | NotAProcess           -- container/CDN/systemd/launchd — serve spawns Processes only
  | Sdi SdiViolation      -- PortNotInStartCommand / NoAbsoluteCwd
  | PortClaimed Int       -- another service already claims this public port
derive instance Eq RejectReason
derive instance Generic RejectReason _
-- Show for test/REPL diagnostics only (entry 73); user-facing text is
-- `Bosun.Report.renderReject`.
instance Show RejectReason where show = genericShow

-- | A refused service. `publicPort` is the port the row CLAIMED (`Nothing` only
-- | for `NoHostPort`, which claims none) — carried so a rejection can be
-- | correlated with the registry row that produced it. Public port is identity
-- | here as everywhere else in the router, and without it "the registry has a
-- | row on :3028" and "the router refused :3028" cannot be shown to be the same
-- | fact (`planDrift`).
type Rejection = { serviceId :: String, publicPort :: Maybe Int, reason :: RejectReason }

-- | A remote service (P2): the router can't spawn it here, but it CAN bind the
-- | public port and answer with a `421 Misdirected Request` pointing at where
-- | the service actually lives — SDI's "runs on <host>, try <tailscale-url>"
-- | behaviour, made a first-class outcome rather than a silent skip.
type Redirect =
  { serviceId  :: String
  , publicPort :: Int
  , host       :: String
  , target     :: String  -- the tailnet URL the client should use instead
  }

-- | The admission decision over a whole deployment: routes to bind+lazy-spawn,
-- | brokered services to ensure-and-locate, redirects to bind+421, and
-- | rejections (each with its typed reason). All four are reported, so nothing
-- | is silently dropped.
type ServePlan =
  { routes    :: Array Route
  , brokered  :: Array Broker
  , redirects :: Array Redirect
  , rejected  :: Array Rejection
  }

-- | The per-service verdict (internal; partitioned into the `ServePlan`).
data Admission = Admit Route | Broke Broker | Redir Redirect | Reject Rejection

-- | The unhinted plan: every service proxied, which is what the whole registry
-- | meant before broker mode existed. Kept as the plain arity so the corpus,
-- | the conformance Main and every existing caller are untouched — the default
-- | is not a value buried in a decoder, it is the absence of a hint.
servePlan :: Deployment -> ServePlan
servePlan = servePlanWith []

-- | The plan given the registry's per-row serve hints. A service with no hint
-- | (or a hint that says `proxy`) travels the identical path it did before.
servePlanWith :: Array ServeHint -> Deployment -> ServePlan
servePlanWith hints dep =
  foldr classify { routes: [], brokered: [], redirects: [], rejected: [] }
    (arbitrate (map (admit hintFor) (deploymentServices dep)))
  where
  hintMap = Map.fromFoldable (map (\h -> Tuple h.serviceId h) hints)
  hintFor sid = Map.lookup sid hintMap
  classify adm acc = case adm of
    Admit r -> acc { routes = A.cons r acc.routes }
    Broke b -> acc { brokered = A.cons b acc.brokered }
    Redir d -> acc { redirects = A.cons d acc.redirects }
    Reject x -> acc { rejected = A.cons x acc.rejected }

-- | The single-binder guarantee SDI got implicitly (it owned every port, so two
-- | rows could never both bind one): make it EXPLICIT and typed. A binder is
-- | anything that takes a public port — a lazy-spawn `Admit` or a `Redir`'s
-- | bind+421. Walking the admissions in their (deterministic, ServiceId-ordered)
-- | deployment order, the FIRST claimant of a public port wins; any later binder
-- | on the same port becomes a `PortClaimed` rejection rather than a runtime
-- | `EADDRINUSE`. `Reject`s carry no port and pass through untouched. Total and
-- | order-deterministic, so it rides the node≡Go conformance unchanged.
arbitrate :: Array Admission -> Array Admission
arbitrate adms = (foldl step { claimed: Set.empty, out: [] } adms).out
  where
  step st adm = case binderPort adm of
    Just (Tuple sid port)
      | Set.member port st.claimed ->
          st { out = A.snoc st.out (Reject { serviceId: sid, publicPort: Just port, reason: PortClaimed port }) }
      | otherwise ->
          st { claimed = Set.insert port st.claimed, out = A.snoc st.out adm }
    _ -> st { out = A.snoc st.out adm }

-- The public port a binding admission claims (and the service claiming it);
-- `Reject`s bind nothing.
binderPort :: Admission -> Maybe (Tuple String Int)
binderPort = case _ of
  Admit r -> Just (Tuple r.serviceId r.publicPort)
  -- a broker binds its public port too — only to answer `307` on it, but a
  -- listener is a listener and two of them still collide.
  Broke b -> map (Tuple b.serviceId) b.publicPort
  Redir d -> Just (Tuple d.serviceId d.publicPort)
  Reject _ -> Nothing

-- | Classify one service, given its registry hint (if any).
-- |
-- | PROXY (the default) is unchanged: a `HostPort` on a remote host becomes a
-- | `Redirect`; on this machine it must be a launchable `Process` with the
-- | literal port in its command (so the public→internal rewrite lands).
-- | Everything else is a typed `Rejection`.
-- |
-- | BROKER relaxes two of those requirements, and it is worth saying why each
-- | one existed. The literal-port rule exists ONLY so the router can move the
-- | backend off the public port and own it; a broker that cannot rewrite simply
-- | leaves the service on its own port and binds nothing. The host-port rule
-- | exists only because a proxy has nothing to relay without one; a broker
-- | reaching a unix socket — or nothing at all — is still worth ensuring and
-- | still has an address (or honestly hasn't). What broker does NOT relax is
-- | the absolute-`cd` rule: it still has to spawn the thing.
admit :: (String -> Maybe ServeHint) -> LooseService -> Admission
admit hintFor s = case mediationOf of
  Broker -> admitBroker
  Proxy -> admitProxy
  where
  sid = unServiceId s.id
  hint = hintFor sid
  mediationOf = maybe Proxy _.mediation hint
  scheme = hint >>= _.scheme
  reject r = Reject { serviceId: sid, publicPort: Nothing, reason: r }
  rejectAt port r = Reject { serviceId: sid, publicPort: Just port, reason: r }
  -- The port the ROW claimed, if it claimed one — known before we decide
  -- whether we can honour it, and therefore available to a rejection. A refusal
  -- that drops the port cannot be correlated with the row that caused it, and
  -- reappears one layer up as `Unaccounted` drift telling the operator to fix a
  -- row that is already reported, with a reason, in `rejected`.
  declared = case classify s.reachability of
    HostPort p -> Just (unPort p)
    _ -> Nothing
  refuse r = Reject { serviceId: sid, publicPort: declared, reason: r }

  admitProxy = case classify s.reachability of
    HostPort p ->
      let public = unPort p in
      case classifyHost s.host of
        Left host ->
          Redir { serviceId: sid, publicPort: public, host, target: redirectTarget host public }
        Right _ -> case s.launch.executor of
          Process pr
            | String.contains (Pattern (show public)) pr.command ->
                Admit
                  { serviceId: sid
                  , publicPort: public
                  , internalPort: internalPort public
                  , cwd: unAbsPath pr.cwd
                  , launchCommand: rewritePort public (internalPort public) pr.command
                  , idleTimeoutMs: defaultIdleMs
                  }
            | otherwise -> rejectAt public (Sdi PortNotInStartCommand)
          -- A `cd`-less registry row parses to `Unmanaged` (StartCommand.purs): it
          -- has no absolute cwd, the SDI footgun. Report it as such.
          Unmanaged _ -> rejectAt public (Sdi NoAbsoluteCwd)
          _ -> rejectAt public NotAProcess
    _ -> reject NoHostPort

  -- A brokered service on ANOTHER machine is still a redirect: we cannot spawn
  -- it here, and the honest answer to "where is it" is already the 421 target.
  admitBroker = case classifyHost s.host of
    Left host -> case classify s.reachability of
      HostPort p ->
        let public = unPort p
        in Redir { serviceId: sid, publicPort: public, host, target: redirectTarget host public }
      _ -> refuse NoHostPort
    Right _ -> case s.launch.executor of
      Process pr -> brokerFor pr
      Unmanaged _ -> refuse (Sdi NoAbsoluteCwd)
      _ -> refuse NotAProcess

  isUdp = scheme == Just "udp"

  brokerFor pr = case classify s.reachability of
    -- A DATAGRAM listener is left exactly where it is, always. The rewrite-and-
    -- hold trick below exists so the router can answer `307` to someone who
    -- dialled the registered port — and there is no such thing as a 307 over
    -- UDP. Moving it would only mean nobody could find it.
    HostPort p | isUdp ->
      Broke
        { serviceId: sid
        , publicPort: Nothing
        , declaredPort: Just (unPort p)
        , cwd: unAbsPath pr.cwd
        , launchCommand: pr.command
        , at: portLocator scheme (unPort p)
        , probe: NoProbe
        }
    -- A TCP listener we CAN move: rewrite it onto the internal port, hold
    -- the public one, and answer `307` there. The rewrite is not for relaying —
    -- it is what lets the router catch a caller who dialled the registered port
    -- and send them on, and what makes a connection the trigger for a spawn.
    HostPort p
      | String.contains (Pattern (show (unPort p))) pr.command ->
          let public = unPort p
              actual = internalPort public
          in Broke
              { serviceId: sid
              , publicPort: Just public
              , declaredPort: Just public
              , cwd: unAbsPath pr.cwd
              , launchCommand: rewritePort public actual pr.command
              , at: portLocator scheme actual
              , probe: portProbe scheme p actual
              }
    -- A listener we CANNOT move (no literal port to rewrite): leave it exactly
    -- where the registry says it is and bind nothing. This is a refusal under
    -- the proxy rules and a perfectly good broker — which is the point, since
    -- the daemons that most need broker mode are the ones least likely to have
    -- a rewritable command.
    HostPort p ->
      let public = unPort p
      in Broke
          { serviceId: sid
          , publicPort: Nothing
          , declaredPort: Just public
          , cwd: unAbsPath pr.cwd
          , launchCommand: pr.command
          , at: portLocator scheme public
          , probe: portProbe scheme p public
          }
    -- The case a proxy cannot represent at all. es9-daemon and the fh2 daemon
    -- live here: reached at `~/.es9/control.sock`, ensurable, locatable, and
    -- utterly un-relayable through a TCP router.
    UnixSocket path ->
      Broke
        { serviceId: sid
        , publicPort: Nothing
        , declaredPort: Nothing
        , cwd: unAbsPath pr.cwd
        , launchCommand: pr.command
        , at: { transport: "unix", host: Nothing, port: Nothing, path: Just (unAbsPath path), url: Nothing }
        , probe: SocketReady path
        }
    -- Startable, worth ensuring, and with no inbound address anyone can dial —
    -- a fan-out daemon. `none` is the honest answer; the alternative is to
    -- invent a port for it, which is how a caller ends up dialling nothing.
    _ ->
      Broke
        { serviceId: sid
        , publicPort: Nothing
        , declaredPort: Nothing
        , cwd: unAbsPath pr.cwd
        , launchCommand: pr.command
        , at: { transport: "none", host: Nothing, port: Nothing, path: Nothing, url: Nothing }
        , probe: NoProbe
        }

-- Everything the router brokers on this machine is on loopback: the registry's
-- host names the MACHINE, and the address we hand back is one a caller on that
-- machine dials.
brokerHost :: String
brokerHost = "127.0.0.1"

-- A dialable address for a port, carrying the row's own scheme through so the
-- answer is `ws://127.0.0.1:23028` and not something the caller has to assemble.
portLocator :: Maybe String -> Int -> Locator
portLocator scheme port =
  { transport: if scheme == Just "udp" then "udp" else "tcp"
  , host: Just brokerHost
  , port: Just port
  , path: Nothing
  , url: map (\sch -> sch <> "://" <> brokerHost <> ":" <> show port) scheme
  }

-- Which readiness check applies to a listening broker. The rule is
-- `Bosun.CLI.Observe.effectiveProbe`'s — a service with no declared probe but a
-- listening address is observable by that address — with one honest exception:
-- a UDP listener does not accept connections, so a TCP connect against it
-- proves nothing and `NoProbe` (which reports as "not checked", never as
-- "down") is the truthful verdict.
portProbe :: Maybe String -> Port -> Int -> Probe
portProbe scheme declared actual
  | scheme == Just "udp" = NoProbe
  | otherwise = TcpConnect (fromMaybe declared (mkPort actual))

-- | Local (this machine) vs remote: `mbp` and host-less are local; any other
-- | host is remote, returned by name for the redirect.
classifyHost :: Maybe Host -> Either String Unit
classifyHost mh = case map unHost mh of
  Nothing -> Right unit
  Just "mbp" -> Right unit
  Just other -> Left other

-- | Where a remote service actually lives, as a tailnet URL on the same port.
-- | The host's network address comes from the shared target table
-- | (`Bosun.Target`), the same registry `apply` resolves ssh logins from —
-- | so `macmini`'s tailnet name is described once, not in two places. A host
-- | not in the table passes through verbatim (`networkAddr`'s fallback).
redirectTarget :: String -> Int -> String
redirectTarget host port =
  "http://" <> networkAddr defaultTargets (mkHost host) <> ":" <> show port

-- | Move the backend off the public port: replace the literal public port with
-- | the internal port throughout the command (SDI's `rewriteCommand`). The
-- | literal-port-present check in `admit` is what guarantees this lands.
rewritePort :: Int -> Int -> String -> String
rewritePort from to =
  String.replaceAll (Pattern (show from)) (Replacement (show to))

-- | What changed between two `ServePlan`s, for SIGHUP hot-reload (registry
-- | edited while resident). Keyed by public port: `unbind` is the ports whose
-- | listener must be torn down (the service was removed, or changed and will be
-- | rebound); `bindRoutes` / `bindRedirects` are the ones to (re)bind (added, or
-- | changed). A port whose service flips proxy↔redirect counts as changed, so it
-- | appears in both `unbind` and the matching bind list. The pure diff the
-- | resident shim applies — so hot-reload is conformance-testable, not ad hoc.
-- |
-- | Brokered services appear here only through the port they hold (`bindBrokers`
-- | is the ones whose `307` listener must be (re)bound). A brokered service with
-- | NO public port owns no listener, so there is nothing for a diff to say about
-- | it: the resident front takes the whole brokered list from the fresh plan
-- | instead. A diff is about listeners; a broker without one is pure plan data.
type ServeDiff =
  { unbind        :: Array Int
  , bindRoutes    :: Array Route
  , bindBrokers   :: Array Broker
  , bindRedirects :: Array Redirect
  }

serveDiff :: ServePlan -> ServePlan -> ServeDiff
serveDiff old new =
  { unbind: A.filter changed (A.fromFoldable (Map.keys oldSig))
  , bindRoutes: A.filter (changed <<< _.publicPort) new.routes
  , bindBrokers: A.filter (maybe false changed <<< _.publicPort) new.brokered
  , bindRedirects: A.filter (changed <<< _.publicPort) new.redirects
  }
  where
  oldSig = sigMap old
  newSig = sigMap new
  -- present-but-identical ⇒ Just s == Just s; removed/added ⇒ one side Nothing;
  -- mutated ⇒ Just s /= Just s'. All three reduce to inequality of the lookups.
  changed port = Map.lookup port oldSig /= Map.lookup port newSig

-- A signature per bound public port: enough to detect a meaningful change
-- (command/cwd/internal-port for a proxy; target for a redirect) and a
-- proxy↔redirect flip (the tag prefix).
sigMap :: ServePlan -> Map Int String
sigMap plan =
  Map.fromFoldable
    ( map (\r -> Tuple r.publicPort (routeSig r)) plan.routes
        <> A.mapMaybe (\b -> map (\p -> Tuple p (brokerSig b)) b.publicPort) plan.brokered
        <> map (\d -> Tuple d.publicPort (redirectSig d)) plan.redirects
    )

routeSig :: Route -> String
routeSig r = "proxy|" <> r.cwd <> "|" <> r.launchCommand <> "|" <> show r.internalPort

-- The tag prefix differs from `routeSig`'s, which is what makes a service
-- flipping proxy↔broker read as a CHANGE: the listener has to be torn down and
-- rebuilt, because one of them relays and the other redirects.
brokerSig :: Broker -> String
brokerSig b = "broker|" <> b.cwd <> "|" <> b.launchCommand <> "|" <> locatorSig b.at

locatorSig :: Locator -> String
locatorSig l =
  l.transport <> "|" <> fromMaybe "" l.host <> "|" <> maybe "" show l.port <> "|" <> fromMaybe "" l.path

redirectSig :: Redirect -> String
redirectSig d = "redir|" <> d.target

-- A rejection's signature. Not a `Show` — a stable tag for change detection
-- (the operator-facing text is `Bosun.Report.renderReject`).
rejectSig :: RejectReason -> String
rejectSig = case _ of
  NoHostPort -> "reject|no-host-port"
  NotAProcess -> "reject|not-a-process"
  Sdi PortNotInStartCommand -> "reject|sdi-port-not-in-start-command"
  Sdi NoAbsoluteCwd -> "reject|sdi-no-absolute-cwd"
  PortClaimed port -> "reject|port-claimed|" <> show port

-- ── registry-vs-router drift ─────────────────────────────────────────────────

-- | Which way a public port disagrees between the registry ON DISK and the plan
-- | the router currently HOLDS. This is a different question from `rejected`:
-- | a rejection means *seen and unusable*, drift means *not seen at all* (or no
-- | longer what was seen). Both must be visible, or a registration that
-- | persisted without reaching the router looks identical to one that never
-- | happened — the 2026-08-14 itajara case.
data DriftKind
  = Unrouted     -- the fresh plan has a verdict on this port, the router doesn't: reload
  | Altered      -- both have a verdict, and they differ (the router holds a stale one)
  | Departed     -- the router holds a verdict for a port nothing claims any more: reload
  -- The registry still claims this port and NO plan accounts for it. A reload
  -- cannot help: the row is being dropped before admission — two rows sharing a
  -- `projectSlug:role` (reconcile keeps one), or a row with no `role` at all.
  -- Only visible by comparing against the raw rows, which is why `planDrift`
  -- takes the claims and not just the two plans.
  | Unaccounted
derive instance Eq DriftKind
derive instance Generic DriftKind _
-- Show for test/REPL diagnostics only (entry 73); operator text is
-- `Bosun.Report.renderDrift`.
instance Show DriftKind where show = genericShow

-- | One disagreeing public port. `serviceId` names the fresher side's claimant
-- | (the registry's, except for `Departed` where only the router has one).
type PortDrift = { publicPort :: Int, serviceId :: String, kind :: DriftKind }

-- | One registry ROW's claim on a public port, as stated — before reconcile
-- | merges rows and before admission judges them. Structurally identical to
-- | `Bosun.Adapters.Registry.RegistryClaim` (records unify by shape, so no
-- | conversion is needed); declared here because core cannot import adapters.
type PortClaim = { serviceId :: String, publicPort :: Int }

-- | `planDrift claims held fresh` — every public port on which the registry AS
-- | IT NOW STANDS and the plan the router HOLDS fail to say the same thing.
-- | Empty ⇔ the sources of truth agree. One entry per port, so two surfaces
-- | reporting drift report it identically.
-- |
-- | Three inputs, not two, and the third earns its place: `claims` is the raw
-- | registry rows (`Bosun.Adapters.Registry.registryClaims`). Without it, a row
-- | that never became a service at all — two rows colliding on one
-- | `projectSlug:role`, a row with no role — is absent from BOTH plans and so
-- | looks exactly like agreement. That is the same "registered and invisible"
-- | failure one level lower down, and it needs a different remedy (`Unaccounted`
-- | ⇒ fix the row; the others ⇒ reload).
-- |
-- | Unlike `serveDiff` this accounts for ALL THREE verdicts, so a row the
-- | router *refuses* is agreement, not drift: the operator reads the reason in
-- | `rejected` instead of chasing a reload that would change nothing.
-- | Total and order-deterministic (sorted by port), so it rides the node≡Go
-- | conformance like the rest of the plan machinery.
planDrift :: Array PortClaim -> ServePlan -> ServePlan -> Array PortDrift
planDrift claims held fresh =
  A.sortWith _.publicPort (A.mapMaybe delta (A.fromFoldable ports))
  where
  heldV = verdictMap held
  freshV = verdictMap fresh
  claimed = Map.fromFoldable (map (\c -> Tuple c.publicPort c.serviceId) claims)
  ports = Set.union (Map.keys claimed) (Set.union (Map.keys heldV) (Map.keys freshV))
  at port serviceId kind = Just { publicPort: port, serviceId, kind }
  delta port = case Map.lookup port heldV, Map.lookup port freshV, Map.lookup port claimed of
    -- the router has never seen a row the fresh plan does account for
    Nothing, Just f, _ -> at port f.serviceId Unrouted
    -- both account for it, differently: the router's verdict is stale
    Just h, Just f, _ | h.sig /= f.sig -> at port f.serviceId Altered
    Just _, Just _, _ -> Nothing
    -- no fresh verdict, yet the registry still asks for the port ⇒ the row is
    -- being swallowed upstream of admission (whether or not we still hold it)
    _, Nothing, Just sid -> at port sid Unaccounted
    -- held, and nothing claims it any more
    Just h, Nothing, Nothing -> at port h.serviceId Departed
    Nothing, Nothing, Nothing -> Nothing

-- The plan's verdict on every public port it accounted for, rejections
-- included. `Map.union` is left-biased, so a binder wins over a rejection on
-- the same port — which is exactly the `PortClaimed` case (one service binds,
-- the loser is refused on a port that IS served).
--
-- Brokers enter by `declaredPort`, NOT `publicPort`: this map answers "does the
-- plan account for the registry's claim on :N", and a broker the router could
-- not move off its port accounts for it perfectly well while binding nothing.
-- Keyed by `publicPort` instead, every such broker looked like a claim no plan
-- had a verdict on — `Unaccounted`, the drift kind whose remedy is "fix the
-- row" — for the healthiest service in the deployment (2026-08-23).
verdictMap :: ServePlan -> Map Int { serviceId :: String, sig :: String }
verdictMap plan = Map.union (binders plan) (refusals plan)
  where
  binders p = Map.fromFoldable
    ( map (\r -> Tuple r.publicPort { serviceId: r.serviceId, sig: routeSig r }) p.routes
        <> A.mapMaybe
             (\b -> map (\port -> Tuple port { serviceId: b.serviceId, sig: brokerSig b }) b.declaredPort)
             p.brokered
        <> map (\d -> Tuple d.publicPort { serviceId: d.serviceId, sig: redirectSig d }) p.redirects
    )
  refusals p = Map.fromFoldable (A.mapMaybe refusal p.rejected)
  refusal x = x.publicPort <#> \port ->
    Tuple port { serviceId: x.serviceId, sig: rejectSig x.reason }
