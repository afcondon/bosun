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
import Data.Either (Either(..), either, hush)
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
  = NotLocal String       -- runs on another host; P1 is local-only (P2: 421 redirect)
  | NoHostPort            -- no host port to bind / route
  | NotAProcess           -- container/CDN/systemd/launchd — P1 spawns Processes only
  | Sdi SdiViolation      -- PortNotInStartCommand / NoAbsoluteCwd
derive instance Eq RejectReason
derive instance Generic RejectReason _
-- Show for test/REPL diagnostics only (entry 73); user-facing text is
-- `Bosun.Report.renderReject`.
instance Show RejectReason where show = genericShow

type Rejection = { serviceId :: String, reason :: RejectReason }

-- | The admission decision over a whole deployment: the bound routes and the
-- | rejected services (each with its typed reason — the report makes both
-- | visible, so nothing is silently dropped).
type ServePlan = { routes :: Array Route, rejected :: Array Rejection }

servePlan :: Deployment -> ServePlan
servePlan dep =
  { routes: A.mapMaybe hush decided
  , rejected: A.mapMaybe (either Just (const Nothing)) decided
  }
  where
  decided = map admit (deploymentServices dep)

-- | Admit one service or reject it with a reason. The order of checks matters
-- | only for which single reason a doubly-disqualified service reports; each is
-- | the most specific applicable.
admit :: LooseService -> Either Rejection Route
admit s = case localHost s.host of
  Left other -> reject (NotLocal other)
  Right _ -> case s.exposure of
    HostPort p -> case s.launch.executor of
      Process pr
        | String.contains (Pattern (show (unPort p))) pr.command ->
            let public = unPort p in
            Right
              { serviceId: unServiceId s.id
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
  reject r = Left { serviceId: unServiceId s.id, reason: r }

-- | P1 serves mbp-local (and host-less) services on this machine; a remote host
-- | is rejected with its name (P2 answers those with SDI's 421 "runs on <host>,
-- | try <tailscale-url>" redirect).
localHost :: Maybe Host -> Either String Unit
localHost mh = case map unHost mh of
  Nothing -> Right unit
  Just "mbp" -> Right unit
  Just other -> Left other

-- | Move the backend off the public port: replace the literal public port with
-- | the internal port throughout the command (SDI's `rewriteCommand`). The
-- | literal-port-present check in `admit` is what guarantees this lands.
rewritePort :: Int -> Int -> String -> String
rewritePort from to =
  String.replaceAll (Pattern (show from)) (Replacement (show to))
