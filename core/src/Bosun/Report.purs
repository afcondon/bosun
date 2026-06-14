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
  , renderReport
  ) where

import Prelude

import Bosun.Atoms (Host, ServiceId, unEnvVar, unHost, unPort, unRoutePath, unServiceId)
import Bosun.Edge (Gate)
import Bosun.Error (DeployError(..), SdiViolation(..))
import Bosun.Reconcile (Divergence(..), FacetKey)
import Bosun.Selector (Selector)
import Data.Array (filter, null)
import Data.Array.NonEmpty as NEA
import Data.Foldable (intercalate)
import Data.Maybe (Maybe, maybe)
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
  where
  claim (Tuple src val) = show src <> " says " <> val

renderDivergence :: Divergence -> String
renderDivergence (Divergence d) =
  unServiceId d.svc <> " has " <> show (NEA.length d.facets)
    <> " deployment facets: "
    <> intercalate "; " (map facetLabel (NEA.toArray d.facets))

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
