-- | The `/analyze` wire contract for Bosun's Chair (MVP-PLAN workstream A).
-- |
-- | Flat, display-oriented **view types** projected from the IR at each rung of
-- | the loose→tight MISU ladder, plus bidirectional `codec-argonaut` codecs.
-- | The codecs are *values* (entry-73 house rule), defined once here and shared
-- | by both ends: `chair-server` ENCODES an `AnalyzeResult`, the Halogen
-- | frontend DECODES it with the same codec value — so the contract cannot
-- | drift. The projections are entry-73 `display` functions (never `show`):
-- | the IR's rich ADTs become short human labels for the UI.
-- |
-- | This module is pure and lives in `core`; it imports the IR but nothing
-- | imports it, so there is no cycle. The orchestration that runs
-- | `ingest → reconcile → validate` and calls these projections lives one layer
-- | up (it needs the adapters), not here.
module Bosun.View where

import Prelude

import Bosun.Atoms (mkServiceId, unAbsPath, unDomain, unEnvVar, unHost, unPort, unProjectSlug, unRoutePath, unServiceId)
import Bosun.Edge (DepOrdering(..), Gate(..), Requirement(..))
import Bosun.Error (DeployError(..), SdiViolation(..))
import Bosun.Executor (BuildContext(..), CDNProvider(..), ContainerSpec(..), Executor(..), ExecutorMechanism(..), ImageRef(..), RemoteVia(..), SystemdScope(..), mechanism)
import Bosun.Health (Probe(..))
import Bosun.Reconcile (AliasMap, Divergence(..), FacetKey, ReconcileResult, exposureLabel)
import Bosun.Selector (Selector(..))
import Bosun.Service (Service, ServiceInstance, Source(..), ValidatedDeployment, deploymentServices, unBootOrder, unRole, unServiceRef, unValidatedDeployment)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Compat as CAC
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Profunctor (dimap)
import Data.String (joinWith)
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (V, toEither)

-- ── view types (the wire shapes) ─────────────────────────────────────────────

type DepView = { to :: String, ordering :: Maybe String, requirement :: Maybe String }
type RouteView = { to :: String, path :: String }
type ExecutorView = { mechanism :: String, detail :: String }

-- | RUNG 1 — a single ingested instance, loose/open, per (source × unit).
type ServiceInstanceView =
  { source    :: String
  , project   :: Maybe String
  , localName :: String
  , role      :: String
  , host      :: Maybe String
  , executor  :: ExecutorView
  , exposure  :: String
  , readiness :: String
  , deps      :: Array DepView
  , routes    :: Array RouteView
  , selectors :: Array String
  }

type FacetView = { host :: Maybe String, mechanism :: String }
type ClaimView = { source :: String, value :: String }
type ConflictView = { svc :: String, field :: String, claims :: Array ClaimView }
type DivergenceView = { svc :: String, facets :: Array FacetView }
type AliasEntry = { from :: String, to :: String }

-- | RUNG 2 — how the instances collapsed: canonical ids, the expected multi-
-- | facet divergences, the real cross-source conflicts, the alias map used.
type ReconcileView =
  { services    :: Array String
  , divergences :: Array DivergenceView
  , conflicts   :: Array ConflictView
  , aliases     :: Array AliasEntry
  }

type SvcView = { id :: String, host :: Maybe String, exposure :: String, deps :: Array String, selectors :: Array String }
type RouteBacking = { path :: String, backend :: String }

-- | RUNG 3 (success) — the TIGHT deployment: dangling edges unrepresentable,
-- | a proven-acyclic boot order in stages.
type ValidatedView =
  { services  :: Array SvcView
  , bootOrder :: Array (Array String)
  , routes    :: Array RouteBacking
  }

-- | RUNG 3 (failure) — an illegal-state family that survived, with how to fix it.
type DeployErrorView = { kind :: String, detail :: String, remediation :: Array String }

-- | The validate outcome: the MISU spec, or the ledger of what is still illegal.
data ValidationView = Valid ValidatedView | Invalid (Array DeployErrorView)
derive instance Eq ValidationView

type AnalyzeResult =
  { instances :: Array ServiceInstanceView
  , reconcile :: ReconcileView
  , result    :: ValidationView
  }

-- ── display labels (entry-73: display functions, never `show`) ───────────────

sourceLabel :: Source -> String
sourceLabel = case _ of
  FromCompose -> "compose"
  FromRegistry -> "registry"
  FromPlist -> "plist"
  FromSystemd -> "systemd"
  FromK8s -> "k8s"
  FromOverlay -> "overlay"

mechanismLabel :: ExecutorMechanism -> String
mechanismLabel = case _ of
  MechProcess -> "process"
  MechContainer -> "container"
  MechSystemd -> "systemd"
  MechLaunchd -> "launchd"
  MechCDN -> "cdn"
  MechRemote -> "remote"
  MechUnmanaged -> "unmanaged"

executorDetail :: Executor -> String
executorDetail = case _ of
  Process p -> unAbsPath p.cwd <> "$ " <> p.command
  Container (ContainerSpec cs) -> case cs.source of
    Left (ImageRef img) -> "image " <> img
    Right (BuildContext b) -> "build " <> b.context
  SystemdUnit u -> u.unit <> case u.scope of
    SystemScope -> " (system)"
    UserScope -> " (user)"
  LaunchdJob j -> j.label
  StaticCDN c -> cdnLabel c.provider <> " " <> unDomain c.domain
  Remote r -> "ssh " <> remoteLabel r.via <> " → " <> executorDetail r.inner
  Unmanaged s -> "unmanaged: " <> s
  where
  cdnLabel = case _ of
    CloudflarePages -> "cloudflare-pages"
    NetlifyCDN -> "netlify"
    GitHubPages -> "github-pages"
    OtherCDN o -> o
  remoteLabel (Ssh s) = maybe "" (_ <> "@") s.user <> unHost s.host

executorView :: Executor -> ExecutorView
executorView e = { mechanism: mechanismLabel (mechanism e), detail: executorDetail e }

probeLabel :: Probe -> String
probeLabel = case _ of
  HttpGet h -> "http " <> h.path <> " :" <> show (unPort h.port)
  TcpConnect p -> "tcp :" <> show (unPort p)
  ExecCmd cmd -> "exec " <> joinWith " " cmd
  ProcessAlive -> "process-alive"
  SocketReady p -> "socket " <> unAbsPath p
  NotifyReady -> "notify"
  NoProbe -> "none"

selectorLabel :: Selector -> String
selectorLabel = case _ of
  Profile s -> "profile:" <> s
  Namespace s -> "namespace:" <> s
  SystemdTarget s -> "target:" <> s
  Workspace s -> "workspace:" <> s

orderingLabel :: DepOrdering -> String
orderingLabel = case _ of
  StartAfter -> "after"
  StartBefore -> "before"

gateLabel :: Gate -> String
gateLabel = case _ of
  OnStarted -> "started"
  OnReady -> "ready"
  OnHealthy -> "healthy"
  OnCompleted -> "completed"

requirementLabel :: Requirement -> String
requirementLabel = case _ of
  Wants -> "wants"
  Requires g -> "requires(" <> gateLabel g <> ")"
  Requisite -> "requisite"
  BindsTo -> "binds-to"
  PartOf -> "part-of"

-- ── projections IR → view ────────────────────────────────────────────────────

serviceInstanceView :: ServiceInstance -> ServiceInstanceView
serviceInstanceView si =
  { source: sourceLabel si.source
  , project: map unProjectSlug si.project
  , localName: si.localName
  , role: unRole si.role
  , host: map unHost si.host
  , executor: executorView si.executor
  , exposure: exposureLabel si.exposure
  , readiness: probeLabel si.health.readiness
  , deps: map depView si.rawDeps
  , routes: map (\r -> { to: r.to, path: unRoutePath r.path }) si.rawRoutes
  , selectors: map selectorLabel si.selectors
  }
  where
  depView d = { to: d.to, ordering: map orderingLabel d.ordering, requirement: map requirementLabel d.requirement }

facetView :: FacetKey -> FacetView
facetView fk = { host: map unHost fk.host, mechanism: mechanismLabel fk.mechanism }

divergenceView :: Divergence -> DivergenceView
divergenceView (Divergence d) = { svc: unServiceId d.svc, facets: map facetView (NEA.toArray d.facets) }

reconcileView :: AliasMap -> ReconcileResult -> ReconcileView
reconcileView aliases r =
  { services: map (unServiceId <<< _.id) (deploymentServices r.deployment)
  , divergences: map divergenceView r.divergences
  , conflicts: A.mapMaybe conflictView r.conflicts
  , aliases: map (\(Tuple from to) -> { from, to: unServiceId to }) (Map.toUnfoldable aliases)
  }

conflictView :: DeployError -> Maybe ConflictView
conflictView = case _ of
  CrossSourceDrift d -> Just
    { svc: unServiceId d.svc
    , field: d.field
    , claims: map (\(Tuple s v) -> { source: sourceLabel s, value: v }) d.claims
    }
  _ -> Nothing

svcView :: Service -> SvcView
svcView s =
  { id: unServiceId s.id
  , host: map unHost s.host
  , exposure: exposureLabel s.exposure
  , deps: map (unServiceId <<< unServiceRef <<< _.to) s.deps
  , selectors: map selectorLabel s.selectors
  }

validatedView :: ValidatedDeployment -> ValidatedView
validatedView vd =
  let r = unValidatedDeployment vd
  in
    { services: map svcView (A.fromFoldable (Map.values r.services))
    , bootOrder: map (map (unServiceId <<< unServiceRef) <<< NEA.toArray) (unBootOrder r.bootOrder)
    , routes: map (\(Tuple path ref) -> { path: unRoutePath path, backend: unServiceId (unServiceRef ref) })
        (Map.toUnfoldable r.routes)
    }

validationView :: V (Array DeployError) ValidatedDeployment -> ValidationView
validationView v = case toEither v of
  Left errs -> Invalid (map deployErrorView errs)
  Right vd -> Valid (validatedView vd)

-- ── the DeployError → (kind, detail, remediation) projection (workstream D) ──

deployErrorView :: DeployError -> DeployErrorView
deployErrorView e = { kind: errKind e, detail: errDetail e, remediation: remediation e }

errKind :: DeployError -> String
errKind = case _ of
  PortCollision _ _ _ -> "PortCollision"
  DanglingDependency _ _ -> "DanglingDependency"
  DependencyCycle _ -> "DependencyCycle"
  EmptySelector _ -> "EmptySelector"
  SelectorNotClosed _ -> "SelectorNotClosed"
  UncheckableGate _ -> "UncheckableGate"
  RouteWithoutBacking _ -> "RouteWithoutBacking"
  ServiceExpectsRouteButNone _ -> "ServiceExpectsRouteButNone"
  CrossSourceDrift _ -> "CrossSourceDrift"
  UnboundReference _ -> "UnboundReference"
  SdiContractViolation _ -> "SdiContractViolation"
  UnparseableExecutor _ -> "UnparseableExecutor"

errDetail :: DeployError -> String
errDetail = case _ of
  PortCollision host port svcs ->
    unHost host <> ":" <> show (unPort port) <> " is claimed by " <> joinIds (NEA.toArray svcs)
  DanglingDependency svc dep ->
    unServiceId svc <> " depends on \"" <> dep <> "\", which no source defines"
  DependencyCycle svcs -> "cycle: " <> joinWith " → " (map unServiceId (NEA.toArray svcs))
  EmptySelector sel -> "selector " <> selectorLabel sel <> " selects no service"
  SelectorNotClosed d ->
    "selector " <> selectorLabel d.selector <> " includes " <> unServiceId d.svc
      <> " but not its dependency " <> unServiceId d.missingDep
  UncheckableGate d ->
    unServiceId d.gated <> " waits for " <> unServiceId d.upstream <> " to be "
      <> gateLabel d.gate <> ", but " <> unServiceId d.upstream <> " has no readiness probe"
  RouteWithoutBacking path -> "route " <> unRoutePath path <> " has no backing service"
  ServiceExpectsRouteButNone svc -> unServiceId svc <> " expects a route but none targets it"
  CrossSourceDrift d ->
    unServiceId d.svc <> " has conflicting " <> d.field <> ": "
      <> joinWith ", " (map (\(Tuple s v) -> sourceLabel s <> "=" <> v) d.claims)
  UnboundReference d -> unServiceId d.svc <> " references ${" <> unEnvVar d.var <> "} with no default or supplier"
  SdiContractViolation d -> unServiceId d.svc <> ": " <> case d.why of
    NoAbsoluteCwd -> "start command has no absolute `cd /…` anchor"
    PortNotInStartCommand -> "start command does not contain its public port literally"
  UnparseableExecutor d -> "could not parse a launch mechanism from " <> sourceLabel d.source <> ": \"" <> d.raw <> "\""
  where
  joinIds = joinWith ", " <<< map unServiceId

remediation :: DeployError -> Array String
remediation = case _ of
  PortCollision _ _ _ -> [ "Give one service a different port, or run them on different hosts." ]
  DanglingDependency _ _ ->
    [ "Add the missing service, fix the name, or remove the dependency."
    , "If the two are the same service under different names, alias them together."
    ]
  DependencyCycle _ -> [ "Break the cycle by removing or reversing one dependency edge." ]
  EmptySelector _ -> [ "Tag a service with this selector, or drop the selector." ]
  SelectorNotClosed d -> [ "Add " <> unServiceId d.missingDep <> " to the selector, or relax the dependency." ]
  UncheckableGate d -> [ "Add a readiness probe to " <> unServiceId d.upstream <> ", or weaken the gate (e.g. to `started`)." ]
  RouteWithoutBacking _ -> [ "Add the backend service, or remove the route." ]
  ServiceExpectsRouteButNone _ -> [ "Add a proxy route that targets this service." ]
  CrossSourceDrift _ ->
    [ "Make the sources agree on this field."
    , "If they are genuinely different facets, they should not be aliased together — split them."
    ]
  UnboundReference d -> [ "Provide a default for ${" <> unEnvVar d.var <> "}, or a service that supplies it." ]
  SdiContractViolation d -> case d.why of
    NoAbsoluteCwd -> [ "Prefix the start command with an absolute anchor: `cd /abs/path && …`." ]
    PortNotInStartCommand -> [ "Embed the public port number literally in the start command so the router can rewrite it." ]
  UnparseableExecutor _ -> [ "Check the start command / service definition for this source." ]

-- ── codecs (codec-argonaut; one value, shared by both ends) ──────────────────

depViewCodec :: CA.JsonCodec DepView
depViewCodec = CAR.object "DepView"
  { to: CA.string, ordering: CAC.maybe CA.string, requirement: CAC.maybe CA.string }

routeViewCodec :: CA.JsonCodec RouteView
routeViewCodec = CAR.object "RouteView" { to: CA.string, path: CA.string }

executorViewCodec :: CA.JsonCodec ExecutorView
executorViewCodec = CAR.object "ExecutorView" { mechanism: CA.string, detail: CA.string }

serviceInstanceViewCodec :: CA.JsonCodec ServiceInstanceView
serviceInstanceViewCodec = CAR.object "ServiceInstanceView"
  { source: CA.string
  , project: CAC.maybe CA.string
  , localName: CA.string
  , role: CA.string
  , host: CAC.maybe CA.string
  , executor: executorViewCodec
  , exposure: CA.string
  , readiness: CA.string
  , deps: CA.array depViewCodec
  , routes: CA.array routeViewCodec
  , selectors: CA.array CA.string
  }

facetViewCodec :: CA.JsonCodec FacetView
facetViewCodec = CAR.object "FacetView" { host: CAC.maybe CA.string, mechanism: CA.string }

claimViewCodec :: CA.JsonCodec ClaimView
claimViewCodec = CAR.object "ClaimView" { source: CA.string, value: CA.string }

conflictViewCodec :: CA.JsonCodec ConflictView
conflictViewCodec = CAR.object "ConflictView"
  { svc: CA.string, field: CA.string, claims: CA.array claimViewCodec }

divergenceViewCodec :: CA.JsonCodec DivergenceView
divergenceViewCodec = CAR.object "DivergenceView"
  { svc: CA.string, facets: CA.array facetViewCodec }

aliasEntryCodec :: CA.JsonCodec AliasEntry
aliasEntryCodec = CAR.object "AliasEntry" { from: CA.string, to: CA.string }

reconcileViewCodec :: CA.JsonCodec ReconcileView
reconcileViewCodec = CAR.object "ReconcileView"
  { services: CA.array CA.string
  , divergences: CA.array divergenceViewCodec
  , conflicts: CA.array conflictViewCodec
  , aliases: CA.array aliasEntryCodec
  }

svcViewCodec :: CA.JsonCodec SvcView
svcViewCodec = CAR.object "SvcView"
  { id: CA.string
  , host: CAC.maybe CA.string
  , exposure: CA.string
  , deps: CA.array CA.string
  , selectors: CA.array CA.string
  }

routeBackingCodec :: CA.JsonCodec RouteBacking
routeBackingCodec = CAR.object "RouteBacking" { path: CA.string, backend: CA.string }

validatedViewCodec :: CA.JsonCodec ValidatedView
validatedViewCodec = CAR.object "ValidatedView"
  { services: CA.array svcViewCodec
  , bootOrder: CA.array (CA.array CA.string)
  , routes: CA.array routeBackingCodec
  }

deployErrorViewCodec :: CA.JsonCodec DeployErrorView
deployErrorViewCodec = CAR.object "DeployErrorView"
  { kind: CA.string, detail: CA.string, remediation: CA.array CA.string }

-- | Tagged via an intermediate wire record (one populated half), so the ADT
-- | gets a clean bidirectional codec without hand-rolling encode/decode.
type ValidationWire = { valid :: Boolean, deployment :: Maybe ValidatedView, errors :: Array DeployErrorView }

validationViewCodec :: CA.JsonCodec ValidationView
validationViewCodec = dimap toWire fromWire wireCodec
  where
  wireCodec = CAR.object "Validation"
    { valid: CA.boolean, deployment: CAC.maybe validatedViewCodec, errors: CA.array deployErrorViewCodec }
  toWire :: ValidationView -> ValidationWire
  toWire = case _ of
    Valid v -> { valid: true, deployment: Just v, errors: [] }
    Invalid es -> { valid: false, deployment: Nothing, errors: es }
  fromWire :: ValidationWire -> ValidationView
  fromWire w = case w.deployment of
    Just v | w.valid -> Valid v
    _ -> Invalid w.errors

analyzeResultCodec :: CA.JsonCodec AnalyzeResult
analyzeResultCodec = CAR.object "AnalyzeResult"
  { instances: CA.array serviceInstanceViewCodec
  , reconcile: reconcileViewCodec
  , result: validationViewCodec
  }

-- ── the request contract (frontend → chair-server) ───────────────────────────

-- | A user correction to the auto-derived alias map (MVP-PLAN #3, the editable
-- | half). `Merge` says "these ingested names are one service" (the fix for
-- | under-grouping); `Split` removes a name from the map so it falls back to
-- | its own identity (the fix for an over-eager auto-merge).
data AliasOverride
  = Merge { canonical :: String, names :: Array String }
  | Split { name :: String }
derive instance Eq AliasOverride

-- | What the Chair POSTs to `/analyze`. `compose` / `registry` are source
-- | locators the server resolves at its edge (a file path, or for the registry
-- | an http(s) URL). MVP scope: compose + registry only (MVP-PLAN #5).
type AnalyzeRequest =
  { compose   :: Maybe String
  , registry  :: Maybe String
  , overrides :: Array AliasOverride
  }

-- | Apply the user overrides on top of the default `buildAliases` map.
applyOverrides :: Array AliasOverride -> AliasMap -> AliasMap
applyOverrides ovs m0 = foldl step m0 ovs
  where
  step m = case _ of
    Merge x -> foldr (\n -> Map.insert n (mkServiceId x.canonical)) m x.names
    Split x -> Map.delete x.name m

type OverrideWire = { op :: String, canonical :: String, names :: Array String, name :: String }

aliasOverrideCodec :: CA.JsonCodec AliasOverride
aliasOverrideCodec = dimap toWire fromWire wireCodec
  where
  wireCodec = CAR.object "AliasOverride"
    { op: CA.string, canonical: CA.string, names: CA.array CA.string, name: CA.string }
  toWire :: AliasOverride -> OverrideWire
  toWire = case _ of
    Merge m -> { op: "merge", canonical: m.canonical, names: m.names, name: "" }
    Split s -> { op: "split", canonical: "", names: [], name: s.name }
  fromWire :: OverrideWire -> AliasOverride
  fromWire w = case w.op of
    "merge" -> Merge { canonical: w.canonical, names: w.names }
    _ -> Split { name: w.name }

analyzeRequestCodec :: CA.JsonCodec AnalyzeRequest
analyzeRequestCodec = CAR.object "AnalyzeRequest"
  { compose: CAC.maybe CA.string
  , registry: CAC.maybe CA.string
  , overrides: CA.array aliasOverrideCodec
  }
