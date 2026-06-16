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
import Chair.Graph (graphView)
import Chair.State (RedirectInfo, RejectInfo, RouteStatus, StateView, decodeStateView)
import Data.Argonaut.Decode.Error (printJsonDecodeError)
import Data.Array as Array
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay)
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
  , analysis :: Maybe AnalyzeResult
  , anaErr :: Maybe String
  , anaLoading :: Boolean
  -- editable aliases (C2) — session-local overrides on top of the auto map
  , overrides :: Array AliasOverride
  , mergeName :: String
  , mergeCanon :: String
  }

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
  | RunAnalyze
  -- editable aliases (C2)
  | SetMergeName String
  | SetMergeCanon String
  | AddMerge
  | SplitAlias String
  | RemoveOverride Int

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
        , composePath: "", registryPath: "", analysis: Nothing, anaErr: Nothing, anaLoading: false
        , overrides: [], mergeName: "", mergeCanon: ""
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
      Right a -> st { anaLoading = false, analysis = Just a, anaErr = Nothing }

-- ── render ───────────────────────────────────────────────────────────────────

render :: forall m. State -> H.ComponentHTML Action () m
render s =
  HH.div [ cls "chair" ]
    [ HH.header [ cls "head" ]
        [ HH.h1_ [ HH.text "Bosun’s Chair" ]
        , HH.p [ cls "sub" ] [ HH.text subtitle ]
        , HH.div [ cls "nav" ]
            [ navBtn Ingestion "Ingestion"
            , navBtn Graph "Graph"
            , navBtn Cockpit "Cockpit"
            ]
        ]
    , case s.view of
        Cockpit -> renderCockpit s
        Ingestion -> renderIngestion s
        Graph -> renderGraphView s
    , HH.footer [ cls "foot" ] [ HH.text ("refresh #" <> show s.ticks) ]
    ]
  where
  subtitle = case s.view of
    Cockpit -> "cockpit for bosun serve · polling localhost:3997/state"
    Ingestion -> "ingestion ladder · POST localhost:3022/analyze"
    Graph -> "deployment graph · loose dependency view (Pillar 3, increment 1)"
  navBtn v label =
    HH.button
      [ cls (if s.view == v then "btn active" else "btn"), HE.onClick \_ -> Goto v ]
      [ HH.text label ]

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

-- ── graph view (pillar 3) — a new render of the same AnalyzeResult ───────────

renderGraphView :: forall m. State -> H.ComponentHTML Action () m
renderGraphView s =
  HH.div_
    [ HH.div [ cls "toolbar" ]
        [ HH.span [ cls "muted" ] [ HH.text "load:" ]
        , HH.button [ cls "btn sm", HE.onClick \_ -> LoadPaths (fixturesDir <> "/topologies/valid/compose.yml") (fixturesDir <> "/topologies/valid/registry.json") ] [ HH.text "topology ✓ (valid)" ]
        , HH.button [ cls "btn sm", HE.onClick \_ -> LoadPaths (fixturesDir <> "/topologies/faults/compose.yml") (fixturesDir <> "/topologies/faults/registry.json") ] [ HH.text "topology ✗ (faults)" ]
        , HH.button [ cls "btn sm", HE.onClick \_ -> LoadPaths (fixturesDir <> "/topologies/gradient/compose.yml") (fixturesDir <> "/topologies/gradient/registry.json") ] [ HH.text "gradient (all 5 marks)" ]
        , HH.button [ cls "btn sm", HE.onClick \_ -> LoadPaths (fixturesDir <> "/topologies/exposure/compose.yml") (fixturesDir <> "/topologies/exposure/registry.json") ] [ HH.text "exposure (ramp)" ]
        , HH.button [ cls "btn sm", HE.onClick \_ -> LoadPaths (corpusDir <> "/docker-compose.yml") (corpusDir <> "/registry.json") ] [ HH.text "frozen corpus" ]
        , if s.anaLoading then HH.span [ cls "muted" ] [ HH.text "analysing…" ] else HH.text ""
        ]
    , maybe (HH.text "") (\e -> HH.div [ cls "error" ] [ HH.text e ]) s.anaErr
    , case s.analysis of
        Nothing -> HH.p [ cls "muted" ] [ HH.text "load a fixture above — the graph renders the same AnalyzeResult the Ingestion view uses." ]
        Just a -> graphView a
    ]

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
