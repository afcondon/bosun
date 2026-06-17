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
import Bosun.View (AliasEntry, AliasOverride(..), AnalyzeRequest, AnalyzeResult, ConflictView, DeployErrorView, DivergenceView, RouteBacking, ServiceInstanceView, SvcView, ValidationView(..), analyzeRequestCodec, analyzeResultCodec)
import Chair.Graph (Channel, GroupMode(..), NodeLive(..), allChannels, graphView, layoutPositions, nextMode)
import Chair.State (RedirectInfo, RejectInfo, RouteStatus, StateView, decodeStateView)
import Data.Argonaut.Decode.Error (printJsonDecodeError)
import Data.Array as Array
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Foldable (all)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Tuple.Nested (type (/\), (/\))
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay)
import Hylograph.Transition.Easing (EasingType(..))
import Hylograph.Transition.Engine (TransitionState, currentValue, isComplete, start, tick, transitionWith)
import Hylograph.Transition.Interpolate (Point, lerpPoint)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)

serveBase :: String
serveBase = "http://localhost:3997"

analyzeBase :: String
analyzeBase = "http://localhost:3022"

pollMs :: Number
pollMs = 1500.0

-- The frozen Detect corpus — a one-click sample for the ingestion view.
corpusDir :: String
corpusDir = "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures/polyglot-2026-06-14"

-- Fabricated topology fixtures (rich dependency structure for the graph view).
fixturesDir :: String
fixturesDir = "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures"

data View = Cockpit | Ingestion | Graph
derive instance Eq View

type State =
  { view :: View
  -- cockpit (pillar 0)
  , cockpit :: Maybe StateView
  , cockErr :: Maybe String
  , ticks :: Int
  , busy :: Boolean
  -- ingestion (pillar 1)
  , composePath :: String
  , registryPath :: String
  , fixtureKey :: String      -- which named fixture the graph dropdown has loaded
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
  , channels :: Set Channel  -- which display channels are composited into the view
  }

-- one node's position transition (interpolating a 2D Point through the engine)
type AnimNode = { id :: String, st :: TransitionState Point }

data Action
  = Initialize
  | Refresh
  | Reload
  | Spawn Int
  | Stop Int
  | Goto View
  | SetCompose String
  | SetRegistry String
  | LoadCorpus
  | LoadPaths String String   -- set compose+registry paths, then analyze
  | LoadFixture String        -- pick a named fixture from the top-nav dropdown
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

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

component :: forall q i o. H.Component q i o Aff
component =
  H.mkComponent
    { initialState: \_ ->
        { view: Ingestion
        , cockpit: Nothing, cockErr: Nothing, ticks: 0, busy: false
        , composePath: "", registryPath: "", fixtureKey: "", analysis: Nothing, anaErr: Nothing, anaLoading: false
        , overrides: [], mergeName: "", mergeCanon: ""
        , graphFocus: Nothing, graphSelect: Nothing, groupMode: ByDeps
        , livePos: Map.empty, anim: Nothing, animGen: 0
        , channels: Set.fromFoldable allChannels   -- default: full composite (clutter is a fine resting state)
        }
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction, initialize = Just Initialize }
    }

handleAction :: forall o. Action -> H.HalogenM State Action () o Aff Unit
handleAction = case _ of
  Initialize -> do
    refresh
    void (H.fork pollLoop)
  Refresh -> refresh
  Reload -> control "/control/reload"
  Spawn port -> control ("/control/spawn?port=" <> show port)
  Stop port -> control ("/control/stop?port=" <> show port)
  Goto v -> H.modify_ _ { view = v }
  SetCompose s -> H.modify_ _ { composePath = s }
  SetRegistry s -> H.modify_ _ { registryPath = s }
  LoadCorpus -> H.modify_ _
    { composePath = corpusDir <> "/docker-compose.yml", registryPath = corpusDir <> "/registry.json" }
  LoadPaths c r -> do
    H.modify_ _ { composePath = c, registryPath = r }
    runAnalyze
  LoadFixture key -> case Array.find (\f -> f.key == key) fixtures of
    Nothing -> pure unit
    Just f -> do
      H.modify_ _ { composePath = f.compose, registryPath = f.registry, fixtureKey = key }
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
  RemoveOverride i -> do
    H.modify_ \s -> s { overrides = fromMaybe s.overrides (Array.deleteAt i s.overrides) }
    runAnalyze

-- ── cockpit (pillar 0) — talk to bosun serve ─────────────────────────────────

control :: forall o. String -> H.HalogenM State Action () o Aff Unit
control path = do
  H.modify_ _ { busy = true }
  _ <- H.liftAff (AX.post RF.ignore (serveBase <> path) Nothing)
  H.modify_ _ { busy = false }
  refresh

pollLoop :: forall o. H.HalogenM State Action () o Aff Unit
pollLoop = do
  H.liftAff (delay (Milliseconds pollMs))
  refresh
  pollLoop

-- ── named fixtures (the top-nav dropdown) ────────────────────────────────────

type FixtureDef = { key :: String, label :: String, compose :: String, registry :: String }

fixtures :: Array FixtureDef
fixtures =
  [ topo "valid"     "topology ✓ (valid)"
  , topo "faults"    "topology ✗ (faults)"
  , topo "gradient"  "gradient (all 5 marks)"
  , topo "exposure"  "exposure (ramp)"
  , topo "multihost" "multi-host"
  , topo "colocation" "co-location"
  , topo "live"      "◉ live demo"
  , { key: "corpus", label: "frozen corpus", compose: corpusDir <> "/docker-compose.yml", registry: corpusDir <> "/registry.json" }
  ]
  where
  topo dir label =
    { key: dir, label
    , compose: fixturesDir <> "/topologies/" <> dir <> "/compose.yml"
    , registry: fixturesDir <> "/topologies/" <> dir <> "/registry.json"
    }

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
  res <- H.liftAff (AX.get RF.json (serveBase <> "/state"))
  H.modify_ \s -> case res of
    Left err -> s { cockErr = Just (AX.printError err), ticks = s.ticks + 1 }
    Right resp -> case decodeStateView resp.body of
      Left e -> s { cockErr = Just (printJsonDecodeError e), ticks = s.ticks + 1 }
      Right v -> s { cockpit = Just v, cockErr = Nothing, ticks = s.ticks + 1 }

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

appBody :: forall m. State -> Array (H.ComponentHTML Action () m)
appBody s = case s.view of
  Graph -> case s.analysis of
    Nothing ->
      [ HH.section [ cls "mainpane pad" ]
          [ maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text e ]) s.anaErr
          , HH.p [ cls "muted" ] [ HH.text "choose a topology in the top bar — the graph renders the same AnalyzeResult the Ingestion view uses." ]
          ]
      ]
    Just a ->
      let
        g = graphView HoverNode SelectNode ToggleChannel s.groupMode s.channels s.livePos s.graphFocus s.graphSelect
          (maybe Map.empty (\sv -> liveMap sv a) s.cockpit) a
      in
        -- main on top, the rack as a horizontal strip docked along the bottom
        -- (one row, scrolls sideways) so the rail never re-enters vertical
        -- scrolling as the thumbnails get taller under a draggable main view.
        [ HH.section [ cls "mainpane" ] [ g.main ]
        , HH.aside [ cls "dock" ]
            [ HH.div [ cls "dock-h" ] [ HH.text "channels" ], g.rack ]
        ]
  Ingestion -> [ HH.section [ cls "mainpane pad" ] [ renderIngestion s ] ]
  Cockpit -> [ HH.section [ cls "mainpane pad" ] [ renderCockpit s ] ]

-- the shallow top nav: brand · view switcher · view-specific controls · status.
topNav :: forall m. State -> H.ComponentHTML Action () m
topNav s =
  HH.header [ cls "appnav" ]
    [ HH.span [ cls "brand" ] [ HH.text "Bosun’s Chair" ]
    , viewSelect s
    , case s.view of
        Graph -> graphNav s
        _ -> HH.text ""
    , HH.span [ cls "nav-spacer" ] []
    , HH.span [ cls "status" ] [ HH.text serveStatus ]
    ]
  where
  serveStatus = case s.cockErr of
    Just _ -> "serve ✕"
    Nothing -> case s.cockpit of
      Nothing -> "serve …"
      Just v -> "serve ◉ " <> show (Array.length (Array.filter _.up v.routes)) <> "/" <> show (Array.length v.routes) <> " up"

viewSelect :: forall m. State -> H.ComponentHTML Action () m
viewSelect s =
  HH.select [ cls "sel", HE.onValueChange gotoOf ]
    [ vopt "ingestion" "Ingestion" (s.view == Ingestion)
    , vopt "graph" "Graph" (s.view == Graph)
    , vopt "cockpit" "Cockpit" (s.view == Cockpit)
    ]
  where
  vopt val label sel = HH.option [ HP.value val, HP.selected sel ] [ HH.text label ]
  gotoOf = case _ of
    "graph" -> Goto Graph
    "cockpit" -> Goto Cockpit
    _ -> Goto Ingestion

-- graph-specific nav cluster: fixture chooser, grouping, mark all/none.
graphNav :: forall m. State -> H.ComponentHTML Action () m
graphNav s =
  HH.span [ cls "nav-grp" ]
    [ HH.select [ cls "sel", HE.onValueChange LoadFixture ]
        ( [ HH.option [ HP.value "", HP.selected (s.fixtureKey == "") ] [ HH.text "load fixture…" ] ]
            <> map (\f -> HH.option [ HP.value f.key, HP.selected (s.fixtureKey == f.key) ] [ HH.text f.label ]) fixtures
        )
    , HH.select [ cls "sel", HE.onValueChange setGroupOf ]
        [ gopt ByDeps "deps", gopt ByHost "host", gopt ByPack "pack" ]
    , HH.span [ cls "muted" ] [ HH.text "marks" ]
    , HH.button [ cls "btn xs", HE.onClick \_ -> ShowAllChannels ] [ HH.text "all" ]
    , HH.button [ cls "btn xs", HE.onClick \_ -> HideAllChannels ] [ HH.text "none" ]
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

-- ── cockpit view ─────────────────────────────────────────────────────────────

renderCockpit :: forall m. State -> H.ComponentHTML Action () m
renderCockpit s =
  HH.div_
    [ HH.div [ cls "toolbar" ]
        [ HH.button [ cls "btn", HE.onClick \_ -> Reload, HP.disabled s.busy ] [ HH.text "⟳ reload registry" ]
        , if s.busy then HH.span [ cls "muted" ] [ HH.text "working…" ] else HH.text ""
        ]
    , maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text ("serve unreachable — " <> e) ]) s.cockErr
    , case s.cockpit of
        Nothing -> HH.p [ cls "muted" ] [ HH.text "waiting for serve…" ]
        Just v -> cockpitBody v
    ]

cockpitBody :: forall m. StateView -> H.ComponentHTML Action () m
cockpitBody v =
  HH.div_
    [ HH.div [ cls "stats" ]
        [ stat "admitted" (show (Array.length (Array.filter _.up v.routes)) <> " / " <> show (Array.length v.routes) <> " up")
        , stat "redirect" (show (Array.length v.redirects))
        , stat "rejected" (show (Array.length v.rejected))
        ]
    , sectionTable "ADMITTED" (Array.length v.routes) [ "port", "service", "state", "backend", "pid", "" ] (map routeRow v.routes)
    , sectionTable "REDIRECT (421)" (Array.length v.redirects) [ "port", "service", "host", "→ target" ] (map redirectRow v.redirects)
    , sectionTable "REJECTED" (Array.length v.rejected) [ "service", "reason" ] (map rejectRow v.rejected)
    ]

routeRow :: forall m. RouteStatus -> H.ComponentHTML Action () m
routeRow r =
  HH.tr_
    [ td (show r.publicPort)
    , td r.serviceId
    , HH.td_ [ HH.span [ cls (if r.up then "dot up" else "dot down") ] [ HH.text (if r.up then "up" else "down") ] ]
    , td (show r.internalPort)
    , td (maybe "—" show r.pid)
    , HH.td_ [ HH.button [ cls "btn sm", HE.onClick \_ -> (if r.up then Stop else Spawn) r.publicPort ] [ HH.text (if r.up then "stop" else "spawn") ] ]
    ]

redirectRow :: forall m. RedirectInfo -> H.ComponentHTML Action () m
redirectRow r = HH.tr_ [ td (show r.publicPort), td r.serviceId, td r.host, td r.target ]

rejectRow :: forall m. RejectInfo -> H.ComponentHTML Action () m
rejectRow r = HH.tr_ [ td r.serviceId, td r.reason ]

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
  Map.fromFoldable (map (\i -> i.localName /\ statusFor (canonOf i)) a.instances)
  where
  routeStatus = Map.fromFoldable (map (\r -> r.serviceId /\ (if r.up then LiveUp else LiveDown)) sv.routes)
  redirectIds = Set.fromFoldable (map _.serviceId sv.redirects)
  aliasM = Map.fromFoldable (map (\e -> e.from /\ e.to) a.reconcile.aliases)
  canonOf i = fromMaybe (maybe i.localName (\p -> p <> ":" <> i.role) i.project) (Map.lookup i.localName aliasM)
  statusFor canon = case Map.lookup canon routeStatus of
    Just s -> s
    Nothing -> if Set.member canon redirectIds then LiveRedirect else LiveUnknown

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
