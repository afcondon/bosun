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

import Bosun.Atoms (Host, mkHost, unAbsPath, unHost, unPort, unServiceId)
import Bosun.Error (SdiViolation(..))
import Bosun.Executor (Executor(..))
import Bosun.Exposure (Exposure(..))
import Bosun.Reachability (classify)
import Bosun.Service (Deployment, LooseService, deploymentServices)
import Bosun.Target (defaultTargets, networkAddr)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Generic.Rep (class Generic)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
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
  foldr classify { routes: [], redirects: [], rejected: [] } (arbitrate (map admit (deploymentServices dep)))
  where
  classify adm acc = case adm of
    Admit r -> acc { routes = A.cons r acc.routes }
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
  Redir d -> Just (Tuple d.serviceId d.publicPort)
  Reject _ -> Nothing

-- | Classify one service. A `HostPort` on a remote host becomes a `Redirect`;
-- | on this machine it must be a launchable `Process` with the literal port in
-- | its command (so the public→internal rewrite lands). Everything else is a
-- | typed `Rejection`.
admit :: LooseService -> Admission
admit s = case classify s.reachability of
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
  where
  sid = unServiceId s.id
  reject r = Reject { serviceId: sid, publicPort: Nothing, reason: r }
  rejectAt port r = Reject { serviceId: sid, publicPort: Just port, reason: r }

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
type ServeDiff =
  { unbind        :: Array Int
  , bindRoutes    :: Array Route
  , bindRedirects :: Array Redirect
  }

serveDiff :: ServePlan -> ServePlan -> ServeDiff
serveDiff old new =
  { unbind: A.filter changed (A.fromFoldable (Map.keys oldSig))
  , bindRoutes: A.filter (changed <<< _.publicPort) new.routes
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
        <> map (\d -> Tuple d.publicPort (redirectSig d)) plan.redirects
    )

routeSig :: Route -> String
routeSig r = "proxy|" <> r.cwd <> "|" <> r.launchCommand <> "|" <> show r.internalPort

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
verdictMap :: ServePlan -> Map Int { serviceId :: String, sig :: String }
verdictMap plan = Map.union (binders plan) (refusals plan)
  where
  binders p = Map.fromFoldable
    ( map (\r -> Tuple r.publicPort { serviceId: r.serviceId, sig: routeSig r }) p.routes
        <> map (\d -> Tuple d.publicPort { serviceId: d.serviceId, sig: redirectSig d }) p.redirects
    )
  refusals p = Map.fromFoldable (A.mapMaybe refusal p.rejected)
  refusal x = x.publicPort <#> \port ->
    Tuple port { serviceId: x.serviceId, sig: rejectSig x.reason }
