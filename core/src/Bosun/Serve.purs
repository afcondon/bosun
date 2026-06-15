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
  , RejectReason(..)
  , Rejection
  , ServePlan
  , servePlan
  , internalOffset
  , internalPort
  , defaultIdleMs
  ) where

import Prelude

import Bosun.Atoms (Host, unAbsPath, unHost, unPort, unServiceId)
import Bosun.Error (SdiViolation(..))
import Bosun.Executor (Executor(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Service (Deployment, LooseService, deploymentServices)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldr)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..), Replacement(..))
import Data.String as String

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

-- | Why a service is not routable (closed alternatives ⇒ ADT, §10). The first
-- | two are P1-scope limits; the `Sdi` cases are genuine contract violations
-- | that SDI would silently skip.
data RejectReason
  = NoHostPort            -- no host port to bind / route
  | NotAProcess           -- container/CDN/systemd/launchd — serve spawns Processes only
  | Sdi SdiViolation      -- PortNotInStartCommand / NoAbsoluteCwd
derive instance Eq RejectReason
derive instance Generic RejectReason _
-- Show for test/REPL diagnostics only (entry 73); user-facing text is
-- `Bosun.Report.renderReject`.
instance Show RejectReason where show = genericShow

type Rejection = { serviceId :: String, reason :: RejectReason }

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
-- | redirects to bind+421, and rejections (each with its typed reason). All
-- | three are reported, so nothing is silently dropped.
type ServePlan =
  { routes    :: Array Route
  , redirects :: Array Redirect
  , rejected  :: Array Rejection
  }

-- | The per-service verdict (internal; partitioned into the `ServePlan`).
data Admission = Admit Route | Redir Redirect | Reject Rejection

servePlan :: Deployment -> ServePlan
servePlan dep =
  foldr classify { routes: [], redirects: [], rejected: [] } (map admit (deploymentServices dep))
  where
  classify adm acc = case adm of
    Admit r -> acc { routes = A.cons r acc.routes }
    Redir d -> acc { redirects = A.cons d acc.redirects }
    Reject x -> acc { rejected = A.cons x acc.rejected }

-- | Classify one service. A `HostPort` on a remote host becomes a `Redirect`;
-- | on this machine it must be a launchable `Process` with the literal port in
-- | its command (so the public→internal rewrite lands). Everything else is a
-- | typed `Rejection`.
admit :: LooseService -> Admission
admit s = case s.exposure of
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
          | otherwise -> reject (Sdi PortNotInStartCommand)
        -- A `cd`-less registry row parses to `Unmanaged` (StartCommand.purs): it
        -- has no absolute cwd, the SDI footgun. Report it as such.
        Unmanaged _ -> reject (Sdi NoAbsoluteCwd)
        _ -> reject NotAProcess
  _ -> reject NoHostPort
  where
  sid = unServiceId s.id
  reject r = Reject { serviceId: sid, reason: r }

-- | Local (this machine) vs remote: `mbp` and host-less are local; any other
-- | host is remote, returned by name for the redirect.
classifyHost :: Maybe Host -> Either String Unit
classifyHost mh = case map unHost mh of
  Nothing -> Right unit
  Just "mbp" -> Right unit
  Just other -> Left other

-- | Where a remote service actually lives, as a tailnet URL on the same port.
-- | (`macmini` is the one named node today; other hosts pass through verbatim.)
redirectTarget :: String -> Int -> String
redirectTarget host port = "http://" <> tailscaleAddr host <> ":" <> show port

tailscaleAddr :: String -> String
tailscaleAddr = case _ of
  "macmini" -> "andrews-mac-mini"
  other -> other

-- | Move the backend off the public port: replace the literal public port with
-- | the internal port throughout the command (SDI's `rewriteCommand`). The
-- | literal-port-present check in `admit` is what guarantees this lands.
rewritePort :: Int -> Int -> String -> String
rewritePort from to =
  String.replaceAll (Pattern (show from)) (Replacement (show to))
