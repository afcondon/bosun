-- | Bosun's Chair — the workbench root. Two views over the same bosun-core
-- | model, switched by the top nav:
-- |
-- |  · COCKPIT (pillar 0) — polls `bosun serve` /state (:3997) and renders the
-- |    live admission picture + route table (watch + control).
-- |  · INGESTION (pillar 1) — POSTs to `chair-server` /analyze (:3022) and
-- |    renders the loose→tight MISU ladder: instances → reconcile → validate,
-- |    each rung captioned with the illegal-state family it extinguishes.
-- |
-- | The ingestion view decodes the response with the SAME `Bosun.View` codecs
-- | the server encodes with — one codec value, no drift. Styling is
-- | Swiss/light, in chair/index.html.
module Chair.Main where

import Prelude

import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Bosun.View (AliasEntry, AliasOverride(..), AnalyzeRequest, AnalyzeResult, ConflictView, DeployErrorView, DivergenceView, RouteBacking, ServiceInstanceView, SvcView, TopologyEntry, ValidationView(..), analyzeRequestCodec, analyzeResultCodec)
import Chair.Graph (Channel, GroupMode(..), NodeLive(..), allChannels, graphView, layoutPositions, nextMode)
import Chair.Routes (Route(..), routeCodec)
import Chair.State (unsettledTeardowns, BrokerStatus, DriftInfo, RedirectInfo, RejectInfo, RouteStatus, StateView, SuperviseState, brokerEntries, decodeStateView, decodeSuperviseState, driftEntries)
import Chair.Topo (fetchTopology, fetchFleetNames)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError, decodeJson)
import Data.Argonaut.Decode.Error (printJsonDecodeError)
import Data.Array as Array
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Foldable (all)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Tuple (Tuple(..))
import Data.Tuple.Nested (type (/\), (/\))
import Foreign.Object as FO
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay, launchAff_)
import Hylograph.Transition.Easing (EasingType(..))
import Hylograph.Transition.Engine (TransitionState, currentValue, isComplete, start, tick, transitionWith)
import Hylograph.Transition.Interpolate (Point, lerpPoint)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Data.Traversable (traverse)
import Hylograph.Interaction.Zoom (ZoomHandle, attachNativeZoom)
import Routing.Duplex (parse, print)
import Routing.Hash (matchesWith, setHash)
import Web.DOM (Element)
import Web.DOM.ParentNode (QuerySelector(..), querySelector)
import Web.HTML (window)
import Web.HTML.HTMLDocument (toParentNode)
import Web.HTML.Window (document)

serveBase :: String
serveBase = "http://localhost:3997"

analyzeBase :: String
analyzeBase = "http://localhost:3022"

pollMs :: Number
pollMs = 1500.0

-- The frozen Detect corpus — a one-click sample for the ingestion view.
-- Repo-relative: chair-server reads these from its cwd (the bosun repo root),
-- the same basis registry/fleet.json already resolves against.
corpusDir :: String
corpusDir = "fixtures/polyglot-2026-06-14"

-- Fabricated topology fixtures (rich dependency structure for the graph view).
fixturesDir :: String
fixturesDir = "fixtures"

-- | A Project is the unit you pick and operate on: a validated deployment (with
-- | a `supervise` daemon you can drive) or a study fixture (view-only). `key` is
-- | the url slug used in `#/graph/<key>`. `supervise` is the daemon's status/
-- | control port — `Just` ⇒ controllable; `Nothing` ⇒ no control surface.
type Project =
  { key :: String
  , label :: String
  , blurb :: String
  , compose :: String
  , registry :: String
  , supervise :: Maybe Int
  }

-- a control op in flight: PGroup = ▲up all / ▼down all (affects every
-- controllable node); POne = a per-node ⟳ restart (one serviceId). Drives the
-- amber "working" wash + disables the group buttons until the (synchronous)
-- control POST returns. Set/cleared in `control`.
data Pending = PGroup | POne String

type State =
  { route :: Route
  , currentProject :: Maybe Project
  -- cockpit (pillar 0) — serve /state (routes/redirects/rejected)
  , cockpit :: Maybe StateView
  -- supervise /state (desired + serviceId→status), when the project has a daemon
  , superv :: Maybe SuperviseState
  , cockErr :: Maybe String
  , ticks :: Int
  , busy :: Boolean
  , controlPending :: Maybe Pending  -- in-flight control op → amber wash + disabled group buttons
  -- | What the last control verb answered. Until now the Chair posted with
  -- | `RF.ignore` and threw the body away, so a refusal — or a `down` that
  -- | stopped nothing — reached the daemon log and no human. A surface that
  -- | discards the one answer it asked for is the same failure the teardown
  -- | verdicts exist to end, one layer up.
  , lastControl :: Maybe { ok :: Boolean, message :: String }
  -- ingestion (pillar 1)
  , composePath :: String
  , registryPath :: String
  , analysis :: Maybe AnalyzeResult
  , anaErr :: Maybe String
  , anaLoading :: Boolean
  -- editable aliases (C2) — session-local overrides on top of the auto map
  , overrides :: Array AliasOverride
  , mergeName :: String
  , mergeCanon :: String
  -- graph (pillar 3) — the brushed node for coordinated highlighting
  , graphFocus :: Maybe String
  , graphSelect :: Maybe String   -- clicked node → blast radius ("what breaks")
  , groupMode :: GroupMode   -- layout pivot: deps layers / host swimlanes / pack
  -- the pivot tween, driven by the Hylograph interpolation engine: livePos holds
  -- the per-node interpolating positions the graph renders from; anim holds the
  -- in-flight transitions (Nothing when settled); animGen kills stale loops when
  -- the user toggles again mid-flight.
  , livePos :: Map String Point
  , anim :: Maybe (Array AnimNode)
  , animGen :: Int
  , channels :: Set Channel  -- which structural channels are composited into the view
  , armed :: Boolean         -- control mode: armed via the runtime overlay (destructive)
  , zoom :: Maybe ZoomHandle -- the pan/zoom handle for the main SVG (Hylograph.Interaction.Zoom)
  -- the landing's declared topology (from chair-server /topology) + a merged
  -- name→status map polled from every group's /state (the live overlay).
  , topo :: Array TopologyEntry
  , topoStatus :: FO.Object String
  , fleetNames :: Map String String   -- projectSlug → human projectName (fleet.json)
  }

-- one node's position transition (interpolating a 2D Point through the engine)
type AnimNode = { id :: String, st :: TransitionState Point }

data Action
  = Initialize
  | Refresh
  | Reload
  | Spawn Int                 -- serve: spawn a route by port (Cockpit table)
  | Stop Int                  -- serve: stop a route by port (Cockpit table)
  -- serve: the same two verbs on a BROKERED service, keyed by id rather than
  -- port. Not a variant of the above with a different argument type — half the
  -- services broker mode exists for hold no port to be addressed by at all
  -- (es9-daemon on a unix socket), so `?service=` is the only key that works
  -- for the whole bucket.
  | SpawnBroker String
  | StopBroker String
  | GroupUp                   -- supervise: POST /control/up — bring the group up
  | GroupDown                 -- supervise: POST /control/down — hold the group down
  | Restart String            -- supervise: POST /control/restart?service=<id>
  | NavTo Route               -- set the hash; the hashchange drives the view
  | SetCompose String
  | SetRegistry String
  | LoadCorpus
  | LoadPaths String String   -- set compose+registry paths, then analyze
  | RunAnalyze
  -- editable aliases (C2)
  | SetMergeName String
  | SetMergeCanon String
  | AddMerge
  | SplitAlias String
  | RemoveOverride Int
  | HoverNode (Maybe String)
  | SelectNode (Maybe String)
  | ToggleGroupBy
  | SetGroupMode GroupMode
  | ToggleChannel Channel
  | ShowAllChannels
  | HideAllChannels
  | ToggleArm
  | ResetZoom
  | LoadTopo                   -- landing: (re)fetch the declared topology tree

-- the router speaks to the component through this query: `matchesWith` fires
-- `Navigate` on every hash change (and once for the initial hash).
data Query a = Navigate Route a

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  halogenIO <- runUI component unit body
  -- the house pattern (HeresiarchHalogen): one codec parses the hash and drives
  -- the component; navigation elsewhere just sets the hash and rides this loop.
  void $ H.liftEffect $ matchesWith (parse routeCodec) \old new ->
    when (old /= Just new) $ launchAff_ $ void $
      halogenIO.query $ H.mkTell $ Navigate new

component :: forall i o. H.Component Query i o Aff
component =
  H.mkComponent
    { initialState: \_ ->
        { route: Projects, currentProject: Nothing
        , cockpit: Nothing, superv: Nothing, cockErr: Nothing, ticks: 0, busy: false, controlPending: Nothing
        , lastControl: Nothing
        , composePath: "", registryPath: "", analysis: Nothing, anaErr: Nothing, anaLoading: false
        , overrides: [], mergeName: "", mergeCanon: ""
        , graphFocus: Nothing, graphSelect: Nothing, groupMode: ByDeps
        , livePos: Map.empty, anim: Nothing, animGen: 0
        , channels: Set.fromFoldable allChannels   -- default: full composite (clutter is a fine resting state)
        , armed: false
        , zoom: Nothing
        , topo: [], topoStatus: FO.empty, fleetNames: Map.empty
        }
    , render
    , eval: H.mkEval H.defaultEval
        { handleAction = handleAction
        , handleQuery = handleQuery
        , initialize = Just Initialize
        }
    }

-- the router's only message: apply a parsed Route. Each route does its view-
-- specific setup (a Graph route loads its project's analysis and re-attaches
-- pan/zoom once the svg mounts).
handleQuery :: forall o a. Query a -> H.HalogenM State Action () o Aff (Maybe a)
handleQuery (Navigate route a) = do
  case route of
    GraphR key -> do
      H.modify_ _ { route = route }
      cur <- H.gets _.currentProject
      when (map _.key cur /= Just key) (openProject key)
      void (H.fork attachZoom)
    _ -> H.modify_ _ { route = route }
  pure (Just a)

-- load a project by key: point compose/registry at it, remember it (so the poll
-- and control target its supervise daemon), and analyze.
openProject :: forall o. String -> H.HalogenM State Action () o Aff Unit
openProject key = do
  -- a topology GROUP (a sub-supervisor) opens its own compose+daemon; otherwise
  -- fall back to a hardcoded study fixture. Either way, drop any armed state and
  -- the previous daemon's snapshot so a stale armed mode can't command the wrong
  -- daemon.
  s <- H.get
  case Array.find (\e -> e.name == key && isJust e.groupPort) s.topo of
    Just e -> setProj
      { key, label: key, blurb: "", supervise: e.groupPort
      , compose: fromMaybe "" e.compose, registry: fromMaybe "" e.registry }
    Nothing -> case Array.find (\p -> p.key == key) projects of
      Nothing -> H.modify_ _ { currentProject = Nothing, anaErr = Just ("unknown project: " <> key) }
      Just p -> setProj p
  where
  setProj p = do
    H.modify_ _ { currentProject = Just p, composePath = p.compose, registryPath = p.registry
                , armed = false, superv = Nothing, cockpit = Nothing }
    runAnalyze
    refresh

handleAction :: forall o. Action -> H.HalogenM State Action () o Aff Unit
handleAction = case _ of
  Initialize -> do
    refresh
    loadTopo
    void (H.fork pollLoop)
  Refresh -> refresh
  LoadTopo -> loadTopo
  Reload -> control Nothing "/control/reload"
  Spawn port -> control Nothing ("/control/spawn?port=" <> show port)
  Stop port -> control Nothing ("/control/stop?port=" <> show port)
  -- Brokered rows go to the SAME router on the same two verbs; only the key
  -- differs. Note that a brokered stop does not suspend the lazy-spawn — asking
  -- `/where` again starts it — which is why the row's button says `stop` and
  -- not `hold`.
  SpawnBroker svc -> control Nothing ("/control/spawn?service=" <> svc)
  StopBroker svc -> control Nothing ("/control/stop?service=" <> svc)
  -- supervise control: whole-group up/down (desired-state, stop HOLDS) + atomic
  -- per-element restart. All POST to the current project's supervise daemon.
  -- The Pending tag drives the "working" amber + button-disable until the
  -- (synchronous) control POST returns.
  GroupUp -> control (Just PGroup) "/control/up"
  GroupDown -> control (Just PGroup) "/control/down"
  Restart svc -> control (Just (POne svc)) ("/control/restart?service=" <> svc)
  -- navigation is hash-first: set the hash and let `matchesWith` drive the view,
  -- so the URL and the rendered view are always the same fact.
  NavTo route -> H.liftEffect (setHash (print routeCodec route))
  ResetZoom -> do
    mh <- H.gets _.zoom
    H.liftEffect (maybe (pure unit) _.resetZoom mh)
  SetCompose s -> H.modify_ _ { composePath = s }
  SetRegistry s -> H.modify_ _ { registryPath = s }
  LoadCorpus -> H.modify_ _
    { composePath = corpusDir <> "/docker-compose.yml", registryPath = corpusDir <> "/registry.json" }
  LoadPaths c r -> do
    H.modify_ _ { composePath = c, registryPath = r }
    runAnalyze
  RunAnalyze -> runAnalyze
  SetMergeName x -> H.modify_ _ { mergeName = x }
  SetMergeCanon x -> H.modify_ _ { mergeCanon = x }
  AddMerge -> do
    s <- H.get
    when (notBlank s.mergeName && notBlank s.mergeCanon) do
      H.modify_ \st -> st
        { overrides = Array.snoc st.overrides (Merge { canonical: st.mergeCanon, names: [ st.mergeName ] })
        , mergeName = "", mergeCanon = ""
        }
      runAnalyze
  SplitAlias name -> do
    H.modify_ \s -> s { overrides = Array.snoc s.overrides (Split { name }) }
    runAnalyze
  HoverNode mid -> H.modify_ _ { graphFocus = mid }
  -- click toggles the blast-radius selection; clicking the same node clears it
  SelectNode mid -> H.modify_ \s -> s { graphSelect = if s.graphSelect == mid then Nothing else mid }
  ToggleGroupBy -> do
    s <- H.get
    pivotTo (nextMode s.groupMode)
  SetGroupMode m -> pivotTo m
  ToggleChannel ch -> H.modify_ \s ->
    s { channels = if Set.member ch s.channels then Set.delete ch s.channels else Set.insert ch s.channels }
  ShowAllChannels -> H.modify_ _ { channels = Set.fromFoldable allChannels }
  HideAllChannels -> H.modify_ _ { channels = Set.empty }
  ToggleArm -> H.modify_ \s -> s { armed = not s.armed }
  RemoveOverride i -> do
    H.modify_ \s -> s { overrides = fromMaybe s.overrides (Array.deleteAt i s.overrides) }
    runAnalyze

-- ── cockpit (pillar 0) — talk to the current group's daemon ──────────────────

-- which daemon do we poll and command? The selected project's `supervise` port
-- when it has one (one daemon per group, B-model); otherwise the legacy serve
-- on :3997 (the Cockpit's demo source, and any view-only fixture).
controlBase :: State -> String
controlBase s = case s.currentProject >>= _.supervise of
  Just port -> "http://localhost:" <> show port
  Nothing -> serveBase

-- `pend` marks the in-flight op so the graph can wash the affected nodes amber
-- and disable the group buttons. The control POST is SYNCHRONOUS (the resident
-- doesn't reply until its ssh `docker compose …` finishes), so clearing it on
-- the response is an exact "done" signal — no timer/guess needed.
control :: forall o. Maybe Pending -> String -> H.HalogenM State Action () o Aff Unit
control pend path = do
  base <- H.gets controlBase
  H.modify_ _ { busy = true, controlPending = pend, lastControl = Nothing }
  res <- H.liftAff (AX.post RF.json (base <> path) Nothing)
  -- A transport failure is reported as a refusal rather than swallowed: from
  -- where the operator sits, "the daemon did not answer" and "the daemon said
  -- no" are both "it did not happen", and only one of them used to be visible.
  let
    reply = case res of
      Left err -> { ok: false, message: "no answer from the daemon — " <> AX.printError err }
      Right resp -> case decodeControlReply resp.body of
        Left _ -> { ok: true, message: "" }
        Right r -> r
  H.modify_ _ { busy = false, controlPending = Nothing, lastControl = Just reply }
  refresh

-- | `{ ok, message }`, the shape every `/control` verb answers with since
-- | `b45bb21`. Decoded leniently — an older daemon answering something else
-- | leaves the Chair silent rather than showing it a decode error it cannot act
-- | on.
decodeControlReply :: Json -> Either JsonDecodeError { ok :: Boolean, message :: String }
decodeControlReply = decodeJson

pollLoop :: forall o. H.HalogenM State Action () o Aff Unit
pollLoop = do
  H.liftAff (delay (Milliseconds pollMs))
  s <- H.get
  case s.route of
    Projects -> refreshTopoStatus   -- landing: poll every group's /state
    _ -> refresh                    -- a project view: poll its own daemon
  pollLoop

-- ── the declared topology (landing) ──────────────────────────────────────────

-- | Fetch the tree from chair-server (which resolves it from the compose
-- | files), then overlay live status.
loadTopo :: forall o. H.HalogenM State Action () o Aff Unit
loadTopo = do
  res <- H.liftAff fetchTopology
  case res of
    Left _ -> pure unit
    Right t -> H.modify_ _ { topo = t }
  names <- H.liftAff fetchFleetNames   -- port → human name (fleet.json)
  H.modify_ _ { fleetNames = names }
  refreshTopoStatus

-- | Poll every group `/state` in the tree, merging name→status into one map
-- | (service names are unique across groups). This is the landing's live layer.
refreshTopoStatus :: forall o. H.HalogenM State Action () o Aff Unit
refreshTopoStatus = do
  s <- H.get
  let ports = Array.nub (Array.mapMaybe _.groupPort s.topo)
  maps <- H.liftAff (traverse fetchGroupStatus ports)
  serve <- H.liftAff fetchServeState   -- the lazy-spawn fleet (serve :3997)
  H.modify_ _ { topoStatus = Array.foldl FO.union FO.empty maps, cockpit = serve }

fetchGroupStatus :: Int -> Aff (FO.Object String)
fetchGroupStatus port = do
  res <- AX.get RF.json ("http://localhost:" <> show port <> "/state")
  pure case res of
    Left _ -> FO.empty
    Right resp -> case decodeSuperviseState resp.body of
      Left _ -> FO.empty
      Right v -> v.services

fetchServeState :: Aff (Maybe StateView)
fetchServeState = do
  res <- AX.get RF.json (serveBase <> "/state")
  pure case res of
    Left _ -> Nothing
    Right resp -> case decodeStateView resp.body of
      Left _ -> Nothing
      Right v -> Just v

-- ── projects (the picker) ────────────────────────────────────────────────────

-- The three live deployments — each backed by its own `bosun supervise` daemon
-- on its own port (B-model: one group at a time). The two polyglot entries are
-- safe engine fixtures (spawning them never touches anything real). Atlantis is
-- the REAL live-coding rig: its compose carries the actual es9-daemon /
-- link-spike / fh2-daemon / purerl-tidal / calypso launch commands, so arming
-- it and raising the group starts the real rig (and touches ES-9 / FH-2
-- hardware). Launch its supervise daemon `--held` so the group boots down and is
-- raised deliberately from the Chair — the DeepStar-replacement path.
deployments :: Array Project
deployments =
  [ { key: "polyglot-mbp"
    , label: "Polyglot · MBP"
    , blurb: "native processes — website (Go static-httpd) · 2× python · julia atlas (supervise :3996)"
    , compose: fixturesDir <> "/polyglot-up/compose.yml"
    , registry: fixturesDir <> "/polyglot-up/registry.json"
    , supervise: Just 3996
    }
  , { key: "polyglot-macmini"
    , label: "Polyglot · MacMini"
    , blurb: "containers — edge + website over ssh docker, Funnel-published (bosun docker :3995)"
    , compose: fixturesDir <> "/polyglot-core/compose.yml"
    , registry: fixturesDir <> "/polyglot-core/registry.json"
    , supervise: Just 3995
    }
  , { key: "atlantis"
    , label: "Atlantis · live-coding rig"
    , blurb: "process tier — es9 · link · fh2 · purerl-tidal · calypso (supervise :3994)"
    , compose: fixturesDir <> "/atlantis/compose.yml"
    , registry: fixturesDir <> "/atlantis/registry.json"
    , supervise: Just 3994
    }
  ]

-- Study fixtures — view-only (no supervise daemon), kept for exploring the
-- ingestion/validation surface and the structural channels.
studyFixtures :: Array Project
studyFixtures =
  [ topo "valid"      "topology ✓ (valid)"     "a clean validated deployment"
  , topo "faults"     "topology ✗ (faults)"    "illegal-state families that survive validation"
  , topo "gradient"   "gradient (all 5 marks)" "every requirement mark on one graph"
  , topo "exposure"   "exposure (ramp)"        "the exposure ramp public→internal"
  , topo "multihost"  "multi-host"             "services spread across hosts"
  , topo "colocation" "co-location"            "co-located services on one host"
  , topo "live"       "◉ live demo"            "the serve safe-fixture (control via :3997)"
  , { key: "corpus", label: "frozen corpus", blurb: "the Detect corpus snapshot"
    , compose: corpusDir <> "/docker-compose.yml", registry: corpusDir <> "/registry.json", supervise: Nothing }
  ]
  where
  topo dir label blurb =
    { key: dir, label, blurb
    , compose: fixturesDir <> "/topologies/" <> dir <> "/compose.yml"
    , registry: fixturesDir <> "/topologies/" <> dir <> "/registry.json"
    , supervise: Nothing
    }

projects :: Array Project
projects = deployments <> studyFixtures

-- ── pivot animation (Hylograph interpolation engine) ─────────────────────────

-- animate the layout from where the nodes are NOW to a target group mode. Shared
-- by the cycle button and the top-nav dropdown; a no-op-looking re-select of the
-- current mode just tweens in place. No analysis ⇒ set the mode without animating.
pivotTo :: forall o. GroupMode -> H.HalogenM State Action () o Aff Unit
pivotTo target = do
  s <- H.get
  case s.analysis of
    Nothing -> H.modify_ _ { groupMode = target }
    Just a -> do
      let
        toPos = layoutPositions target a
        fromPos = if Map.isEmpty s.livePos then layoutPositions s.groupMode a else s.livePos
        gen = s.animGen + 1
        mk (id /\ to) =
          let from = fromMaybe to (Map.lookup id fromPos)
          in { id, st: start (transitionWith lerpPoint { from, to } { duration: pivotMs, easing: CubicInOut, delay: 0.0 }) }
        anims = map mk (Map.toUnfoldable toPos :: Array (String /\ Point))
      H.modify_ _ { groupMode = target, anim = Just anims, livePos = fromPos, animGen = gen }
      void (H.fork (animLoop gen))

pivotMs :: Number
pivotMs = 520.0

frameMs :: Number
frameMs = 16.0

-- A forked frame loop: tick every node's position transition, write the current
-- interpolated points to `livePos` (the graph re-renders from it, so edges
-- follow), and stop when all are complete. The `gen` guard makes a fresh toggle
-- supersede this loop instead of two loops fighting over the same `anim`.
animLoop :: forall o. Int -> H.HalogenM State Action () o Aff Unit
animLoop gen = do
  s <- H.get
  when (s.animGen == gen) case s.anim of
    Nothing -> pure unit
    Just anims -> do
      H.liftAff (delay (Milliseconds frameMs))
      s2 <- H.get
      when (s2.animGen == gen) do
        let
          stepped = map (\an -> an { st = tick frameMs an.st }) anims
          lp = Map.fromFoldable (map (\an -> an.id /\ currentValue an.st) stepped)
          done = all (\an -> isComplete an.st) stepped
        if done then H.modify_ _ { anim = Nothing, livePos = lp }
        else do
          H.modify_ _ { anim = Just stepped, livePos = lp }
          animLoop gen

refresh :: forall o. H.HalogenM State Action () o Aff Unit
refresh = do
  s0 <- H.get
  let base = controlBase s0
  res <- H.liftAff (AX.get RF.json (base <> "/state"))
  -- a supervise project speaks the {desired, services} shape; serve speaks
  -- {routes,redirects,rejected}. Decode the one this daemon emits.
  case res of
    Left err ->
      H.modify_ \s -> s { cockErr = Just (AX.printError err), ticks = s.ticks + 1 }
    Right resp -> case s0.currentProject >>= _.supervise of
      Just _ -> case decodeSuperviseState resp.body of
        Left e ->
          H.modify_ \s -> s { cockErr = Just (printJsonDecodeError e), ticks = s.ticks + 1 }
        Right v -> do
          H.modify_ \s -> s { superv = Just v, cockpit = Nothing, cockErr = Nothing, ticks = s.ticks + 1 }
          -- Auto-re-analyze when the supervised service SET changes under us — a
          -- member added (or removed) via `control/reload`. The graph is analyzed
          -- on project-select (guarded on key change), and the poll otherwise only
          -- refreshes existing nodes' status, so without this a reload'd service is
          -- running in /state yet missing from the graph (the "why isn't it in the
          -- Chair" trap). Comparing against the PREVIOUS poll's key set converges —
          -- after the re-analyze the sets match — and never loops on a phantom key.
          -- `s0.superv` is Nothing right after openProject, so no redundant analyze
          -- on first load (openProject already analyzed).
          case s0.superv of
            Just prev
              | supervKeys prev /= supervKeys v
              , not s0.anaLoading -> runAnalyze
            _ -> pure unit
      Nothing -> case decodeStateView resp.body of
        Left e ->
          H.modify_ \s -> s { cockErr = Just (printJsonDecodeError e), ticks = s.ticks + 1 }
        Right v ->
          H.modify_ \s -> s { cockpit = Just v, superv = Nothing, cockErr = Nothing, ticks = s.ticks + 1 }
  where
  supervKeys v = Set.fromFoldable (FO.keys v.services) :: Set String

-- ── ingestion (pillar 1) — talk to chair-server ──────────────────────────────

mkRequest :: State -> AnalyzeRequest
mkRequest s =
  { compose: nonEmpty s.composePath, registry: nonEmpty s.registryPath, overrides: s.overrides }
  where
  nonEmpty x = if notBlank x then Just x else Nothing

notBlank :: String -> Boolean
notBlank x = not (String.null (String.trim x))

runAnalyze :: forall o. H.HalogenM State Action () o Aff Unit
runAnalyze = do
  H.modify_ _ { anaLoading = true, anaErr = Nothing }
  s <- H.get
  let body = CA.encode analyzeRequestCodec (mkRequest s)
  res <- H.liftAff (AX.post RF.json (analyzeBase <> "/analyze") (Just (RB.json body)))
  H.modify_ \st -> case res of
    Left err -> st { anaLoading = false, anaErr = Just ("chair-server unreachable — " <> AX.printError err) }
    Right resp -> case CA.decode analyzeResultCodec resp.body of
      Left e -> st { anaLoading = false, anaErr = Just (CA.printJsonDecodeError e) }
      -- seed the live positions for the current layout so the graph (and any
      -- subsequent pivot) starts from a settled, correct frame
      Right a -> st { anaLoading = false, analysis = Just a, anaErr = Nothing
                    , livePos = layoutPositions st.groupMode a, anim = Nothing
                    , graphSelect = Nothing }   -- a stale selection wouldn't exist in the new graph
  r <- H.gets _.route
  when (isGraphRoute r) (void (H.fork attachZoom))   -- the svg (re)mounts with the new graph

-- ── pan / zoom (Hylograph.Interaction.Zoom over the main SVG) ─────────────────

zoomMin :: Number
zoomMin = 0.15

zoomMax :: Number
zoomMax = 6.0

-- the graph SVG (a single instance, tagged `.graph-svg`); querying by class
-- avoids a Halogen ref (an <svg> is an SVGElement, not an HTMLElement).
findGraphSvg :: Effect (Maybe Element)
findGraphSvg = do
  doc <- document =<< window
  querySelector (QuerySelector "svg.graph-svg") (toParentNode doc)

-- (re)attach drag-pan / wheel-zoom to the main SVG's `.zoom-group`. Forked by the
-- caller so the yield (the 16ms delay) lands AFTER Halogen has mounted the svg.
-- Idempotent: destroys any prior handle first (the svg is a fresh element when we
-- re-enter the Graph view; persists across pivots/channel toggles, where we don't
-- re-attach). A fresh handle starts at identity, so loading a fixture also resets.
attachZoom :: forall o. H.HalogenM State Action () o Aff Unit
attachZoom = do
  H.liftAff (delay (Milliseconds 16.0))
  old <- H.gets _.zoom
  H.liftEffect (maybe (pure unit) _.destroy old)
  mEl <- H.liftEffect findGraphSvg
  h <- H.liftEffect (traverse mkZoom mEl)
  H.modify_ _ { zoom = h }
  where
  mkZoom el = attachNativeZoom el
    { scaleMin: zoomMin, scaleMax: zoomMax, targetSelector: ".zoom-group"
    , initialTransform: Nothing, translateExtent: Nothing, onZoom: Nothing
    }

-- ── render ───────────────────────────────────────────────────────────────────

-- the full-screen app shell: a shallow top nav over a body that fills the
-- viewport. The Graph view docks the small-multiples rack to the left and gives
-- the rest to the main (scrollable; pan/zoom is the next step) surface; the other
-- views just fill the main pane.
render :: forall m. State -> H.ComponentHTML Action () m
render s =
  HH.div [ cls "app" ]
    [ topNav s
    , HH.div [ cls "appbody" ] (appBody s)
    ]

isGraphRoute :: Route -> Boolean
isGraphRoute = case _ of
  GraphR _ -> true
  _ -> false

appBody :: forall m. State -> Array (H.ComponentHTML Action () m)
appBody s = case s.route of
  Projects -> [ HH.section [ cls "mainpane pad" ] [ renderProjects s ] ]
  GraphR _ -> case s.analysis of
    Nothing ->
      [ HH.section [ cls "mainpane pad" ]
          [ maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text e ]) s.anaErr
          , HH.p [ cls "muted" ] [ HH.text "loading the project graph…" ]
          ]
      ]
    Just a ->
      let
        handlers = { hover: HoverNode, select: SelectNode, toggleChan: ToggleChannel, arm: ToggleArm, groupUp: GroupUp, groupDown: GroupDown, restart: Restart }
        -- live status from whichever daemon backs this project; control + desired
        -- only from a supervise daemon (serve-backed projects are status-only here).
        live = case s.superv of
          Just sv -> superviseLive sv a
          Nothing -> maybe Map.empty (\c -> liveMap c a) s.cockpit
        ctrl = maybe Map.empty (\sv -> superviseCtrl sv a) s.superv
        superv = maybe Map.empty (\sv -> superviseBadge sv a) s.superv
        desired = map (\sv -> sv.desired == "up") s.superv
        -- nodes with a control op in flight (amber "working" wash): PGroup washes
        -- every controllable node; POne washes just the node being restarted.
        pendingIds = case s.controlPending of
          Nothing -> Set.empty
          Just PGroup -> Set.fromFoldable (Map.keys ctrl)
          Just (POne svc) -> Set.fromFoldable (Map.keys (Map.filter (_ == svc) ctrl))
        controlBusy = case s.controlPending of
          Nothing -> false
          _ -> true
        g = graphView handlers s.armed s.groupMode s.channels s.livePos s.graphFocus s.graphSelect live ctrl superv desired pendingIds controlBusy a
      in
        -- main on top, the structural rack docked as a horizontal strip along the
        -- bottom (one row, scrolls sideways); the runtime overlay floats fixed in
        -- the top-right corner above everything (it carries status + arms control).
        [ HH.section [ cls "mainpane" ] [ g.main ]
        , HH.aside [ cls "dock" ]
            [ HH.div [ cls "dock-h" ] [ HH.text "channels" ], g.rack ]
        , g.overlay
        ]
  IngestionR -> [ HH.section [ cls "mainpane pad" ] [ renderIngestion s ] ]
  CockpitR -> [ HH.section [ cls "mainpane pad" ] [ renderCockpit s ] ]

-- the shallow top nav: brand (→ picker) · context · graph controls · status.
topNav :: forall m. State -> H.ComponentHTML Action () m
topNav s =
  HH.header [ cls "appnav" ]
    [ HH.button [ cls "brand brand-btn", HE.onClick \_ -> NavTo Projects ] [ HH.text "Bosun’s Chair" ]
    , case s.route of
        Projects -> HH.span [ cls "muted" ] [ HH.text "choose a project" ]
        GraphR _ -> graphNav s
        IngestionR -> navLabel "ingestion"
        CockpitR -> navLabel "cockpit"
    , HH.span [ cls "nav-spacer" ] []
    -- in Graph view the fixed runtime overlay owns the top-right corner and the
    -- up/down count, so the nav chip would be redundant; show it elsewhere.
    , case s.route of
        GraphR _ -> HH.text ""
        _ -> HH.span [ cls "status" ] [ HH.text serveStatus ]
    ]
  where
  navLabel t = HH.span [ cls "nav-grp" ]
    [ HH.span [ cls "ctx" ] [ HH.text t ]
    , HH.button [ cls "btn xs", HE.onClick \_ -> NavTo Projects ] [ HH.text "← projects" ]
    ]
  serveStatus = case s.cockErr of
    Just _ -> "serve ✕"
    Nothing -> case s.cockpit of
      Nothing -> "serve …"
      Just v -> "serve ◉ " <> show (Array.length (Array.filter _.up v.routes)) <> "/" <> show (Array.length v.routes) <> " up"

-- graph-specific nav cluster: project label · grouping · mark all/none · zoom.
graphNav :: forall m. State -> H.ComponentHTML Action () m
graphNav s =
  HH.span [ cls "nav-grp" ]
    [ HH.button [ cls "btn xs", HE.onClick \_ -> NavTo Projects ] [ HH.text "← projects" ]
    , HH.span [ cls "ctx" ] [ HH.text (maybe "—" _.label s.currentProject) ]
    , HH.select [ cls "sel", HE.onValueChange setGroupOf ]
        [ gopt ByDeps "deps", gopt ByHost "host", gopt ByPack "pack" ]
    , HH.span [ cls "muted" ] [ HH.text "marks" ]
    , HH.button [ cls "btn xs", HE.onClick \_ -> ShowAllChannels ] [ HH.text "all" ]
    , HH.button [ cls "btn xs", HE.onClick \_ -> HideAllChannels ] [ HH.text "none" ]
    , HH.button [ cls "btn xs", HE.onClick \_ -> ResetZoom ] [ HH.text "⤢ reset" ]
    , if s.anaLoading then HH.span [ cls "muted" ] [ HH.text "…" ] else HH.text ""
    ]
  where
  gopt m label = HH.option [ HP.value (gkey m), HP.selected (s.groupMode == m) ] [ HH.text ("group: " <> label) ]
  gkey = case _ of
    ByDeps -> "deps"
    ByHost -> "host"
    ByPack -> "pack"
  setGroupOf = case _ of
    "host" -> SetGroupMode ByHost
    "pack" -> SetGroupMode ByPack
    _ -> SetGroupMode ByDeps

-- ── projects picker (landing) ────────────────────────────────────────────────

renderProjects :: forall m. State -> H.ComponentHTML Action () m
renderProjects s =
  HH.div [ cls "picker-page" ]
    [ maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text e ]) s.anaErr
    , HH.h2 [ cls "picker-h" ] [ HH.text "Root topology" ]
    , HH.p [ cls "muted" ] [ HH.text "the single launchd root and everything it supervises — live, from declared state (click a group to drill in)" ]
    , if Array.null s.topo then HH.p [ cls "muted" ] [ HH.text "resolving topology…" ]
      else HH.div [ cls "topo-tree" ] (map (topoRow s) s.topo)
    , HH.h2 [ cls "picker-h" ] [ HH.text "Serve fleet" ]
    , HH.p [ cls "muted" ] [ HH.text "lazy-spawn dev services on the bosun serve router (:3997) — spawned on first request; green = a backend is live" ]
    , case s.cockpit of
        Just sv | not (Array.null sv.routes) ->
          HH.div [ cls "fleet-grid" ] (map (fleetRow s.fleetNames) (Array.sortWith _.publicPort sv.routes))
        _ -> HH.p [ cls "muted" ] [ HH.text "serve router unreachable or no routes" ]
    , HH.h2 [ cls "picker-h" ] [ HH.text "Study fixtures" ]
    , HH.p [ cls "muted" ] [ HH.text "view-only — explore the ingestion / validation surface and the structural channels" ]
    , HH.div [ cls "proj-grid" ] (map (projCard s false) studyFixtures)
    ]

-- one row of the declared tree: indent by depth, a status dot polled from the
-- owning group's /state, the name, its port chip, and the raw status token.
-- Group rows (sub-supervisors) are clickable — they open their detail graph.
topoRow :: forall m. State -> TopologyEntry -> H.ComponentHTML Action () m
topoRow s e =
  HH.div
    ( [ cls ("topo-row" <> if isGroup then " group" else "")
      , HP.style ("padding-left:" <> show (8 + e.depth * 22) <> "px")
      ] <> clickProps )
    [ HH.span [ cls ("topo-dot " <> statusDotClass status) ] []
    , HH.span [ cls "topo-name" ] [ HH.text e.name ]
    , if portTxt == "" then HH.text "" else HH.span [ cls portCls ] [ HH.text portTxt ]
    , HH.span [ cls "topo-stat" ] [ HH.text status ]
    ]
  where
  isGroup = isJust e.groupPort
  status = fromMaybe "—" (FO.lookup e.name s.topoStatus)
  clickProps = if isGroup then [ HE.onClick \_ -> NavTo (GraphR e.name) ] else []
  portTxt = case e.groupPort, e.port of
    Just gp, _ -> ":" <> show gp
    _, Just p -> ":" <> show p
    _, _ -> ""
  portCls = if isGroup then "topo-gport" else "topo-port"

statusDotClass :: String -> String
statusDotClass = case _ of
  "running" -> "up"
  "starting" -> "up"
  "completed-ok" -> "up"
  "in-backoff" -> "warn"
  "down" -> "down"
  "failed" -> "down"
  _ -> "unknown"

-- one lazy-spawn serve route: a status dot (up ⇒ a backend is live), the human
-- project NAME (from fleet.json, keyed by port — the router only knows the
-- slug:role serviceId), its role, and its public port. Click opens the Cockpit.
fleetRow :: forall m. Map String String -> RouteStatus -> H.ComponentHTML Action () m
fleetRow names r =
  HH.button [ cls "fleet-row", HE.onClick \_ -> NavTo CockpitR ]
    [ HH.span [ cls ("topo-dot " <> if r.up then "up" else "down") ] []
    , HH.span [ cls "fleet-name" ] [ HH.text (serviceName names r.serviceId) ]
    , case roleOf r.serviceId of
        "" -> HH.text ""
        role -> HH.span [ cls "fleet-role" ] [ HH.text role ]
    , HH.span [ cls "fleet-port" ] [ HH.text (":" <> show r.publicPort) ]
    ]

-- a serve/supervise id is "slug:role". Resolve the slug to a human name (from
-- fleet.json; fallback = the id itself), split out the role, or a combined label.
serviceName :: Map String String -> String -> String
serviceName names sid = fromMaybe sid (Map.lookup (slugOf sid) names)

slugOf :: String -> String
slugOf sid = fromMaybe sid (Array.head (String.split (String.Pattern ":") sid))

roleOf :: String -> String
roleOf sid = case String.split (String.Pattern ":") sid of
  [ _, rl ] -> rl
  _ -> ""

serviceLabel :: Map String String -> String -> String
serviceLabel names sid =
  let n = serviceName names sid
  in case roleOf sid of
       "" -> n
       r -> n <> " · " <> r

projCard :: forall m. State -> Boolean -> Project -> H.ComponentHTML Action () m
projCard _ controllable p =
  HH.button [ cls ("proj-card" <> if controllable then " ctl" else ""), HE.onClick \_ -> NavTo (GraphR p.key) ]
    [ HH.div [ cls "proj-top" ]
        [ HH.span [ cls "proj-label" ] [ HH.text p.label ]
        , case p.supervise of
            Just port -> HH.span [ cls "proj-port" ] [ HH.text (":" <> show port) ]
            Nothing -> HH.span [ cls "proj-port view" ] [ HH.text "view" ]
        ]
    , HH.div [ cls "proj-blurb" ] [ HH.text p.blurb ]
    ]

-- | What the last control verb answered, when it is worth saying.
-- |
-- | Shown for a refusal always, and for a success only when the daemon had
-- | something to add — a `down` that stopped everything says "2 stopped" and
-- | that is worth a line; an `up` says nothing interesting and gets none.
controlNotice :: forall m. State -> H.ComponentHTML Action () m
controlNotice s = case s.lastControl of
  Nothing -> HH.text ""
  Just r
    | r.message == "" -> HH.text ""
    | otherwise -> HH.div [ cls (if r.ok then "muted" else "error") ] [ HH.text r.message ]

-- | The services whose last teardown did not settle.
-- |
-- | This is the half that survives a refresh. `controlNotice` shows the answer
-- | to the click that just happened and is gone on the next one; `/state`
-- | carries the verdict until the service is launched again, so a partial
-- | teardown stays visible to whoever looks next — including someone who was
-- | not the one who clicked.
teardownNotice :: forall m. State -> H.ComponentHTML Action () m
teardownNotice s = case s.superv of
  Nothing -> HH.text ""
  Just sv -> case unsettledTeardowns sv of
    [] -> HH.text ""
    rows ->
      HH.div [ cls "error" ]
        ( [ HH.strong_ [ HH.text (show (Array.length rows) <> " service(s) did not stop") ] ]
            <> map row rows
        )
      where
      row (Tuple sid t) =
        HH.div_ [ HH.text ("  " <> sid <> " — " <> t.verdict) ]

-- ── cockpit view ─────────────────────────────────────────────────────────────

renderCockpit :: forall m. State -> H.ComponentHTML Action () m
renderCockpit s =
  HH.div_
    [ HH.div [ cls "toolbar" ]
        [ HH.button [ cls "btn", HE.onClick \_ -> Reload, HP.disabled s.busy ] [ HH.text "⟳ reload registry" ]
        , if s.busy then HH.span [ cls "muted" ] [ HH.text "working…" ] else HH.text ""
        ]
    , maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text ("serve unreachable — " <> e) ]) s.cockErr
    , controlNotice s
    , teardownNotice s
    , case s.cockpit of
        Nothing -> HH.p [ cls "muted" ] [ HH.text "waiting for serve…" ]
        Just v -> cockpitBody s.busy s.fleetNames v
    ]

cockpitBody :: forall m. Boolean -> Map String String -> StateView -> H.ComponentHTML Action () m
cockpitBody busy names v =
  HH.div_
    [ HH.div [ cls "stats" ]
        [ stat "admitted" (show (Array.length (Array.filter _.up v.routes)) <> " / " <> show (Array.length v.routes) <> " up")
        -- Brokered services count SEPARATELY from admitted, because "up" is not
        -- the same claim: for a proxy route bosun holds the port and knows, and
        -- for a broker it holds a pid or a probe or (link-spike over multicast)
        -- neither. Counting the ones bosun started is the only honest number.
        , stat "brokered" (show (Array.length (Array.filter (isJust <<< _.pid) brokers)) <> " / " <> show (Array.length brokers) <> " ours")
        , stat "redirect" (show (Array.length v.redirects))
        , stat "rejected" (show (Array.length v.rejected))
        , stat "drift" (show (Array.length (driftEntries v)))
        ]
    , driftPanel busy names v
    , sectionTable "ADMITTED" (Array.length v.routes) [ "port", "service", "state", "backend", "pid", "" ] (map (routeRow names) v.routes)
    -- Its own section, directly under ADMITTED, because these ARE served here —
    -- they are just not relayed. Putting them below REJECTED would file a
    -- working service with the refusals.
    , sectionTable "BROKERED (no relay)" (Array.length brokers) [ "port", "service", "at", "307 door", "probe", "pid", "" ] (map (brokerRow names) brokers)
    , sectionTable "REDIRECT (421)" (Array.length v.redirects) [ "port", "service", "host", "→ target" ] (map (redirectRow names) v.redirects)
    , sectionTable "REJECTED" (Array.length v.rejected) [ "port", "service", "reason" ] (map (rejectRow names) v.rejected)
    ]
  where
  brokers = brokerEntries v

-- | The third source of truth, made visible. Silent when the registry and the
-- | router agree (the overwhelmingly common case) — and when they don't, it sits
-- | ABOVE the three verdict tables, because a row shown nowhere below is the one
-- | thing those tables cannot tell you about. Every entry has the same single
-- | remedy, so the reload lives here rather than per row.
-- |
-- | It also shows when the check FAILED. A drift check that could not be made
-- | reports an empty `drift`, which is indistinguishable from agreement — so the
-- | panel opens on `registry.error` too, and says the answer below is the last
-- | one rather than a current one.
driftPanel :: forall m. Boolean -> Map String String -> StateView -> H.ComponentHTML Action () m
driftPanel busy names v = case driftEntries v, registryError v of
  [], Nothing -> HH.text ""
  ds, err ->
    HH.div [ cls "drift" ]
      [ HH.div [ cls "drift-head" ]
          [ HH.span [ cls "drift-title" ] [ HH.text (driftTitle ds err) ]
          , HH.button [ cls "btn sm", HE.onClick \_ -> Reload, HP.disabled busy ] [ HH.text "⟳ reload" ]
          ]
      , if Array.null ds then HH.text "" else HH.table_ [ HH.tbody_ (map (driftRow names) ds) ]
      , HH.div [ cls "muted" ] [ HH.text (registryLine v) ]
      ]

driftTitle :: Array DriftInfo -> Maybe String -> String
driftTitle ds = case _ of
  Just e -> "the registry could not be checked — " <> e <> " (the list below, if any, is the last answer)"
  Nothing -> show (Array.length ds) <> " port(s) the router has not read — registered, not routed"

registryError :: StateView -> Maybe String
registryError v = v.registry >>= _.error

driftRow :: forall m. Map String String -> DriftInfo -> H.ComponentHTML Action () m
driftRow names d = HH.tr_ [ td (show d.publicPort), td (serviceLabel names d.serviceId), td d.note ]

-- | Provenance for the drift panel: which registry, and when it was last
-- | written vs when the router last planned from it.
registryLine :: StateView -> String
registryLine v = case v.registry of
  Nothing -> ""
  Just r ->
    r.source
      <> maybe "" (\m -> " · written " <> m) r.modifiedAt
      <> maybe "" (\p -> " · router planned " <> p) r.plannedAt

routeRow :: forall m. Map String String -> RouteStatus -> H.ComponentHTML Action () m
routeRow names r =
  HH.tr_
    [ td (show r.publicPort)
    , td (serviceLabel names r.serviceId)
    , HH.td_ [ HH.span [ cls ("dot " <> stateClass st) ] [ HH.text (stateLabel st) ] ]
    , td (show r.internalPort)
    , td (maybe "—" show r.pid)
    , HH.td_
        -- external and unbound routes have no backend of ours to start or stop;
        -- serve answers 409, so don't offer the button that earns it.
        [ if st == External || st == Unbound then HH.text ""
          else HH.button [ cls "btn sm", HE.onClick \_ -> (if r.up then Stop else Spawn) r.publicPort ]
                 [ HH.text (if r.up then "stop" else "spawn") ]
        ]
    ]
  where
  st = routeState r

-- | What a route actually IS, as opposed to what `up` alone says. `External` and
-- | `Unbound` both used to render as a plain up/down dot, which is how a route
-- | with nothing listening on it at all could sit in the ADMITTED table looking
-- | merely idle.
data RouteState = Up | Down | External | Unbound

derive instance Eq RouteState

routeState :: RouteStatus -> RouteState
routeState r
  | fromMaybe false r.external = External
  -- `bound` absent = an older router that does not report it; assume bound
  -- rather than inventing a fault.
  | not (fromMaybe true r.bound) = Unbound
  | r.up = Up
  | otherwise = Down

stateLabel :: RouteState -> String
stateLabel = case _ of
  Up -> "up"
  Down -> "down"
  External -> "external"
  Unbound -> "unbound"

stateClass :: RouteState -> String
stateClass = case _ of
  Up -> "up"
  Down -> "down"
  External -> "redirect"
  Unbound -> "down"

-- | A BROKERED service. Deliberately NOT a `routeRow` with some columns blank:
-- | almost nothing carries over. There is no internal port (the service keeps
-- | its own address), no `up` column (readiness is whatever `probe` could
-- | establish, and for a UDP fan-out nothing could), and an absent port is
-- | normal rather than a fault.
-- |
-- | The button offers `stop` ONLY when the router holds the pid, on the same
-- | rule `routeRow` follows: bosun does not kill what bosun did not start, so
-- | serve answers 409 for a stop with no child, and a surface that offers the
-- | button which earns the refusal teaches you to ignore refusals. `spawn` is
-- | always safe — it is ensure-and-locate, so on something already running it
-- | answers `started: false` rather than starting a second copy.
brokerRow :: forall m. Map String String -> BrokerStatus -> H.ComponentHTML Action () m
brokerRow names b =
  HH.tr_
    [ td (maybe "—" show b.publicPort)
    , td (serviceLabel names b.serviceId)
    , td (fromMaybe "—" b.at)
    , HH.td_
        [ HH.span [ cls ("dot " <> doorClass door) ] [ HH.text (doorLabel door) ]
        , case b.bindError of
            Nothing -> HH.text ""
            Just e -> HH.span [ cls "muted" ] [ HH.text (" " <> e) ]
        ]
    -- `none` here means NOTHING WAS CHECKED, which is not "down" — the same
    -- distinction `bosun where` prints and PRINCIPLES.md insists on everywhere
    -- an observation is reported.
    , td (case fromMaybe "" b.probe of
            "none" -> "not checked"
            "" -> "—"
            p -> p)
    , td (maybe "—" show b.pid)
    , HH.td_
        [ HH.button
            [ cls "btn sm"
            , HE.onClick \_ -> if isJust b.pid then StopBroker b.serviceId else SpawnBroker b.serviceId
            ]
            [ HH.text (if isJust b.pid then "stop" else "spawn") ]
        ]
    ]
  where
  door = readDoor b.door

-- | The standing of a broker's 307 listener, as an ADT rather than the wire
-- | string it arrives as. `Unstated` is the case the router's five tags do not
-- | cover: a binary predating the field says nothing, which is not the same
-- | claim as "this service has no door" and must not draw as one.
data Door = DoorNone | DoorOpen | DoorAside | DoorReclaim | DoorBlocked | DoorUnstated

readDoor :: Maybe String -> Door
readDoor = case _ of
  Just "none" -> DoorNone
  Just "open" -> DoorOpen
  Just "aside" -> DoorAside
  Just "reclaim" -> DoorReclaim
  Just "blocked" -> DoorBlocked
  _ -> DoorUnstated

doorLabel :: Door -> String
doorLabel = case _ of
  DoorNone -> "no port"
  DoorOpen -> "307"
  DoorAside -> "held elsewhere"
  DoorReclaim -> "reclaiming"
  DoorBlocked -> "unbindable"
  DoorUnstated -> "—"

-- `redirect` for `aside` on purpose: it is the same amber the ADMITTED table
-- uses for a port held by somebody bosun did not start, and it is the same
-- situation one bucket along.
doorClass :: Door -> String
doorClass = case _ of
  DoorNone -> "idle"
  DoorOpen -> "up"
  DoorAside -> "redirect"
  DoorReclaim -> "redirect"
  DoorBlocked -> "down"
  DoorUnstated -> "idle"

redirectRow :: forall m. Map String String -> RedirectInfo -> H.ComponentHTML Action () m
redirectRow names r = HH.tr_ [ td (show r.publicPort), td (serviceLabel names r.serviceId), td r.host, td r.target ]

rejectRow :: forall m. Map String String -> RejectInfo -> H.ComponentHTML Action () m
rejectRow names r =
  HH.tr_ [ td (maybe "—" show r.publicPort), td (serviceLabel names r.serviceId), td r.reason ]

-- ── ingestion view (the MISU ladder) ─────────────────────────────────────────

renderIngestion :: forall m. State -> H.ComponentHTML Action () m
renderIngestion s =
  HH.div_
    [ HH.div [ cls "picker" ]
        [ field "compose (.yml path)" s.composePath SetCompose
        , field "registry (.json path or http URL)" s.registryPath SetRegistry
        , HH.div [ cls "toolbar" ]
            [ HH.button [ cls "btn", HE.onClick \_ -> RunAnalyze, HP.disabled s.anaLoading ] [ HH.text "analyze ▶" ]
            , HH.button [ cls "btn sm", HE.onClick \_ -> LoadCorpus ] [ HH.text "load frozen corpus" ]
            , if s.anaLoading then HH.span [ cls "muted" ] [ HH.text "analysing…" ] else HH.text ""
            ]
        ]
    , maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text e ]) s.anaErr
    , case s.analysis of
        Nothing -> HH.p [ cls "muted" ] [ HH.text "point the Chair at a compose file and a registry, then analyze." ]
        Just a -> ladder s a
    ]
  where
  field label val act =
    HH.label [ cls "field" ]
      [ HH.span [ cls "field-lbl" ] [ HH.text label ]
      , HH.input [ cls "inp", HP.value val, HE.onValueInput act, HP.placeholder "/abs/path…" ]
      ]

-- ── live overlay: correlate serve /state to graph nodes ──────────────────────

-- | Map each graph node id (an instance's `localName`) to its runtime status.
-- | The bridge: /state keys by canonical `projectSlug:role`; nodes key by
-- | localName. `reconcile.aliases` (ingested name → canonical) carries the
-- | cross-source merge (compose's `gallery-web` ↔ registry's `gallery:frontend`);
-- | where there's no alias (single-source registry), the instance's own
-- | `project:role` IS the canonical id. A node with no matching route/redirect is
-- | `LiveUnknown` and draws nothing — so the overlay is silent on fixtures that
-- | aren't serve-managed.
liveMap :: StateView -> AnalyzeResult -> Map String NodeLive
liveMap sv a =
  Map.fromFoldable (map (\i -> i.localName /\ statusFor (canonOf a i)) a.instances)
  where
  routeStatus = Map.fromFoldable (map (\r -> r.serviceId /\ (if r.up then LiveUp else LiveDown)) sv.routes)
  redirectIds = Set.fromFoldable (map _.serviceId sv.redirects)
  -- A brokered service is `LiveUp` only when the router holds its pid. It is
  -- NOT `LiveDown` otherwise: the router genuinely does not know — a daemon
  -- started by hand, or one whose probe is `none`, is running or not running
  -- and no evidence here can say which. `LiveUnknown` draws no dot, which is
  -- the right thing to draw for a fact nobody has.
  brokerUp = Set.fromFoldable (map _.serviceId (Array.filter (isJust <<< _.pid) (brokerEntries sv)))
  statusFor canon = case Map.lookup canon routeStatus of
    Just s -> s
    Nothing
      | Set.member canon redirectIds -> LiveRedirect
      | Set.member canon brokerUp -> LiveUp
      | otherwise -> LiveUnknown

-- | Map each graph node id → its serve public port, for the armed control mode.
-- | Only serve ROUTES are controllable (redirects live on another host; rejects
-- | and non-serve nodes have no port), so a node absent from this map gets no
-- | control button even when armed. Same canonicalisation bridge as `liveMap`.
controlMap :: StateView -> AnalyzeResult -> Map String Int
controlMap sv a =
  Map.fromFoldable (Array.mapMaybe entry a.instances)
  where
  portByCanon = Map.fromFoldable (map (\r -> r.serviceId /\ r.publicPort) sv.routes)
  entry i = map (\p -> i.localName /\ p) (Map.lookup (canonOf a i) portByCanon)

-- | The canonical serviceId for an instance — node `localName` bridged to the
-- | `projectSlug:role` the daemons key by, via `reconcile.aliases` (else the
-- | instance's own `project:role`). Shared by every correlation map.
canonOf :: AnalyzeResult -> ServiceInstanceView -> String
canonOf a i =
  fromMaybe (maybe i.localName (\p -> p <> ":" <> i.role) i.project)
    (Map.lookup i.localName aliasM)
  where aliasM = Map.fromFoldable (map (\e -> e.from /\ e.to) a.reconcile.aliases)

-- | supervise /state → each graph node's runtime status. `services` is keyed by
-- | canonical serviceId; we look each node up through the same `canonOf` bridge.
-- | The richer supervise tokens collapse onto the Chair's 4-state NodeLive:
-- | running/starting/completed-ok → up; failed/down/in-backoff → down (the alarm
-- | + blast); anything else → unknown (no dot).
superviseLive :: SuperviseState -> AnalyzeResult -> Map String NodeLive
superviseLive sv a =
  Map.fromFoldable (map (\i -> i.localName /\ statusFor (canonOf a i)) a.instances)
  where
  statusFor canon = maybe LiveUnknown tokenToLive (FO.lookup canon sv.services)

tokenToLive :: String -> NodeLive
tokenToLive = case _ of
  "running" -> LiveUp
  "starting" -> LiveUp
  "completed-ok" -> LiveUp
  "failed" -> LiveDown
  "down" -> LiveDown
  "in-backoff" -> LiveDown
  _ -> LiveUnknown

-- | supervise /state → each supervised node's serviceId (the atomic-restart
-- | target). A node is controllable iff its canonical id is in `services`.
superviseCtrl :: SuperviseState -> AnalyzeResult -> Map String String
superviseCtrl sv a =
  Map.fromFoldable (Array.mapMaybe entry a.instances)
  where
  entry i = let c = canonOf a i in if FO.member c sv.services then Just (i.localName /\ c) else Nothing

-- | supervise /state → node id ↦ restart count, for the `↻` auto-restart badge.
-- | PRESENCE in this map means "this process will self-heal" (it's under an
-- | active supervisor). Sourced from the D-S1 `supervision` map when present
-- | (carrying real counts); else, for a `supervised: true` daemon that predates
-- | D-S1, every managed service still self-heals — fall back to count 0.
superviseBadge :: SuperviseState -> AnalyzeResult -> Map String Int
superviseBadge sv a = case sv.supervision of
  Just m -> Map.fromFoldable (Array.mapMaybe (rowEntry m) a.instances)
  Nothing
    | sv.supervised == Just true -> Map.fromFoldable (Array.mapMaybe svcEntry a.instances)
    | otherwise -> Map.empty
  where
  rowEntry m i = map (\row -> i.localName /\ row.restarts) (FO.lookup (canonOf a i) m)
  svcEntry i = if FO.member (canonOf a i) sv.services then Just (i.localName /\ 0) else Nothing

ladder :: forall m. State -> AnalyzeResult -> H.ComponentHTML Action () m
ladder s a =
  HH.div_
    [ rung "①" "Ingest" "messy config strings → precise typed instances"
        "made impossible: ports out of range · non-absolute cwd · image AND build at once"
        [ sectionTable ("INSTANCES") (Array.length a.instances)
            [ "source", "service", "role", "host", "mechanism", "exposure" ]
            (map instanceRow a.instances)
        ]
    , rung "②" "Reconcile" "many sources → one identity per service"
        "divergence (expected) is kept apart from conflict (an error); made impossible: two identities for one service"
        [ HH.div [ cls "stats" ]
            [ stat "services" (show (Array.length a.reconcile.services))
            , stat "divergences" (show (Array.length a.reconcile.divergences))
            , stat "conflicts" (show (Array.length a.reconcile.conflicts))
            , stat "aliases" (show (Array.length a.reconcile.aliases))
            ]
        , sectionTable "FACET DIVERGENCE (informational)" (Array.length a.reconcile.divergences)
            [ "service", "facets" ] (map divergenceRow a.reconcile.divergences)
        , sectionTable "CROSS-SOURCE CONFLICT" (Array.length a.reconcile.conflicts)
            [ "service", "field", "claims" ] (map conflictRow a.reconcile.conflicts)
        , aliasEdits s
        , sectionTable "ALIAS MAP (why they grouped)" (Array.length a.reconcile.aliases)
            [ "ingested name", "→ canonical id", "" ] (map aliasRow a.reconcile.aliases)
        ]
    , rung "③" "Validate" "the loose deployment → the TIGHT ValidatedDeployment"
        "made UNREPRESENTABLE: dangling deps · cycles · unbacked routes · uncheckable gates · selector not closed"
        [ rungResult a.result ]
    ]

rungResult :: forall m. ValidationView -> H.ComponentHTML Action () m
rungResult = case _ of
  Valid v ->
    HH.div [ cls "ok-panel" ]
      [ HH.p [ cls "ok-head" ] [ HH.text "✓ MISU spec — illegal states discharged; plan / apply are now total." ]
      , sectionTable "BOOT ORDER (proven acyclic — stages)" (Array.length v.bootOrder)
          [ "stage", "services (independent within)" ] (Array.mapWithIndex stageRow v.bootOrder)
      , sectionTable "BACKED ROUTES" (Array.length v.routes) [ "path", "→ backend" ] (map routeBackingRow v.routes)
      , sectionTable "SERVICES" (Array.length v.services) [ "service", "host", "exposure", "deps" ] (map svcRow v.services)
      ]
  Invalid errs ->
    HH.div [ cls "err-panel" ]
      ( [ HH.p [ cls "err-head" ] [ HH.text ("✗ " <> show (Array.length errs) <> " illegal-state " <> plural (Array.length errs) "family" "families" <> " survived — cannot mint a ValidatedDeployment.") ] ]
          <> map errorCard errs
      )
  where
  plural n one many = if n == 1 then one else many

-- ── ingestion rows ───────────────────────────────────────────────────────────

instanceRow :: forall m. ServiceInstanceView -> H.ComponentHTML Action () m
instanceRow i =
  HH.tr_
    [ HH.td_ [ HH.span [ cls ("badge src-" <> i.source) ] [ HH.text i.source ] ]
    , td i.localName
    , td i.role
    , td (maybe "—" identity i.host)
    , HH.td_ [ HH.span [ cls "mech" ] [ HH.text i.executor.mechanism ], HH.span [ cls "muted detail" ] [ HH.text (" " <> i.executor.detail) ] ]
    , td i.exposure
    ]

divergenceRow :: forall m. DivergenceView -> H.ComponentHTML Action () m
divergenceRow d =
  HH.tr_
    [ td d.svc
    , HH.td_ (Array.intersperse (HH.span [ cls "muted" ] [ HH.text " · " ]) (map facetPill d.facets))
    ]
  where
  facetPill f = HH.span [ cls "pill" ] [ HH.text (maybe "" (_ <> "/") f.host <> f.mechanism) ]

conflictRow :: forall m. ConflictView -> H.ComponentHTML Action () m
conflictRow c =
  HH.tr_
    [ td c.svc
    , td c.field
    , td (String.joinWith ", " (map (\cl -> cl.source <> "=" <> cl.value) c.claims))
    ]

aliasRow :: forall m. AliasEntry -> H.ComponentHTML Action () m
aliasRow al =
  HH.tr_
    [ td al.from
    , td al.to
    , HH.td_ [ HH.button [ cls "btn sm", HE.onClick \_ -> SplitAlias al.from ] [ HH.text "split" ] ]
    ]

-- ── editable aliases (C2): active overrides + a merge form ───────────────────

overrideLabel :: AliasOverride -> String
overrideLabel = case _ of
  Merge m -> "merge " <> String.joinWith "+" m.names <> " → " <> m.canonical
  Split sp -> "split " <> sp.name

aliasEdits :: forall m. State -> H.ComponentHTML Action () m
aliasEdits s =
  HH.div [ cls "edits" ]
    [ HH.div [ cls "edits-lbl" ] [ HH.text "alias edits (session-local)" ]
    , if Array.null s.overrides then HH.span [ cls "muted" ] [ HH.text "no overrides — showing the auto-derived map" ]
      else HH.div [ cls "chips" ] (Array.mapWithIndex chip s.overrides)
    , HH.div [ cls "merge-form" ]
        [ HH.input [ cls "inp sm", HP.value s.mergeName, HE.onValueInput SetMergeName, HP.placeholder "ingested name" ]
        , HH.span [ cls "muted" ] [ HH.text "→" ]
        , HH.input [ cls "inp sm", HP.value s.mergeCanon, HE.onValueInput SetMergeCanon, HP.placeholder "canonical id" ]
        , HH.button [ cls "btn sm", HE.onClick \_ -> AddMerge ] [ HH.text "merge" ]
        ]
    ]
  where
  chip i ov =
    HH.span [ cls "chip" ]
      [ HH.text (overrideLabel ov)
      , HH.button [ cls "chip-x", HE.onClick \_ -> RemoveOverride i ] [ HH.text "✕" ]
      ]

stageRow :: forall m. Int -> Array String -> H.ComponentHTML Action () m
stageRow n svcs = HH.tr_ [ td (show (n + 1)), td (String.joinWith ", " svcs) ]

routeBackingRow :: forall m. RouteBacking -> H.ComponentHTML Action () m
routeBackingRow r = HH.tr_ [ td r.path, td r.backend ]

svcRow :: forall m. SvcView -> H.ComponentHTML Action () m
svcRow s = HH.tr_ [ td s.id, td (maybe "—" identity s.host), td s.exposure, td (String.joinWith ", " s.deps) ]

errorCard :: forall m. DeployErrorView -> H.ComponentHTML Action () m
errorCard e =
  HH.div [ cls "err-card" ]
    [ HH.div [ cls "err-kind" ] [ HH.text e.kind ]
    , HH.div [ cls "err-detail" ] [ HH.text e.detail ]
    , HH.ul [ cls "rem" ] (map (\r -> HH.li_ [ HH.text r ]) e.remediation)
    ]

-- ── shared html helpers ──────────────────────────────────────────────────────

rung
  :: forall m
   . String -> String -> String -> String
  -> Array (H.ComponentHTML Action () m)
  -> H.ComponentHTML Action () m
rung numeral title gloss extinguishes body =
  HH.section [ cls "rung" ]
    [ HH.div [ cls "rung-cap" ]
        [ HH.span [ cls "rung-num" ] [ HH.text numeral ]
        , HH.span [ cls "rung-title" ] [ HH.text title ]
        , HH.span [ cls "rung-gloss" ] [ HH.text gloss ]
        ]
    , HH.p [ cls "rung-misu" ] [ HH.text extinguishes ]
    , HH.div_ body
    ]

sectionTable
  :: forall m
   . String -> Int -> Array String -> Array (H.ComponentHTML Action () m) -> H.ComponentHTML Action () m
sectionTable title n heads rows =
  HH.section [ cls "sec" ]
    [ HH.h2_ [ HH.text (title <> " "), HH.span [ cls "count" ] [ HH.text (show n) ] ]
    , if n == 0 then HH.p [ cls "muted" ] [ HH.text "none" ]
      else HH.table_
        [ HH.thead_ [ HH.tr_ (map (\h -> HH.th_ [ HH.text h ]) heads) ]
        , HH.tbody_ rows
        ]
    ]

stat :: forall m. String -> String -> H.ComponentHTML Action () m
stat label val =
  HH.div [ cls "stat" ]
    [ HH.div [ cls "stat-val" ] [ HH.text val ]
    , HH.div [ cls "stat-lbl" ] [ HH.text label ]
    ]

td :: forall m. String -> H.ComponentHTML Action () m
td t = HH.td_ [ HH.text t ]

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls c = HP.class_ (HH.ClassName c)
