-- | Bosun's Chair — Pillar 3, the deployment-graph view (increment 1).
-- |
-- | A *new render of the same `AnalyzeResult`* the ingestion view already
-- | fetches — no backend change (docs/GRAPH-GRAMMAR.md §10). This first
-- | increment is deliberately a STATIC render with a pure, hand-rolled
-- | layered-by-depth layout (no force simulation yet — §4.8: structured
-- | layouts rest, force is a later tool). It proves the rendering vocabulary:
-- |
-- |   · nodes from the loose `instances`, **bordered by source** (§2.9/§4.1);
-- |   · dependency edges from `instances[].deps`, each carrying a single
-- |     **midpoint mark** for the requirement gradient (§4.3) — ○ / ◉ / ● /
-- |     ○○ / ●● — not UML arrowhead+tail+stroke (the "locality" principle);
-- |   · **ghost nodes** for dangling dep targets no source defines (the
-- |     `DanglingDependency` finding, *seen*);
-- |   · cycles render as visible back-edges (layout breaks them, doesn't crash).
-- |
-- | Force layout, the boot-order tight DAG, host hulls and the deck-of-cards
-- | are later increments (docs/GRAPH-GRAMMAR.md §12).
module Chair.Graph (graphView) where

import Prelude

import Bosun.View (AnalyzeResult, ServiceInstanceView)
import Data.Array as Array
import Data.Foldable (foldl, maximum)
import Data.Int (round, toNumber)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.String.CodeUnits (length, take)
import Data.Tuple.Nested ((/\))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.Svg.Attributes as SA
import Halogen.Svg.Elements as SE

-- ── layout constants ─────────────────────────────────────────────────────────

rowGap :: Number
rowGap = 76.0

nodeW :: Number
nodeW = 150.0

nodeH :: Number
nodeH = 42.0

marginX :: Number
marginX = 36.0

marginY :: Number
marginY = 52.0   -- headroom for the labelled dependency axis

-- ── derived model ────────────────────────────────────────────────────────────

type Edge = { from :: String, to :: String, req :: Maybe String }

-- a data/traffic edge (reverse-proxy route): proxy → backend, carrying a path.
-- A SEPARATE graph from lifecycle deps (D-5) — never topo-sorted, own channel.
type Route = { from :: String, to :: String, path :: String }

type Node =
  { id :: String
  , x :: Number
  , y :: Number
  , ghost :: Boolean        -- a dangling dep target no source defines
  , source :: String
  , mech :: String
  , depth :: Number         -- 0..1 dependency layer (retained channel for pivots)
  }

-- Edges from the loose deps: (dependent → dependency), with the requirement label.
edgesOf :: Array ServiceInstanceView -> Array Edge
edgesOf = Array.concatMap \i ->
  map (\d -> { from: i.localName, to: d.to, req: d.requirement }) i.deps

-- Traffic edges from the routes: (proxy → backend), with the path.
trafficOf :: Array ServiceInstanceView -> Array Route
trafficOf = Array.concatMap \i ->
  map (\r -> { from: i.localName, to: r.to, path: r.path }) i.routes

-- from → [to], for the longest-dependency-chain layering.
depMapOf :: Array Edge -> Map String (Array String)
depMapOf = foldl step Map.empty
  where
  step m e = Map.insertWith (<>) e.from [ e.to ] m

-- | Longest dependency chain below a node = its layer. A node depending on
-- | nothing is layer 0; depending on a layer-k node is ≥ k+1. Cycles are broken
-- | by the visited set (a back-edge contributes 0), so the graph always lays
-- | out — the cycle stays visible as a back-edge, it just doesn't drive depth.
layerOf :: Map String (Array String) -> String -> Int
layerOf depMap = go Set.empty
  where
  go seen id
    | Set.member id seen = 0
    | otherwise = case Map.lookup id depMap of
        Nothing -> 0
        Just deps ->
          let seen' = Set.insert id seen
          in foldl (\acc d -> max acc (1 + go seen' d)) 0 deps

-- ── build the laid-out node set ──────────────────────────────────────────────

-- max rows before a layer wraps into a second sub-column (keeps the dep-less
-- crowd compact rather than one 50-tall column).
maxRows :: Int
maxRows = 12

buildNodes :: Array ServiceInstanceView -> Array Edge -> Array Node
buildNodes insts edges =
  _.nodes (foldl placeLayer { x: marginX, nodes: [] } (Array.range 0 maxLayer))
  where
  realIds = Array.nub (map _.localName insts)
  depTargets = Array.nub (map _.to edges)
  ghostIds = Array.filter (\t -> not (Array.elem t realIds)) depTargets
  allIds = realIds <> ghostIds

  depMap = depMapOf edges
  layerMap = Map.fromFoldable (map (\id -> id /\ layerOf depMap id) allIds)
  layerOfId id = fromMaybe 0 (Map.lookup id layerMap)

  maxLayer = fromMaybe 0 (maximum (map layerOfId allIds))
  colW = nodeW + 40.0

  -- thread an x-cursor left→right so wider (wrapped) layers push later ones over
  placeLayer acc l =
    let
      ids = Array.sort (Array.filter (\id -> layerOfId id == l) allIds)
      n = Array.length ids
      subcols = max 1 ((n + maxRows - 1) / maxRows)
      mk idx id =
        let meta = Array.find (\i -> i.localName == id) insts
        in { id
           , x: acc.x + toNumber (idx / maxRows) * colW
           , y: marginY + toNumber (idx `mod` maxRows) * rowGap
           , ghost: maybe true (const false) meta
           , source: maybe "" _.source meta
           , mech: maybe "" _.executor.mechanism meta
           , depth: toNumber l / toNumber (max 1 maxLayer)
           }
    in
      { x: acc.x + toNumber subcols * colW + 40.0
      , nodes: acc.nodes <> Array.mapWithIndex mk ids
      }

-- ── colours ──────────────────────────────────────────────────────────────────

-- border hue by source (§2.9 provenance)
srcColor :: String -> SA.Color
srcColor = case _ of
  "compose" -> SA.RGB 37 99 235     -- blue
  "registry" -> SA.RGB 16 140 110   -- teal
  "plist" -> SA.RGB 130 100 190     -- violet
  "systemd" -> SA.RGB 200 110 0     -- amber
  "k8s" -> SA.RGB 70 80 180         -- indigo
  "overlay" -> SA.RGB 120 120 120   -- grey
  _ -> SA.RGB 170 170 170

ink :: SA.Color
ink = SA.RGB 26 26 26

faint :: SA.Color
faint = SA.RGB 150 150 150

paper :: SA.Color
paper = SA.RGB 255 255 255

edgeColor :: SA.Color
edgeColor = SA.RGB 150 150 150

-- traffic channel — a calm, non-source hue (the source palette owns blue/green/
-- violet/amber/indigo/grey). Provisional pending the holistic attention pass.
traffic :: SA.Color
traffic = SA.RGB 90 150 165

-- node fill = dependency depth, a calm light sequential ramp (lighter = starts
-- earlier). A RETAINED channel (Andrew, 2026-06-15): it survives a layout pivot
-- to force/etc. where left→right no longer encodes boot order, so depth stays
-- legible across views — continuity without animation.
layerRamp :: Number -> SA.Color
layerRamp f =
  let lerp hi lo = round (hi - f * (hi - lo))
  in SA.RGB (lerp 248.0 206.0) (lerp 250.0 216.0) (lerp 252.0 230.0)

-- ── the view ─────────────────────────────────────────────────────────────────

graphView :: forall act m. AnalyzeResult -> H.ComponentHTML act () m
graphView a =
  let
    insts = a.instances
    edges = edgesOf insts
    routes = trafficOf insts
    nodes = buildNodes insts edges
    posOf id = Array.find (\n -> n.id == id) nodes
    maxX = fromMaybe 0.0 (maximum (map _.x nodes)) + nodeW + marginX
    maxY = fromMaybe 0.0 (maximum (map _.y nodes)) + nodeH + marginY
  in
    HH.div [ cls "graph" ]
      [ HH.div [ cls "graph-meta" ]
          [ HH.span [ cls "muted" ]
              [ HH.text (show (Array.length nodes) <> " nodes · "
                  <> show (Array.length edges) <> " deps · "
                  <> show (Array.length routes) <> " routes · loose view (left → right = boot order)") ]
          ]
      , SE.svg
          [ SA.viewBox 0.0 0.0 maxX maxY, SA.class_ (H.ClassName "graph-svg") ]
          [ axisLayer maxX
          , SE.g [ SA.class_ (H.ClassName "traffic") ]
              (Array.mapMaybe (trafficLine posOf) routes)
          , SE.g [ SA.class_ (H.ClassName "edges") ]
              (Array.mapMaybe (edgeLine posOf) edges)
          , SE.g [ SA.class_ (H.ClassName "nodes") ]
              (map nodeMark nodes)
          ]
      , legend
      ]

-- one dependency edge: a line (dependent → dependency) + the midpoint mark.
edgeLine
  :: forall act m
   . (String -> Maybe Node)
  -> Edge
  -> Maybe (H.ComponentHTML act () m)
edgeLine posOf e = do
  from <- posOf e.from
  to <- posOf e.to
  let
    fx = from.x + nodeW / 2.0
    fy = from.y + nodeH / 2.0
    tx = to.x + nodeW / 2.0
    ty = to.y + nodeH / 2.0
    mx = (fx + tx) / 2.0
    my = (fy + ty) / 2.0
  pure $ SE.g [ SA.class_ (H.ClassName "edge") ]
    ( [ SE.line
          [ SA.x1 fx, SA.y1 fy, SA.x2 tx, SA.y2 ty
          , SA.stroke edgeColor, SA.strokeWidth 1.2
          ]
      ] <> midpointMark mx my e.req
    )

-- the labelled dependency axis (§ pivot-table): when the layout IS the boot
-- order, left→right carries meaning, so name it — "depended on by →". (Under a
-- force pivot this is dropped and direction moves onto the edges as arrowheads.)
axisLayer :: forall act m. Number -> H.ComponentHTML act () m
axisLayer maxX =
  let xr = maxX - marginX
  in SE.g [ SA.class_ (H.ClassName "axis") ]
    [ SE.line [ SA.x1 marginX, SA.y1 26.0, SA.x2 xr, SA.y2 26.0, SA.stroke faint, SA.strokeWidth 1.0 ]
    , SE.line [ SA.x1 (xr - 9.0), SA.y1 22.0, SA.x2 xr, SA.y2 26.0, SA.stroke faint, SA.strokeWidth 1.0 ]
    , SE.line [ SA.x1 (xr - 9.0), SA.y1 30.0, SA.x2 xr, SA.y2 26.0, SA.stroke faint, SA.strokeWidth 1.0 ]
    , SE.text
        [ SA.x marginX, SA.y 18.0, SA.fontSize (SA.FontSizeLength (SA.Px 10.5)), SA.fill faint ]
        [ HH.text "depended on by" ]
    ]

-- one traffic edge: a dashed line (proxy → backend, nudged off the lifecycle
-- line it usually coincides with) + the route path. Calm/provisional styling.
trafficLine
  :: forall act m
   . (String -> Maybe Node)
  -> Route
  -> Maybe (H.ComponentHTML act () m)
trafficLine posOf rt = do
  from <- posOf rt.from
  to <- posOf rt.to
  let
    fx = from.x + nodeW / 2.0
    fy = from.y + nodeH / 2.0 + 7.0     -- nudge below the coinciding dep edge
    tx = to.x + nodeW / 2.0
    ty = to.y + nodeH / 2.0 + 7.0
    mx = (fx + tx) / 2.0
    my = (fy + ty) / 2.0
  pure $ SE.g [ SA.class_ (H.ClassName "route") ]
    [ SE.line
        [ SA.x1 fx, SA.y1 fy, SA.x2 tx, SA.y2 ty
        , SA.stroke traffic, SA.strokeWidth 1.3, SA.strokeDashArray "6 4"
        ]
    , SE.text
        [ SA.x mx, SA.y (my - 4.0), SA.textAnchor SA.AnchorMiddle
        , SA.fontSize (SA.FontSizeLength (SA.Px 9.0)), SA.fill traffic
        ]
        [ HH.text rt.path ]
    ]

-- §4.3 — a single mark at the midpoint encoding the requirement gradient.
-- fill = strength (open → bold → solid); count = coupling (one → two circles).
midpointMark :: forall act m. Number -> Number -> Maybe String -> Array (H.ComponentHTML act () m)
-- MONOCHROME by design: fill/weight = strength, count = coupling. Colour is the
-- *source* channel (node borders) — the mark must never borrow it (the §4.3
-- "one channel per phenomenon" rule; an earlier pale-blue `requires` fill
-- collided with compose=blue and read as provenance).
midpointMark mx my = case _ of
  Nothing -> [ dot mx my 2.0 faint faint 0.0 ]                 -- unspecified: faint pip
  Just r
    | r == "wants" -> [ dot mx my 5.0 paper faint 1.3 ]        -- ○ thin grey open (soft)
    | take 8 r == "requires" -> [ dot mx my 5.5 paper ink 2.8 ] -- ◎ bold black ring (hard, waits)
    | r == "requisite" -> [ dot mx my 5.0 ink ink 1.0 ]        -- ● solid (must pre-exist)
    | r == "binds-to" -> [ dot (mx - 5.5) my 4.5 paper ink 1.9, dot (mx + 5.5) my 4.5 paper ink 1.9 ] -- ○○ coupled, soft
    | r == "part-of" -> [ dot (mx - 5.5) my 4.5 ink ink 1.0, dot (mx + 5.5) my 4.5 ink ink 1.0 ]       -- ●● coupled, hard
    | otherwise -> [ dot mx my 5.0 paper faint 1.3 ]
  where
  dot x y rad fill strk sw =
    SE.circle [ SA.cx x, SA.cy y, SA.r rad, SA.fill fill, SA.stroke strk, SA.strokeWidth sw ]

-- one node: a rounded rect bordered by source, label + mechanism tag.
-- ghosts (dangling targets) render hollow + faint.
nodeMark :: forall act m. Node -> H.ComponentHTML act () m
nodeMark n =
  SE.g [ SA.class_ (H.ClassName (if n.ghost then "node ghost" else "node")) ]
    [ SE.rect
        [ SA.x n.x, SA.y n.y, SA.width nodeW, SA.height nodeH, SA.rx 5.0
        , SA.fill (if n.ghost then paper else layerRamp n.depth)
        , SA.fillOpacity (if n.ghost then 0.4 else 1.0)
        , SA.stroke (if n.ghost then faint else srcColor n.source)
        , SA.strokeWidth (if n.ghost then 1.0 else 1.8)
        ]
    , SE.text
        [ SA.x (n.x + 10.0), SA.y (n.y + 18.0)
        , SA.fontSize (SA.FontSizeLength (SA.Px 12.5)), SA.fill ink
        ]
        [ HH.text (clip 18 n.id) ]
    , SE.text
        [ SA.x (n.x + 10.0), SA.y (n.y + 33.0)
        , SA.fontSize (SA.FontSizeLength (SA.Px 9.5)), SA.fill faint
        ]
        [ HH.text (if n.ghost then "undefined — no source" else (n.mech <> " · " <> n.source)) ]
    ]

clip :: Int -> String -> String
clip n s = if length s > n then take (n - 1) s <> "…" else s

-- a small HTML legend so the marks are readable without prior knowledge.
legend :: forall act m. H.ComponentHTML act () m
legend =
  HH.div [ cls "graph-legend" ]
    [ HH.div [ cls "leg-grp" ]
        [ HH.span [ cls "leg-h" ] [ HH.text "edge midpoint (requirement)" ]
        , leg "○" "wants (soft)"
        , leg "◉" "requires (hard, waits)"
        , leg "●" "requisite (must pre-exist)"
        , leg "○○" "binds-to (crash-coupled)"
        , leg "●●" "part-of (reverse lifecycle)"
        ]
    , HH.div [ cls "leg-grp" ]
        [ HH.span [ cls "leg-h" ] [ HH.text "node border (source)" ]
        , leg "▮" "compose / registry / plist / systemd / overlay"
        , leg "▒" "fill = boot depth (lighter starts earlier)"
        , leg "▢" "ghost = dangling dependency"
        ]
    , HH.div [ cls "leg-grp" ]
        [ HH.span [ cls "leg-h" ] [ HH.text "edges" ]
        , leg "──" "dependency (lifecycle)"
        , leg "╌╌" "route (traffic, labelled /path)"
        ]
    ]
  where
  leg sym txt =
    HH.span [ cls "leg" ]
      [ HH.span [ cls "leg-sym" ] [ HH.text sym ], HH.text txt ]

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls c = HP.class_ (HH.ClassName c)
