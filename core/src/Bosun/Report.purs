-- | The `bosun check` report — the user-facing text rendering of a
-- | reconcile + validate pass.
-- |
-- | These are `display` functions with an explicit, documented format
-- | (Elements of PureScript Style, entry 73): `Show` is for the REPL and test
-- | messages, NEVER for user-facing output, and any data crossing a boundary
-- | gets a codec. So the report is hand-rolled here, deliberately, rather than
-- | derived. `renderReport` is the entry point: reconcile conflicts +
-- | divergences + the validate errors, in three labelled sections.
module Bosun.Report
  ( renderError
  , renderDivergence
  , renderArtifactDrift
  , renderTopologyDrift
  , renderReport
  , renderPlan
  , renderChange
  , renderReason
  , renderStatus
  , renderScript
  , renderCommand
  , renderServePlan
  , renderReject
  , renderDrift
  , renderDriftKind
  ) where

import Prelude

import Bosun.Apply (Command(..), StagedCommand)
import Bosun.Atoms (Host, ServiceId, unEnvVar, unHost, unPort, unRoutePath, unServiceId, unUrl)
import Bosun.Edge (Gate)
import Bosun.Error (DeployError(..), SdiViolation(..))
import Bosun.Health (Probe(..))
import Bosun.Artifact (artifactLabel)
import Bosun.Plan (Change(..), Plan, Reason(..), Status(..), planSteps)
import Bosun.Reconcile (ArtifactDrift(..), Divergence(..), FacetKey, TopologyDrift(..))
import Bosun.Protocol (Locator)
import Bosun.Selector (Selector)
import Bosun.Serve (Broker, DriftKind(..), PortDrift, RejectReason(..), Redirect, Rejection, Route, ServePlan)
import Bosun.Service (unServiceRef)
import Data.Array (filter, groupBy, length, mapWithIndex, null, sortWith)
import Data.Array.NonEmpty as NEA
import Data.Foldable (intercalate)
import Data.Maybe (Maybe, fromMaybe, maybe)
import Data.Tuple (Tuple(..))

renderError :: DeployError -> String
renderError = case _ of
  PortCollision h p ids ->
    "port collision: " <> unHost h <> ":" <> show (unPort p)
      <> " claimed by " <> idList ids
  DanglingDependency svc target ->
    unServiceId svc <> " depends on missing service '" <> target <> "'"
  DependencyCycle ids ->
    "dependency cycle: " <> idList ids
  EmptySelector sel ->
    "selector has no members: " <> selectorLabel sel
  SelectorNotClosed r ->
    selectorLabel r.selector <> " is not closed: " <> unServiceId r.svc
      <> " requires " <> unServiceId r.missingDep <> ", which is not in it"
  UncheckableGate r ->
    "uncheckable gate: " <> unServiceId r.gated <> " waits on "
      <> unServiceId r.upstream <> " (" <> gateLabel r.gate
      <> ") but it publishes no readiness signal"
  RouteWithoutBacking path ->
    "route " <> unRoutePath path <> " is not backed by any service"
  ServiceExpectsRouteButNone svc ->
    unServiceId svc <> " expects edge routing but nothing routes to it"
  CrossSourceDrift r ->
    "drift on " <> unServiceId r.svc <> "." <> r.field <> ": "
      <> intercalate ", " (map claim r.claims)
  UnboundReference r ->
    unServiceId r.svc <> " references ${" <> unEnvVar r.var
      <> "} with no default and no supplier"
  SdiContractViolation r ->
    "SDI contract: " <> unServiceId r.svc <> " — " <> sdiLabel r.why
  UnparseableExecutor r ->
    "unparseable start command (" <> show r.source <> "): " <> r.raw
  UrlCollision url ids ->
    "URL collision: " <> unUrl url <> " claimed by " <> idList ids
  ChannelCollision key ids ->
    "publish-channel collision: "
      <> show key <> " — would be deployed by " <> idList ids
  StaticReadinessMismatch r ->
    "static-site readiness mismatch on " <> unServiceId r.svc
      <> ": expected HttpGet probe; got " <> probeShortLabel r.probe
  where
  claim (Tuple src val) = show src <> " says " <> val

renderDivergence :: Divergence -> String
renderDivergence (Divergence d) =
  unServiceId d.svc <> " has " <> show (NEA.length d.facets)
    <> " deployment facets: "
    <> intercalate "; " (map facetLabel (NEA.toArray d.facets))

-- | The artifact-drift section (docs/ARTIFACTS.md): services whose facets would
-- | run DIFFERENT content. Distinct from `renderReport` so it can be surfaced
-- | wherever the reconcile result is shown without re-baselining the
-- | conformance-pinned report. Empty ⇒ "" (the caller omits the section).
renderArtifactDrift :: Array ArtifactDrift -> String
renderArtifactDrift = case _ of
  [] -> ""
  drifts ->
    "ARTIFACT DRIFT (facets would run different content — docs/ARTIFACTS.md)\n"
      <> intercalate "\n" (map (("  - " <> _) <<< driftLine) drifts)
  where
  driftLine (ArtifactDrift d) =
    unServiceId d.svc <> ": " <> intercalate " ≠ " (map artifactLabel (NEA.toArray d.artifacts))
      <> "  (same service, different bytes per substrate — ship one built artifact)"

-- | The edge-missing section (docs/ARTIFACTS.md "the edge is topology"): hosts
-- | that bring up routed backends with no co-located edge serving them. Its own
-- | section, like `renderArtifactDrift`, so it surfaces without touching the
-- | conformance-pinned `renderReport`. Empty ⇒ "" (caller omits the section).
renderTopologyDrift :: Array TopologyDrift -> String
renderTopologyDrift = case _ of
  [] -> ""
  drifts ->
    "EDGE MISSING (host runs routed backends with no co-located edge — links 404)\n"
      <> intercalate "\n" (map (("  - " <> _) <<< driftLine) drifts)
  where
  driftLine (TopologyDrift d) =
    unHost d.host <> " serves none of "
      <> intercalate ", " (map routeLabel (NEA.toArray d.missing))
      <> "  (add a co-located edge serving these routes — docs/ARTIFACTS.md)"
  routeLabel r = unRoutePath r.path <> "→" <> unServiceId r.backend

-- | The full report: reconcile errors (conflicts), reconcile info
-- | (divergences), then the validate errors. Empty sections are omitted; a
-- | wholly clean pass renders a single OK line.
renderReport :: { conflicts :: Array DeployError, divergences :: Array Divergence } -> Array DeployError -> String
renderReport recon vErrors =
  if null recon.conflicts && null recon.divergences && null vErrors
    then "bosun check: OK — no problems found."
    else intercalate "\n\n" (filter (_ /= "") sections)
  where
  sections =
    [ section "CONFLICTS (cross-source drift)" (map renderError recon.conflicts)
    , section "VALIDATION ERRORS" (map renderError vErrors)
    , section "FACET DIVERGENCE (informational)" (map renderDivergence recon.divergences)
    ]

  section :: String -> Array String -> String
  section title = case _ of
    [] -> ""
    items -> title <> "\n" <> intercalate "\n" (map ("  - " <> _) items)

-- ── the `bosun plan` report ───────────────────────────────────────────────────

-- | Render a `Plan` (DESIGN §4). Actionable changes are grouped by stage in
-- | ascending order — `apply` runs the stages in this order, ties concurrently.
-- | `NoOp`s are summarised, not listed (a 40-service rig with one restart should
-- | read clean). Display, not `Show` (entry 73).
renderPlan :: Plan -> String
renderPlan p =
  case actionable of
    [] -> "bosun plan: nothing to do — rig matches desired state ("
            <> show noops <> " service(s) in sync)."
    _ ->
      "PLAN — " <> show (length groups) <> " stage(s), "
        <> show (length actionable) <> " change(s)"
        <> (if noops > 0 then " (" <> show noops <> " in sync)" else "")
        <> "\n\n"
        <> intercalate "\n\n" (mapWithIndex renderStage groups)
  where
  steps = sortWith _.stage (planSteps p)
  actionable = filter (not <<< isNoOp <<< _.change) steps
  noops = length steps - length actionable
  groups = groupBy (\a b -> a.stage == b.stage) actionable

  -- display stages densely (1..k); the PlanStep's own `stage` is the internal
  -- scheduling key (sparse: stops occupy a band below starts), not for humans.
  renderStage i grp =
    "stage " <> show (i + 1) <> ":\n"
      <> intercalate "\n" (map (\s -> "  " <> renderChange s.change) (NEA.toArray grp))

isNoOp :: Change -> Boolean
isNoOp = case _ of
  NoOp _ -> true
  _ -> false

renderChange :: Change -> String
renderChange = case _ of
  Start r -> "start    " <> ref r
  Restart r reason -> "restart  " <> ref r <> " (" <> renderReason reason <> ")"
  NoOp r -> "noop     " <> ref r
  Stop r -> "stop     " <> ref r
  where
  ref = unServiceId <<< unServiceRef

renderReason :: Reason -> String
renderReason = case _ of
  Crashed -> "crashed"
  SpecChanged -> "spec changed"
  DependencyRestarted sid -> "dependency " <> unServiceId sid <> " restarted"
  ProbeUnreachable msg -> "probe unreachable: " <> msg

renderStatus :: Status -> String
renderStatus = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown reason -> "unknown (" <> renderReason reason <> ")"

-- ── the `bosun apply --dry-run` script ────────────────────────────────────────

-- | Render an apply script (Phase 6B). The commands are grouped by stage, in
-- | the order `apply` would run them. Display, not `Show` (entry 73). A `Manual`
-- | line is prefixed `# MANUAL:` so a dry-run reads as a runnable shell script
-- | with the un-automatable steps commented.
renderScript :: Array StagedCommand -> String
renderScript cmds = case cmds of
  [] -> "apply: nothing to do — the rig already matches desired state."
  _ ->
    "APPLY SCRIPT — " <> show (length groups) <> " stage(s), "
      <> show (length cmds) <> " command(s)\n\n"
      <> intercalate "\n\n" (mapWithIndex renderStage groups)
  where
  groups = groupBy (\a b -> a.stage == b.stage) cmds

  renderStage i grp =
    "# stage " <> show (i + 1) <> ":\n"
      <> intercalate "\n" (map (\c -> renderCommand c.command) (NEA.toArray grp))

renderCommand :: Command -> String
renderCommand = case _ of
  Shell s -> maybe "" (\c -> "cd " <> c <> " && ") s.cwd <> s.line
  Ssh target inner -> "ssh " <> target <> " '" <> renderCommand inner <> "'"
  Manual note -> "# MANUAL: " <> note

-- ── the `bosun serve` admission report ────────────────────────────────────────

-- | Render a `ServePlan` (BOSUN-SERVE.md §4) — the typed admission control the
-- | resident router prints at startup: which services it will bind and lazy-
-- | spawn, and which it refuses, each with a reason. The headline difference
-- | from SDI is that the rejections are *visible and typed*, not silent skips.
-- | Display, not `Show` (entry 73).
renderServePlan :: ServePlan -> String
renderServePlan plan =
  intercalate "\n\n" (filter (_ /= "") [ admitted, brokered, redirected, refused ])
  where
  admitted = case plan.routes of
    [] -> "ADMITTED: none — no routable services in this registry."
    rs -> "ADMITTED — " <> show (length rs) <> " routable service(s):\n"
            <> intercalate "\n" (map (("  - " <> _) <<< renderRoute) rs)

  brokered = case plan.brokered of
    [] -> ""
    bs -> "BROKERED — " <> show (length bs) <> " service(s) Bosun starts but does NOT proxy:\n"
            <> intercalate "\n" (map (("  - " <> _) <<< renderBroker) bs)

  redirected = case plan.redirects of
    [] -> ""
    rs -> "REDIRECT (421) — " <> show (length rs) <> " remote service(s):\n"
            <> intercalate "\n" (map (("  - " <> _) <<< renderRedirect) rs)

  refused = case plan.rejected of
    [] -> ""
    rs -> "REJECTED — " <> show (length rs) <> " not routable:\n"
            <> intercalate "\n" (map (("  - " <> _) <<< renderRejection) rs)

renderRoute :: Route -> String
renderRoute r =
  show r.publicPort <> " → " <> r.serviceId
    <> " (backend on " <> show r.internalPort <> ")"

-- A broker line says the two things a proxy line cannot: where the caller
-- should actually go, and whether the router holds the registered port at all.
-- Reading "binds nothing" is the operator's cue that `/where` is the only door.
renderBroker :: Broker -> String
renderBroker b =
  b.serviceId <> " at " <> locatorLabel b.at
    <> " — " <> maybe "binds nothing" (\p -> show p <> " → 307") b.publicPort
    <> ", ready by " <> probeShortLabel b.probe

locatorLabel :: Locator -> String
locatorLabel l = case l.transport of
  "unix" -> "unix " <> fromMaybe "?" l.path
  "none" -> "no dialable address"
  t -> t <> " " <> fromMaybe "?" l.host <> ":" <> maybe "?" show l.port

renderRedirect :: Redirect -> String
renderRedirect r =
  show r.publicPort <> " → " <> r.serviceId
    <> " (runs on " <> r.host <> "; 421 → " <> r.target <> ")"

renderRejection :: Rejection -> String
renderRejection r = r.serviceId <> ": " <> renderReject r.reason

renderReject :: RejectReason -> String
renderReject = case _ of
  NoHostPort -> "no host port to bind"
  NotAProcess -> "not a Process launch (serve spawns local processes only)"
  Sdi why -> "SDI contract — " <> sdiLabel why
  PortClaimed port -> "public port " <> show port <> " is already claimed by another service (collision)"

-- ── registry-vs-router drift ─────────────────────────────────────────────────

-- | Render a `planDrift` — the registry rows the running router has no verdict
-- | on (and vice versa). One line per port, plus the standing instruction,
-- | because every drift entry has the same single remedy. Empty ⇒ "" so callers
-- | can splice it unconditionally.
renderDrift :: Array PortDrift -> String
renderDrift = case _ of
  [] -> ""
  ds -> "DRIFT — " <> show (length ds) <> " port(s) where the registry and the router disagree:\n"
          <> intercalate "\n" (map (("  ! " <> _) <<< renderOne) (sortWith _.publicPort ds))
          <> "\n  → `bosun reload` (or POST /control/reload) brings the router in line"
          <> "\n    (except `Unaccounted`, which needs the ROW fixed — a reload cannot help)."
  where
  renderOne d = show d.publicPort <> " → " <> d.serviceId <> ": " <> renderDriftKind d.kind

renderDriftKind :: DriftKind -> String
renderDriftKind = case _ of
  Unrouted -> "registered, not routed — the router has never seen this row"
  Altered -> "changed since the router planned it — it holds a stale verdict"
  Departed -> "no longer in the registry — the router is still holding this port"
  Unaccounted ->
    "declared by the registry but accounted for by NO plan verdict — the row is dropped \
    \before admission (another row shares its projectSlug:role, or it has no role). \
    \A reload will not help; fix the row."

-- ── small label helpers (display, not Show) ──────────────────────────────────

idList :: NEA.NonEmptyArray ServiceId -> String
idList = intercalate ", " <<< map unServiceId <<< NEA.toArray

facetLabel :: FacetKey -> String
facetLabel k = "(" <> hostLabel k.host <> ", " <> show k.mechanism <> ")"

hostLabel :: Maybe Host -> String
hostLabel = maybe "?" unHost

gateLabel :: Gate -> String
gateLabel = show

selectorLabel :: Selector -> String
selectorLabel = show

sdiLabel :: SdiViolation -> String
sdiLabel = case _ of
  NoAbsoluteCwd -> "start command has no absolute cwd anchor (cd /abs)"
  PortNotInStartCommand -> "the literal public port is missing from the start command"

-- | Compact one-line label for a probe, used by the static-readiness-mismatch
-- | error rendering. The mismatch only ever fires on non-HttpGet probes, so the
-- | label only needs to NAME the wrong probe — full details would be noise.
probeShortLabel :: Probe -> String
probeShortLabel = case _ of
  HttpGet _ -> "http-get"
  TcpConnect _ -> "tcp-connect"
  ExecCmd _ -> "exec-cmd"
  ProcessAlive -> "process-alive"
  SocketReady _ -> "socket-ready"
  NotifyReady -> "notify-ready"
  NoProbe -> "no-probe"
