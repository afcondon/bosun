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
-- |
-- | The wire TYPES and CODECS moved to `Bosun.Protocol` (2026-07-22) so a client
-- | can depend on the contract without this engine; they are re-exported here, so
-- | every existing `import Bosun.View (AnalyzeResult, …)` is unchanged.
module Bosun.View (module Bosun.View, module Bosun.Protocol) where

import Prelude

import Bosun.Atoms (mkServiceId, unAbsPath, unDomain, unEnvVar, unGitWorkdir, unHost, unPort, unProjectSlug, unRoutePath, unServiceId, unUrl)
import Bosun.Edge (DepOrdering(..), Gate(..), Requirement(..))
import Bosun.Error (DeployError(..), SdiViolation(..))
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ExecutorMechanism(..), ImageRef(..), RemoteVia(..), SystemdScope(..), mechanism)
import Bosun.Publish (ChannelKey(..), PublishChannel(..))
import Bosun.Health (Probe(..))
import Bosun.Protocol
import Bosun.Reachability (Address(..), BindScope(..), Openness(..), Reachability, addresses, classify, openness)
import Bosun.Reconcile (AliasMap, Divergence(..), FacetKey, ReconcileResult, exposureLabel)
import Bosun.Selector (Selector(..))
import Bosun.Service (Service, ServiceInstance, Source(..), ValidatedDeployment, deploymentServices, unBootOrder, unRole, unServiceRef, unValidatedDeployment)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Foldable (foldl, foldr)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Argonaut.Core (toString)
import Data.Set as Set
import Data.String (joinWith, split, Pattern(..))
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (V, toEither)

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
  StaticCDN c -> channelLabel c.publish <> " " <> unUrl c.url
  Remote r -> "ssh " <> remoteLabel r.via <> " → " <> executorDetail r.inner
  Unmanaged s -> "unmanaged: " <> s
  where
  channelLabel = case _ of
    CloudflarePagesGit r      -> "cloudflare-pages-git[" <> r.cfProject <> "]"
    CloudflarePagesWrangler r -> "cloudflare-pages-wrangler[" <> r.cfProject <> "]"
    GitHubPagesRepoDir r      -> "github-pages[" <> r.branch <> ":" <> r.servingDir <> "]"
  remoteLabel (Ssh s) = maybe "" (_ <> "@") s.user <> unHost s.host

executorView :: Executor -> ExecutorView
executorView e = { mechanism: mechanismLabel (mechanism e), detail: executorDetail e }

probeLabel :: Probe -> String
probeLabel = case _ of
  HttpGet h -> "http " <> h.path <> " :" <> show (unPort h.port)
  TcpConnect p -> "tcp :" <> show (unPort p)
  ExecCmd cmd -> "exec " <> joinWith " " cmd
  HostExec cmd -> "host-exec " <> joinWith " " cmd
  ProcessAlive -> "process-alive"
  SocketReady p -> "socket " <> unAbsPath p
  NotifyReady -> "notify"
  NoProbe -> "none"

-- | A compact, human-rendered label for a publish-channel collision key.
-- | Each variant prints just the fields that make two services collide on
-- | that channel (the same fields `Bosun.Publish.channelKey` extracts).
channelKeyLabel :: ChannelKey -> String
channelKeyLabel = case _ of
  CfGitKey k ->
    "cloudflare-pages-git[" <> k.cfProject <> " " <> k.branch <> ":" <> k.subdir <> "]"
  CfWranglerKey cfProject ->
    "cloudflare-pages-wrangler[" <> cfProject <> "]"
  GhPagesKey k ->
    "github-pages[" <> unAbsPath (unGitWorkdir k.workdir) <> " " <> k.branch <> ":" <> k.servingDir <> "]"

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

opennessLabel :: Openness -> String
opennessLabel = case _ of
  NoneOpen -> "none"
  LocalOnly -> "local"
  ClusterOnly -> "cluster"
  HostScoped -> "host"
  WideOpen -> "wide"
  InternetWide -> "internet"

bindLabel :: BindScope -> String
bindLabel = case _ of
  AllIfaces -> "all"
  HostIface h -> unHost h
  Internal -> "internal"
  Loopback -> "loopback"

addressView :: Address -> AddressView
addressView a = case a of
  Listening r -> base { kind = "listening", bind = Just (bindLabel r.bind), port = Just (unPort r.port) }
  Proxied r -> base { kind = "proxied", proxy = Just (unServiceId r.proxy), path = Just (unRoutePath r.path) }
  Published d -> base { kind = "published", domain = Just (unDomain d) }
  Socket p -> base { kind = "socket", socket = Just (unAbsPath p) }
  where
  base =
    { kind: "", bind: Nothing, port: Nothing, path: Nothing, proxy: Nothing
    , domain: Nothing, socket: Nothing, openness: opennessLabel (openness a)
    }

reachabilityView :: Reachability -> Array AddressView
reachabilityView r = map addressView (Set.toUnfoldable (addresses r) :: Array Address)

serviceInstanceView :: ServiceInstance -> ServiceInstanceView
serviceInstanceView si =
  { source: sourceLabel si.source
  , project: map unProjectSlug si.project
  , localName: si.localName
  , role: unRole si.role
  , host: map unHost si.host
  , place: placePath si
  , executor: executorView si.executor
  , exposure: exposureLabel (classify si.reachability)
  , reachability: reachabilityView si.reachability
  , readiness: probeLabel si.health.readiness
  , deps: map depView si.rawDeps
  , routes: map (\r -> { to: r.to, path: unRoutePath r.path }) si.rawRoutes
  , selectors: map selectorLabel si.selectors
  }
  where
  depView d = { to: d.to, ordering: map orderingLabel d.ordering, requirement: map requirementLabel d.requirement }

-- the placement path (coarse→fine). PROTOTYPE: read from extra["place"] as a
-- "/"-joined string; falls back to the single-level [host] so existing single-
-- host fixtures keep their one-band layout. To be promoted to a first-class
-- core `Placement` field (docs/PLACEMENT-TYPE.md), at which point this reads
-- si.place directly and the extra-hatch goes away.
placePath :: ServiceInstance -> Array String
placePath si = case Map.lookup "place" si.extra >>= toString of
  Just s -> split (Pattern "/") s
  Nothing -> maybe [] (\h -> [ h ]) (map unHost si.host)

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
  , exposure: exposureLabel (classify s.reachability)
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
  UrlCollision _ _ -> "UrlCollision"
  ChannelCollision _ _ -> "ChannelCollision"
  StaticReadinessMismatch _ -> "StaticReadinessMismatch"

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
  UrlCollision url svcs ->
    unUrl url <> " is claimed by " <> joinIds (NEA.toArray svcs)
  ChannelCollision key svcs ->
    "publish-channel " <> channelKeyLabel key <> " would be deployed by " <> joinIds (NEA.toArray svcs)
  StaticReadinessMismatch d ->
    unServiceId d.svc <> " has readiness probe " <> probeLabel d.probe
      <> " but a StaticCDN service requires an HttpGet probe on its live URL"
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
  UrlCollision _ _ ->
    [ "Give one site a different URL, or split the two services — one site can have only one live URL." ]
  ChannelCollision _ _ ->
    [ "Two services would deploy to the same publish destination. Change one site's cfProject / branch / subdir / artifactDir so they no longer collide." ]
  StaticReadinessMismatch _ ->
    [ "StaticCDN services must use an HttpGet readiness probe (Bosun probes the live URL). Set `x-bosun.healthcheck` to an http-get on the site URL, or remove the non-HTTP probe." ]

-- (The view types, their codecs, and the request contract — AnalyzeResult,
-- TopologyEntry, AliasOverride/AnalyzeRequest, and every *Codec — moved to
-- Bosun.Protocol and are re-exported from this module's header. Only the
-- projections IR → view, and the one function that consumes the engine's
-- AliasMap, remain here.)

-- | Apply the user overrides on top of the default `buildAliases` map.
applyOverrides :: Array AliasOverride -> AliasMap -> AliasMap
applyOverrides ovs m0 = foldl step m0 ovs
  where
  step m = case _ of
    Merge x -> foldr (\n -> Map.insert n (mkServiceId x.canonical)) m x.names
    Split x -> Map.delete x.name m

