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
module Chair.Graph (graphView, layoutPositions, GroupMode(..), NodeLive(..), Channel(..), allChannels, nextMode, modeLabel) where

import Prelude

import Bosun.View (AddressView, AnalyzeResult, ServiceInstanceView)
import DataViz.Layout.Hierarchy.Pack (HierarchyData(..), PackNode(..), defaultPackConfig, hierarchy, pack)
import Data.Graph.Algorithms (SimpleGraph)
import Data.Graph.Decomposition (articulationPoints, bridges)
import Hylograph.Transition.Interpolate (Point)
import Data.Array as Array
import Data.Foldable (foldl, maximum, minimum)
import Data.Int (round, toNumber)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith)
import Data.String.CodeUnits (length, take)
import Data.Tuple (Tuple(..))
import Data.Tuple.Nested ((/\))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Svg.Attributes as SA
import Halogen.Svg.Elements as SE

-- ── layout / grouping mode ───────────────────────────────────────────────────

-- the spatial hierarchy the nodes are arranged by (§5 swappable hierarchy). The
-- interpolation engine animates BETWEEN any two of these (positions are just a
-- layoutPositions map per mode), so cycling is a live pivot.
data GroupMode
  = ByDeps   -- loose dependency layers, left→right = boot order
  | ByHost   -- nested placement swimlanes (rectangular bands)
  | ByPack   -- nested circle-packing of the placement tree (no-overlap, any depth)

derive instance Eq GroupMode

nextMode :: GroupMode -> GroupMode
nextMode = case _ of
  ByDeps -> ByHost
  ByHost -> ByPack
  ByPack -> ByDeps

modeLabel :: GroupMode -> String
modeLabel = case _ of
  ByDeps -> "↹ group: deps"
  ByHost -> "↹ group: host"
  ByPack -> "↹ group: pack"

-- ── live runtime status (the dashboard overlay) ──────────────────────────────

-- | A node's status as `bosun serve` reports it via /state, correlated to the
-- | graph node through `reconcile.aliases` (Main owns the mapping). This is a
-- | SEPARATE channel from every structural one — it overlays a status dot and,
-- | for a down node, auto-drives the blast-radius amber over its dependents
-- | (CONTROL-SURFACE.md). `LiveUnknown` is the default and renders NOTHING (the
-- | node isn't serve-managed, e.g. a non-correlated fixture), so the overlay is
-- | self-effacing — modeless, no toggle.
data NodeLive
  = LiveUp        -- serve route, backend running
  | LiveDown      -- serve route, backend stopped → the failure that blasts
  | LiveRedirect  -- a 421 redirect — lives on another host (not proxied here)
  | LiveUnknown   -- not serve-managed → no dot

derive instance Eq NodeLive

-- ── display channels (the small-multiples rack) ──────────────────────────────

-- | Each orthogonal mark the graph can show is its OWN channel. The main view
-- | composites the enabled set; the rack shows each channel alone as a dot-only
-- | (or edge-only) small multiple that doubles as its toggle and its legend.
-- | Default is everything on — a cluttered full view is a legitimate resting
-- | state (Andrew: don't force a view-flip for optical hygiene). The base layer
-- | (neutral cards + labels at their positions) is always drawn; with every
-- | channel off you get bare dots.
data Channel
  = ChSource       -- node border hue = provenance (§2.9)
  | ChDepth        -- node fill = boot depth ramp
  | ChExposure     -- right-edge openness badge
  | ChPlacement    -- failure-domain bands + cross-host edge hue
  | ChRequirement  -- the dependency edges + midpoint requirement marks
  | ChTraffic      -- reverse-proxy route edges
  | ChSpof         -- structural cut-vertex halos + bridge edges
  | ChLive         -- runtime status dots + blast-from-down

derive instance Eq Channel
derive instance Ord Channel

allChannels :: Array Channel
allChannels = [ ChSource, ChDepth, ChExposure, ChPlacement, ChRequirement, ChTraffic, ChSpof, ChLive ]

channelLabel :: Channel -> String
channelLabel = case _ of
  ChSource -> "source"
  ChDepth -> "boot depth"
  ChExposure -> "exposure"
  ChPlacement -> "placement"
  ChRequirement -> "dependency"
  ChTraffic -> "traffic"
  ChSpof -> "SPOF"
  ChLive -> "live status"

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
  , reach :: Array AddressView  -- inbound addresses, for the exposure badge
  , host :: Maybe String    -- finest placement level, for cross-host marking
  , place :: Array String   -- the failure-domain PATH, coarse→fine (nested bands)
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
           , reach: maybe [] _.reachability meta
           , host: meta >>= _.host
           , place: maybe [] _.place meta
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

-- neutral marks: the resting hue when a channel is OFF (a card whose source
-- channel is hidden) and the un-encoded dots in a small multiple.
neutral :: SA.Color
neutral = SA.RGB 205 209 216

neutralBorder :: SA.Color
neutralBorder = SA.RGB 176 182 192

paper :: SA.Color
paper = SA.RGB 255 255 255

edgeColor :: SA.Color
edgeColor = SA.RGB 150 150 150

-- a dependency that crosses machines — the fragile boundary (network latency +
-- partition). Warm so the boundary-crossings pop (§14.6 "mark cross-host edges").
crossHostColor :: SA.Color
crossHostColor = SA.RGB 200 130 40

-- a dependency that crosses hosts but stays on ONE machine — fragile (a process/
-- container boundary) but not a network partition. A paler amber than cross-machine.
crossHostMild :: SA.Color
crossHostMild = SA.RGB 214 184 130

-- the alarm hue for structural SPOFs (§8.7): cut-vertex halos + bridge edges.
-- A clear red, distinct from the amber boundary ramp (which is about distance,
-- not danger) and from every source border hue.
alarm :: SA.Color
alarm = SA.RGB 206 51 51

-- the "would fall" amber for blast radius (§14.5): the killed node is alarm-red,
-- everything that transitively depends on it is washed in this warning amber.
blastColor :: SA.Color
blastColor = SA.RGB 224 146 46

-- traffic channel — a calm, non-source hue (the source palette owns blue/green/
-- violet/amber/indigo/grey). Provisional pending the holistic attention pass.
traffic :: SA.Color
traffic = SA.RGB 90 150 165

-- live-status dot hues (the runtime overlay). Up is a calm confirmatory green
-- (distinct from the teal traffic and the green source border); down REUSES the
-- alarm red (a down service IS the structural emergency); redirect is a cool
-- indigo "lives elsewhere". Unknown never draws.
liveUpColor :: SA.Color
liveUpColor = SA.RGB 56 158 86

liveRedirectColor :: SA.Color
liveRedirectColor = SA.RGB 92 116 196

-- a PUNCHIER version of the depth ramp, for the dot-only small multiple: the
-- main-card ramp (layerRamp) is deliberately pale and vanishes shrunk to a dot
-- on near-white, reading as "empty" and colliding with the genuinely-hollow
-- no-value dots. Same channel, same semantic (lighter = starts earlier), but a
-- saturated light→deep blue so the gradient reads and the dot is clearly filled.
depthThumb :: Number -> SA.Color
depthThumb f =
  let lerp hi lo = round (hi - f * (hi - lo))
  in SA.RGB (lerp 200.0 36.0) (lerp 216.0 78.0) (lerp 240.0 150.0)

-- node fill = dependency depth, a calm light sequential ramp (lighter = starts
-- earlier). A RETAINED channel (Andrew, 2026-06-15): it survives a layout pivot
-- to force/etc. where left→right no longer encodes boot order, so depth stays
-- legible across views — continuity without animation.
layerRamp :: Number -> SA.Color
layerRamp f =
  let lerp hi lo = round (hi - f * (hi - lo))
  in SA.RGB (lerp 248.0 206.0) (lerp 250.0 216.0) (lerp 252.0 230.0)

-- re-cluster the SAME nodes (depth / reach all retained — §4.8) by PLACEMENT:
-- one column per finest-level group (leaf of the failure-domain path), columns
-- ORDERED by the full path so groups sharing a coarse ancestor sit adjacent —
-- which is what lets the nested swimlane bands (§5/§2.1) enclose them. Reduces
-- to one-column-per-host when the path is a single level (back-compat).
buildPlacementNodes :: Array ServiceInstanceView -> Array Edge -> Array Node
buildPlacementNodes insts edges =
  let
    base = buildNodes insts edges
    leafKey n = joinWith "/" n.place
    leaves = Array.sort (Array.nub (map leafKey base))   -- path-sorted → prefix-adjacent
    maxLen = fromMaybe 1 (maximum (map (\n -> Array.length n.place) base))
    y0 = marginY + toNumber (max 0 (maxLen - 1)) * levelHead   -- headroom for stacked band headers
    colW = nodeW + 50.0
  in
    Array.concat $ Array.mapWithIndex
      ( \ci key ->
          Array.mapWithIndex
            (\row n -> n { x = marginX + toNumber ci * colW, y = y0 + toNumber row * rowGap })
            (Array.filter (\n -> leafKey n == key) base)
      )
      leaves

-- per-level vertical headroom reserved above the node area for each band header
levelHead :: Number
levelHead = 24.0

-- ── circle-packing the placement tree (Hylograph DataViz.Layout.Hierarchy.Pack) ─
--
-- The placement path becomes a hierarchy (root → machine → host → service); the
-- pack layout nests it as non-overlapping circles to ARBITRARY depth (what the
-- rectangular swimlanes can't guarantee). Leaf circles carry the service cards;
-- enclosing circles are the placement bands. Scaled so the 150×42 cards clear
-- each other: equal leaves pack tangent at 2·r, so a uniform scale to ≥184px
-- between adjacent centres keeps even diagonal neighbours apart.

type PackCircle = { x :: Number, y :: Number, r :: Number, label :: String, depth :: Int }

cardSpacing :: Number
cardSpacing = 188.0

-- build the placement hierarchy: leaves (children:Nothing) are services, internal
-- nodes (children:Just) are domains. value 1.0 per leaf → area ∝ service count.
mkHier :: String -> Array { path :: Array String, id :: String } -> HierarchyData String
mkHier label items =
  let
    leaves = Array.filter (\it -> Array.null it.path) items
    nested = Array.filter (\it -> not (Array.null it.path)) items
    heads = Array.nub (Array.mapMaybe (\it -> Array.head it.path) nested)
    leafKids = map (\it -> HierarchyData { data_: it.id, value: Just 1.0, children: Nothing }) leaves
    groupKids = map mkGroup heads
    mkGroup h = mkHier h
      (map (\it -> it { path = fromMaybe [] (Array.tail it.path) })
        (Array.filter (\it -> Array.head it.path == Just h) nested))
  in
    HierarchyData { data_: label, value: Nothing, children: Just (leafKids <> groupKids) }

flattenPack :: PackNode String -> Array (PackNode String)
flattenPack pn@(PackNode n) = [ pn ] <> Array.concatMap flattenPack n.children

-- run the pack and project into screen coords (leaf centres → card top-lefts;
-- internal circles → bands). Deterministic in the node set, so layoutPositions
-- and the band layer agree without sharing state.
packLayout :: Array Node -> { centres :: Map String Point, radii :: Map String Number, circles :: Array PackCircle }
packLayout base =
  let
    hd = mkHier "·" (map (\n -> { path: n.place, id: n.id }) base)
    -- padding is in the SAME units as the radii, and leaves have radius
    -- sqrt(value)=1, so this must be a small FRACTION of 1 — else the gaps
    -- dwarf the circles and leaves read as dots inside huge bands.
    PackNode rootN = pack (defaultPackConfig { padding = 0.12 }) (hierarchy hd)
    flat = flattenPack (PackNode rootN)
    leaves = Array.mapMaybe (\(PackNode n) -> if Array.null n.children then Just { id: n.data_, x: n.x, y: n.y, r: n.r } else Nothing) flat
    internals = Array.mapMaybe
      (\(PackNode n) -> if not (Array.null n.children) && n.depth >= 1 then Just { x: n.x, y: n.y, r: n.r, label: n.data_, depth: n.depth } else Nothing)
      flat
    r0 = fromMaybe 1.0 (map _.r (Array.head leaves))
    s = if r0 <= 0.0 then 200.0 else cardSpacing / (2.0 * r0)
    minX = rootN.x - rootN.r
    minY = rootN.y - rootN.r
    tx v = (v - minX) * s + marginX
    ty v = (v - minY) * s + marginY
    -- centres are stored as card top-lefts (so the pivot interpolates the same
    -- convention as the other layouts); the leaf circle is drawn around the card
    -- centre. radii are the scaled pack-circle radii (the node's actual slot).
    centres = Map.fromFoldable (map (\l -> l.id /\ { x: tx l.x - nodeW / 2.0, y: ty l.y - nodeH / 2.0 }) leaves)
    radii = Map.fromFoldable (map (\l -> l.id /\ (l.r * s)) leaves)
    circles = map (\c -> { x: tx c.x, y: ty c.y, r: c.r * s, label: c.label, depth: c.depth }) internals
  in
    { centres, radii, circles }

buildPackNodes :: Array ServiceInstanceView -> Array Edge -> Array Node
buildPackNodes insts edges =
  let
    base = buildNodes insts edges
    centres = (packLayout base).centres
  in
    map (\n -> maybe n (\p -> n { x = p.x, y = p.y }) (Map.lookup n.id centres)) base

-- dispatch the node layout by grouping mode
buildFor :: GroupMode -> Array ServiceInstanceView -> Array Edge -> Array Node
buildFor mode insts edges = case mode of
  ByDeps -> buildNodes insts edges
  ByHost -> buildPlacementNodes insts edges
  ByPack -> buildPackNodes insts edges

-- ── structural SPOF (§8.7) ───────────────────────────────────────────────────

-- the dependency graph as an UNDIRECTED SimpleGraph, for biconnected
-- decomposition. Cut-vertices (articulation points) are nodes whose loss
-- partitions the graph — "everything funnels through this one service with no
-- alternative"; bridges are edges with no redundant path around them. Both are
-- SPOFs read purely from the graph's shape, computed not remembered.
spofGraph :: Array String -> Array Edge -> SimpleGraph String
spofGraph ids edges = { nodes: ids, edges: foldl ins Map.empty edges }
  where
  ins acc e =
    Map.alter (Just <<< Set.insert e.to <<< fromMaybe Set.empty) e.from
      (Map.alter (Just <<< Set.insert e.from <<< fromMaybe Set.empty) e.to acc)

-- normalise an undirected edge so (a,b) and (b,a) hash the same for lookup
normEdge :: String -> String -> Tuple String String
normEdge a b = if a <= b then Tuple a b else Tuple b a

-- ── blast radius (§14.5 "click to ask what breaks") ──────────────────────────

-- everything that TRANSITIVELY DEPENDS ON `start` — i.e. what stops if it dies.
-- Edges run dependent→dependency, so this is reverse reachability: follow
-- to→from. The returned set includes `start` itself (the killed node).
blastRadius :: Array Edge -> String -> Set String
blastRadius edges start = go (Set.singleton start) [ start ]
  where
  revAdj = foldl (\m e -> Map.insertWith (<>) e.to [ e.from ] m) Map.empty edges
  go seen frontier = case Array.uncons frontier of
    Nothing -> seen
    Just { head, tail } ->
      let fresh = Array.filter (\d -> not (Set.member d seen)) (fromMaybe [] (Map.lookup head revAdj))
      in go (foldl (flip Set.insert) seen fresh) (tail <> fresh)

-- ── the view ─────────────────────────────────────────────────────────────────

-- `hoverAct` reports the hovered node id (Nothing on leave); `focus` is the
-- current brush. Brushing DIMS the unconnected rather than hiding it (Andrew:
-- show everything, highlight on interrogation) — the Minard pattern.
-- | The final laid-out positions for a layout (deps layers vs host columns),
-- | keyed by node id. Bosun's Chair animates BETWEEN two of these maps through
-- | the Hylograph interpolation engine (Transition.Engine + Interpolate), so the
-- | pivot is a real per-frame tween, not a CSS transform — which means the edges,
-- | re-rendered each frame from the live positions, follow the nodes.
layoutPositions :: GroupMode -> AnalyzeResult -> Map String Point
layoutPositions mode a =
  let
    insts = a.instances
    edges = edgesOf insts
    nodes = buildFor mode insts edges
  in
    Map.fromFoldable (map (\n -> n.id /\ { x: n.x, y: n.y }) nodes)

graphView :: forall act m. (Maybe String -> act) -> (Maybe String -> act) -> (Channel -> act) -> GroupMode -> Set Channel -> Map String Point -> Maybe String -> Maybe String -> Map String NodeLive -> AnalyzeResult -> H.ComponentHTML act () m
graphView hoverAct selectAct toggleChan mode channels livePos focus select live a =
  let
    chOn ch = Set.member ch channels
    insts = a.instances
    edges = edgesOf insts
    routes = trafficOf insts
    -- structural nodes for the current layout; their x,y are OVERRIDDEN by the
    -- live (interpolating) positions during a pivot, so everything that reads a
    -- node position — edges, swimlane bboxes, the extents — follows the tween.
    builtNodes = buildFor mode insts edges
    nodes = map (\n -> maybe n (\p -> n { x = p.x, y = p.y }) (Map.lookup n.id livePos)) builtNodes
    -- STABLE render order (sort by id) so Halogen reuses each node's <g> across
    -- re-renders rather than tearing down and rebuilding (object constancy, §6.1).
    renderNodes = Array.sortWith _.id nodes
    posOf id = Array.find (\n -> n.id == id) nodes
    -- pack circles (band layer + extents) + per-node leaf radii, only in ByPack
    -- mode; deterministic in the node set, so this matches buildPackNodes' centres.
    packRes = case mode of
      ByPack -> packLayout builtNodes
      _ -> { centres: Map.empty, radii: Map.empty, circles: [] }
    packCirc = packRes.circles
    maxX = max (fromMaybe 0.0 (maximum (map _.x nodes)) + nodeW)
               (fromMaybe 0.0 (maximum (map (\c -> c.x + c.r) packCirc))) + marginX
    maxY = max (fromMaybe 0.0 (maximum (map _.y nodes)) + nodeH)
               (fromMaybe 0.0 (maximum (map (\c -> c.y + c.r) packCirc))) + marginY
    -- the brushed node + its neighbours (via deps and routes) stay lit
    focusSet = focus <#> \fid ->
      Set.fromFoldable
        ( [ fid ]
            <> Array.concatMap (\e -> nbr fid e.from e.to) edges
            <> Array.concatMap (\r -> nbr fid r.from r.to) routes
        )
    -- blast radius (click-to-select): what stops if `select` dies. When a node
    -- is selected this lens DOMINATES the hover brush — dim everything outside
    -- the blast set, the killed node red, its transitive dependents amber.
    blastSet = maybe Set.empty (blastRadius edges) select
    nodeDim n = case select of
      Just _ -> not (Set.member n.id blastSet)
      Nothing -> case focusSet of
        Nothing -> false
        Just s -> not (Set.member n.id s)
    edgeDim from to = case select of
      Just _ -> not (Set.member from blastSet && Set.member to blastSet)
      Nothing -> case focus of
        Nothing -> false
        Just fid -> not (from == fid || to == fid)
    -- structural SPOFs, computed from the dependency graph's shape (§8.7).
    -- Computed UNCONDITIONALLY (the rack thumbnail always previews them); the
    -- MAIN view gates them by the ChSpof channel.
    spofG = spofGraph (map _.id nodes) edges
    showSpof = chOn ChSpof
    cutVertsAll = articulationPoints spofG
    bridgeSetAll = Set.fromFoldable (map (\(Tuple x y) -> normEdge x y) (bridges spofG))
    cutVerts = if showSpof then cutVertsAll else Set.empty
    bridgeSet = if showSpof then bridgeSetAll else Set.empty
    isBridge from to = Set.member (normEdge from to) bridgeSet
    -- live overlay: which nodes serve reports DOWN, and the auto-blast over their
    -- transitive dependents (§14.5 driven by reality, not a click). The MAIN view
    -- gates by ChLive (so liveOf reads Unknown when off); the rack uses the raw
    -- `live` map so its thumbnail always previews.
    liveOf id = if chOn ChLive then fromMaybe LiveUnknown (Map.lookup id live) else LiveUnknown
    downIds = Array.filter (\n -> liveOf n.id == LiveDown) nodes
    liveBlast = foldl (\acc n -> Set.union acc (blastRadius edges n.id)) Set.empty downIds
    hasLive = Array.any (\n -> liveOf n.id /= LiveUnknown) nodes
    liveUpN = Array.length (Array.filter (\n -> liveOf n.id == LiveUp) nodes)
    nodeFlags n =
      { dim: nodeDim n
      , cutVertex: Set.member n.id cutVerts
      , killed: select == Just n.id
      , willFall: select /= Just n.id && Set.member n.id blastSet
      , circleR: Map.lookup n.id packRes.radii   -- Just r in pack mode → render as a circle
      , live: liveOf n.id
      , liveWillFall: liveOf n.id /= LiveDown && Set.member n.id liveBlast
      }
    -- the SVG layers, each gated by its channel. The ByDeps axis is BASE (it
    -- names the boot-order direction, not placement). Placement bands, traffic
    -- routes and the dependency edges each switch off with their channel — with
    -- everything off you're left with the neutral cards (bare dots).
    bgLayer = case mode of
      ByDeps -> [ axisLayer maxX ]
      ByHost -> if chOn ChPlacement then [ swimlaneLayer nodes ] else []
      ByPack -> if chOn ChPlacement then [ circleLayer packCirc ] else []
    trafficLayer =
      if chOn ChTraffic
        then [ SE.g [ SA.class_ (H.ClassName "traffic") ]
                 (Array.mapMaybe (\r -> trafficLine (edgeDim r.from r.to) posOf r) routes) ]
        else []
    edgeLayer =
      if chOn ChRequirement
        then [ SE.g [ SA.class_ (H.ClassName "edges") ]
                 (Array.mapMaybe (\e -> edgeLine (edgeDim e.from e.to) (isBridge e.from e.to) (chOn ChPlacement) posOf e) edges) ]
        else []
  in
    HH.div [ cls "graph" ]
      [ HH.div [ cls "graph-meta" ]
          [ HH.span [ cls "muted" ]
              [ HH.text (show (Array.length nodes) <> " nodes · "
                  <> show (Array.length edges) <> " deps · "
                  <> show (Array.length routes) <> " routes · "
                  <> (case mode of
                        ByDeps -> "loose view (left → right = boot order)"
                        ByHost -> "grouped by host"
                        ByPack -> "packed by placement")
                  <> (if showSpof then " · ⚠ " <> show (Set.size cutVerts) <> " cut-vertices · " <> show (Set.size bridgeSet) <> " bridges" else "")
                  <> (if hasLive then " · ◉ live: " <> show liveUpN <> " up · " <> show (Array.length downIds) <> " down" else "")) ]
          ]
      , SE.svg
          [ SA.viewBox 0.0 0.0 maxX maxY, SA.width maxX, SA.height maxY
          , SA.class_ (H.ClassName "graph-svg")
          ]
          ( bgLayer <> trafficLayer <> edgeLayer <>
          [ SE.g [ SA.class_ (H.ClassName "nodes") ]
              (map (\n -> nodeMark hoverAct selectAct channels (nodeFlags n) n) renderNodes)
          ] )
      , channelRack toggleChan channels maxX maxY nodes edges routes cutVertsAll bridgeSetAll live
      ]

-- append the dim marker class when brushing has pushed this element to the back
dimClass :: String -> Boolean -> String
dimClass base d = if d then base <> " dim" else base

-- neighbours of `f` across one edge's endpoints
nbr :: String -> String -> String -> Array String
nbr f x y = if x == f then [ y ] else if y == f then [ x ] else []

-- one dependency edge: a line (dependent → dependency) + the midpoint mark.
-- `bridge` (SPOF mode on) overrides the boundary hue with alarm-red: this edge
-- is a single link with no redundant path around it (§8.7).
edgeLine
  :: forall act m
   . Boolean
  -> Boolean
  -> Boolean
  -> (String -> Maybe Node)
  -> Edge
  -> Maybe (H.ComponentHTML act () m)
edgeLine dim bridge showPlace posOf e = do
  from <- posOf e.from
  to <- posOf e.to
  let
    fx = from.x + nodeW / 2.0
    fy = from.y + nodeH / 2.0
    tx = to.x + nodeW / 2.0
    ty = to.y + nodeH / 2.0
    mx = (fx + tx) / 2.0
    my = (fy + ty) / 2.0
    -- fragility by how COARSELY the endpoints diverge in placement: same leaf →
    -- local (grey); diverge only deep (same machine, different host) → mild;
    -- diverge at the top (different machine/region) → the fragile network
    -- boundary (strong amber). §14.6 generalised from flat cross-host to the path.
    -- The cross-host hue belongs to the PLACEMENT channel — neutral when it's off.
    shared = sharedPrefixLen from.place to.place
    diverges = showPlace && from.place /= to.place && not (Array.null from.place) && not (Array.null to.place)
    boundaryColor
      | not diverges = edgeColor
      | shared == 0 = crossHostColor       -- different machine — most fragile
      | otherwise = crossHostMild          -- same machine, different host
  pure $ SE.g [ SA.class_ (H.ClassName (dimClass "edge" dim)) ]
    ( [ SE.line
          [ SA.x1 fx, SA.y1 fy, SA.x2 tx, SA.y2 ty
          , SA.stroke (if bridge then alarm else boundaryColor)
          , SA.strokeWidth (if bridge then 2.2 else if diverges then 1.7 else 1.2)
          ]
      ] <> midpointMark mx my e.req
    )

-- length of the shared coarse→fine prefix of two placement paths
sharedPrefixLen :: Array String -> Array String -> Int
sharedPrefixLen a b = go 0
  where
  go i = case Array.index a i, Array.index b i of
    Just x, Just y | x == y -> go (i + 1)
    _, _ -> i

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

-- NESTED placement bands (§2.1/§5): one band per distinct prefix of the
-- failure-domain path, at every level. Coarse bands (machines) enclose finer
-- bands (hosts) — which is why co-location is *visible*: two hosts on one
-- machine sit inside the same outer band, so a primary/mirror that share a
-- machine read as the SPOF they are before any analysis runs. Drawn behind
-- everything, bboxes read off live node positions, faded in via CSS keyframe.
-- Coarser bands get more padding (so they frame the inner ones) and are tinted
-- by their level-0 ancestor (a machine + its hosts share a hue family). A
-- single-level path reduces this to the flat one-band-per-host swimlane.
swimlaneLayer :: forall act m. Array Node -> H.ComponentHTML act () m
swimlaneLayer nodes =
  SE.g [ SA.class_ (H.ClassName "swimlanes") ]
    (Array.concatMap bandsAtLevel (Array.range 0 (maxLen - 1)))
  where
  maxLen = fromMaybe 1 (maximum (map (\n -> Array.length n.place) nodes))
  machines = Array.sort (Array.nub (Array.mapMaybe (\n -> Array.head n.place) nodes))
  basePad = 11.0
  levelGap = 18.0   -- extra padding per coarser level → visible nesting frame
  headH = 17.0

  bandsAtLevel d =
    let
      relevant = Array.filter (\n -> Array.length n.place > d) nodes
      prefixes = Array.nub (map (\n -> Array.take (d + 1) n.place) relevant)
    in
      Array.mapMaybe (band d) prefixes

  band d prefix = do
    let ns = Array.filter (\n -> Array.take (d + 1) n.place == prefix) nodes
    label <- Array.last prefix
    let
      machineIx = fromMaybe 0 (Array.head prefix >>= \m -> Array.elemIndex m machines)
      st = hostStyle machineIx
      outer = d == 0
      pad = basePad + toNumber (maxLen - 1 - d) * levelGap
      minX = fromMaybe 0.0 (minimum (map _.x ns)) - pad
      maxX = fromMaybe 0.0 (maximum (map _.x ns)) + nodeW + pad
      minY = fromMaybe 0.0 (minimum (map _.y ns)) - pad - headH
      maxY = fromMaybe 0.0 (maximum (map _.y ns)) + nodeH + pad
    pure $ SE.g [ SA.class_ (H.ClassName "swimlane") ]
      [ SE.rect
          [ SA.x minX, SA.y minY, SA.width (maxX - minX), SA.height (maxY - minY)
          , SA.rx 8.0, SA.fill st.tint, SA.fillOpacity (if outer then 0.45 else 0.0)
          , SA.stroke st.ink, SA.strokeWidth (if outer then 1.2 else 1.0)
          ]
      , SE.text
          [ SA.x (minX + 12.0), SA.y (minY + 13.0)
          , SA.fontSize (SA.FontSizeLength (SA.Px (if outer then 11.0 else 10.0)))
          , SA.fill st.ink, SA.fillOpacity (if outer then 1.0 else 0.75)
          ]
          [ HH.text label ]
      ]

-- the circle-packing band layer: nested placement circles (machine ⊃ host ⊃ …).
-- Outermost machine circles are tinted (by index) and filled faintly; deeper
-- circles are stroke-only so the machine tint shows through. Label sits at the
-- top of each circle. Fades in via the same keyframe as the swimlanes.
circleLayer :: forall act m. Array PackCircle -> H.ComponentHTML act () m
circleLayer circles =
  SE.g [ SA.class_ (H.ClassName "swimlanes") ] (map circ circles)
  where
  machines = Array.sort (Array.nub (map _.label (Array.filter (\c -> c.depth == 1) circles)))
  circ c =
    let
      outer = c.depth == 1
      st = if outer then hostStyle (fromMaybe 0 (Array.elemIndex c.label machines))
           else { tint: paper, ink: faint }
    in
      SE.g [ SA.class_ (H.ClassName "swimlane") ]
        [ SE.circle
            [ SA.cx c.x, SA.cy c.y, SA.r c.r
            , SA.fill st.tint, SA.fillOpacity (if outer then 0.4 else 0.0)
            , SA.stroke st.ink, SA.strokeWidth (if outer then 1.2 else 1.0)
            ]
        , SE.text
            [ SA.x c.x, SA.y (c.y - c.r + 13.0), SA.textAnchor SA.AnchorMiddle
            , SA.fontSize (SA.FontSizeLength (SA.Px (if outer then 11.0 else 10.0)))
            , SA.fill st.ink, SA.fillOpacity (if outer then 1.0 else 0.75)
            ]
            [ HH.text c.label ]
        ]

-- pale per-host tints (restrained, Swiss) with a matching darker ink for the
-- header. Distinct hues so adjacent lanes separate; light enough that the node
-- fills (depth ramp) still read on top. Cycles if there are more hosts than hues.
hostStyle :: Int -> { tint :: SA.Color, ink :: SA.Color }
hostStyle hi =
  fromMaybe { tint: SA.RGB 240 240 240, ink: faint }
    (Array.index hostPalette (hi `mod` max 1 (Array.length hostPalette)))

hostPalette :: Array { tint :: SA.Color, ink :: SA.Color }
hostPalette =
  [ { tint: SA.RGB 232 240 250, ink: SA.RGB 88 118 158 }   -- blue
  , { tint: SA.RGB 233 246 238, ink: SA.RGB 78 138 108 }   -- green
  , { tint: SA.RGB 250 244 230, ink: SA.RGB 162 128 68 }   -- amber
  , { tint: SA.RGB 244 238 250, ink: SA.RGB 128 98 162 }   -- violet
  , { tint: SA.RGB 232 246 246, ink: SA.RGB 68 138 138 }   -- teal
  , { tint: SA.RGB 250 238 240, ink: SA.RGB 162 92 108 }   -- rose
  ]

-- one traffic edge: a dashed line (proxy → backend, nudged off the lifecycle
-- line it usually coincides with) + the route path. Calm/provisional styling.
trafficLine
  :: forall act m
   . Boolean
  -> (String -> Maybe Node)
  -> Route
  -> Maybe (H.ComponentHTML act () m)
trafficLine dim posOf rt = do
  from <- posOf rt.from
  to <- posOf rt.to
  let
    fx = from.x + nodeW / 2.0
    fy = from.y + nodeH / 2.0 + 7.0     -- nudge below the coinciding dep edge
    tx = to.x + nodeW / 2.0
    ty = to.y + nodeH / 2.0 + 7.0
    mx = (fx + tx) / 2.0
    my = (fy + ty) / 2.0
  pure $ SE.g [ SA.class_ (H.ClassName (dimClass "route" dim)) ]
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
-- render flags for one node, computed in graphView (which lens is active).
type NodeFlags =
  { dim :: Boolean          -- pushed back by a brush / blast lens
  , cutVertex :: Boolean    -- structural SPOF (§8.7)
  , killed :: Boolean       -- the blast-radius selection (§14.5)
  , willFall :: Boolean     -- transitively depends on the killed node
  , circleR :: Maybe Number -- Just r ⇒ pack mode: render the node AS a circle of radius r
  , live :: NodeLive        -- runtime status from serve /state (the overlay dot)
  , liveWillFall :: Boolean -- transitively depends on a node serve reports DOWN
  }

nodeMark :: forall act m. (Maybe String -> act) -> (Maybe String -> act) -> Set Channel -> NodeFlags -> Node -> H.ComponentHTML act () m
nodeMark hoverAct selectAct channels flags n =
  -- positioned by a `translate` on the group, children at LOCAL 0,0 — so a layout
  -- pivot changes only this transform and the browser CSS-tweens the move
  -- (§6.1 object constancy). The reordering in graphView keeps Halogen reusing
  -- this <g> across pivots, which is what lets the transition fire.
  SE.g
    [ SA.class_ (H.ClassName (dimClass (if n.ghost then "node ghost" else "node") flags.dim))
    , SA.transform [ SA.Translate n.x n.y ]
    , HE.onMouseEnter \_ -> hoverAct (Just n.id)
    , HE.onMouseLeave \_ -> hoverAct Nothing
    , HE.onClick \_ -> selectAct (Just n.id)
    ]
    ( halos <> body <> liveDot )
  where
  chOn ch = Set.member ch channels
  -- the card's fill is the depth ramp (ChDepth) and its border is the source hue
  -- (ChSource); each falls back to a neutral when its channel is off.
  cardFill = if n.ghost then paper else if chOn ChDepth then layerRamp n.depth else paper
  cardStroke = if n.ghost then faint else if chOn ChSource then srcColor n.source else neutralBorder
  -- in pack mode the node IS its pack circle (centred on the card-box centre);
  -- elsewhere it's the 150×42 card. Same source/depth/exposure channels apply.
  body = case flags.circleR of
    Just r -> circleBody r
    Nothing -> cardBody

  -- the runtime status dot (serve /state), top-left so it never collides with the
  -- right-edge exposure badge. Unknown draws nothing → the overlay is invisible on
  -- non-correlated fixtures. On top of the body so it reads over the fill.
  liveDot = case flags.live of
    LiveUnknown -> []
    st ->
      let
        Tuple dx dy = case flags.circleR of
          Just r -> let cr = max 6.0 (r - 4.0) in Tuple (nodeW / 2.0 - 0.66 * cr) (nodeH / 2.0 - 0.66 * cr)
          Nothing -> Tuple 8.5 8.5
      in
        [ SE.circle
            [ SA.cx dx, SA.cy dy, SA.r 5.0
            , SA.fill (liveColor st), SA.stroke paper, SA.strokeWidth 1.6
            , SA.class_ (H.ClassName (if st == LiveDown then "live-dot down" else "live-dot"))
            ]
        ]

  cardBody =
    [ SE.rect
        [ SA.x 0.0, SA.y 0.0, SA.width nodeW, SA.height nodeH, SA.rx 5.0
        , SA.fill cardFill
        , SA.fillOpacity (if n.ghost then 0.4 else 1.0)
        , SA.stroke cardStroke
        , SA.strokeWidth (if n.ghost then 1.0 else 1.8)
        ]
    , SE.text
        [ SA.x 10.0, SA.y 18.0
        , SA.fontSize (SA.FontSizeLength (SA.Px 12.5)), SA.fill ink
        ]
        [ HH.text (clip 18 n.id) ]
    , SE.text
        [ SA.x 10.0, SA.y 33.0
        , SA.fontSize (SA.FontSizeLength (SA.Px 9.5)), SA.fill faint
        ]
        [ HH.text (if n.ghost then "undefined — no source" else (n.mech <> maybe "" (\h -> " · " <> h) n.host)) ]
    ] <> (if chOn ChExposure then exposureBadge n else [])

  -- a leaf circle filling its pack slot (drawn a touch inside r for a gap),
  -- centred on the card-box centre so the position tween is unchanged.
  circleBody r =
    let cr = max 6.0 (r - 4.0)
    in
      [ SE.circle
          [ SA.cx (nodeW / 2.0), SA.cy (nodeH / 2.0), SA.r cr
          , SA.fill cardFill
          , SA.fillOpacity (if n.ghost then 0.4 else 1.0)
          , SA.stroke cardStroke
          , SA.strokeWidth (if n.ghost then 1.0 else 1.8)
          ]
      , SE.text
          [ SA.x (nodeW / 2.0), SA.y (nodeH / 2.0 + 4.0), SA.textAnchor SA.AnchorMiddle
          , SA.fontSize (SA.FontSizeLength (SA.Px 12.0)), SA.fill ink
          ]
          [ HH.text (clip (max 4 (round (cr / 4.0))) n.id) ]
      ]

  -- halos drawn behind the node, biggest first. cut-vertex (structural SPOF) +
  -- killed (alarm-red) + will-fall (blast amber) stack as nested rings; circular
  -- in pack mode, rounded-rect otherwise.
  halos =
    (if flags.killed then [ haloRing flags.circleR alarm 6.5 ] else [])
      <> (if flags.willFall then [ haloRing flags.circleR blastColor 6.5 ] else [])
      -- live fallout (serve says a dependency is down) — same amber as the
      -- interactive blast, a touch tighter so the two read as one phenomenon.
      <> (if flags.liveWillFall then [ haloRing flags.circleR blastColor 5.0 ] else [])
      -- a node serve reports DOWN: a pulsing alarm ring (the CSS class animates it)
      <> (if flags.live == LiveDown then [ liveDownHalo flags.circleR ] else [])
      <> (if flags.cutVertex then [ haloRing flags.circleR alarm 3.5 ] else [])

-- the live-status dot hue (down reuses the structural alarm red — a down service
-- IS the emergency the SPOF lens warns about).
liveColor :: NodeLive -> SA.Color
liveColor = case _ of
  LiveUp -> liveUpColor
  LiveDown -> alarm
  LiveRedirect -> liveRedirectColor
  LiveUnknown -> faint

-- the pulsing alarm ring around a node serve reports DOWN. Like haloRing but a
-- touch heavier and tagged `live-down-halo` so the stylesheet animates it — a
-- real outage draws the eye without an interaction.
liveDownHalo :: forall act m. Maybe Number -> H.ComponentHTML act () m
liveDownHalo circleR = case circleR of
  Just r ->
    SE.circle
      [ SA.cx (nodeW / 2.0), SA.cy (nodeH / 2.0), SA.r (max 6.0 (r - 4.0) + 8.0)
      , SA.fill paper, SA.fillOpacity 0.0, SA.stroke alarm, SA.strokeWidth 2.8
      , SA.class_ (H.ClassName "live-down-halo")
      ]
  Nothing ->
    SE.rect
      [ SA.x (-8.0), SA.y (-8.0)
      , SA.width (nodeW + 16.0), SA.height (nodeH + 16.0), SA.rx 13.0
      , SA.fill paper, SA.fillOpacity 0.0, SA.stroke alarm, SA.strokeWidth 2.8
      , SA.class_ (H.ClassName "live-down-halo")
      ]

-- an alarm/warning ring just outside the node, drawn behind it (a SPOF halo or
-- a blast-radius wash). `off` is how far the ring sits outside the node edge.
-- A circle in pack mode (Just r), a rounded-rect otherwise.
haloRing :: forall act m. Maybe Number -> SA.Color -> Number -> H.ComponentHTML act () m
haloRing circleR c off = case circleR of
  Just r ->
    SE.circle
      [ SA.cx (nodeW / 2.0), SA.cy (nodeH / 2.0), SA.r (max 6.0 (r - 4.0) + off)
      , SA.fill paper, SA.fillOpacity 0.0, SA.stroke c, SA.strokeWidth 2.4
      , SA.class_ (H.ClassName "spof-halo")
      ]
  Nothing ->
    SE.rect
      [ SA.x (negate off), SA.y (negate off)
      , SA.width (nodeW + 2.0 * off), SA.height (nodeH + 2.0 * off), SA.rx (5.0 + off)
      , SA.fill paper, SA.fillOpacity 0.0, SA.stroke c, SA.strokeWidth 2.4
      , SA.class_ (H.ClassName "spof-halo")
      ]

-- the collapsed EXPOSURE BADGE (the Siglet's smallest form): on the node's
-- outward-facing (right) edge, an openness-coloured dot + the address value.
-- Prominence-by-exposure — wide/internet warm and eye-catching, workers silent.
-- (Composition collapses to the loudest member; full glob on interrogation later.)
exposureBadge :: forall act m. Node -> Array (H.ComponentHTML act () m)
exposureBadge n = case mostExposedView n.reach of
  Nothing -> []
  Just a ->
    let
      c = opennessColor a.openness
      cx = nodeW - 11.0     -- LOCAL coords: drawn inside the node's translate group
      cy = 30.0
    in
      [ SE.circle [ SA.cx cx, SA.cy cy, SA.r 4.0, SA.fill c, SA.fillOpacity 0.85, SA.stroke c, SA.strokeWidth 1.0 ]
      , SE.text
          [ SA.x (cx - 9.0), SA.y (cy + 3.5), SA.textAnchor SA.AnchorEnd
          , SA.fontSize (SA.FontSizeLength (SA.Px 9.5)), SA.fill c
          ]
          [ HH.text (clip 14 (addrValue a)) ]
      ]

-- pick the most-exposed address (the loudest member of a composite)
mostExposedView :: Array AddressView -> Maybe AddressView
mostExposedView = foldl pick Nothing
  where
  pick acc a = case acc of
    Nothing -> Just a
    Just b -> if opennessRank a.openness > opennessRank b.openness then Just a else acc

opennessRank :: String -> Int
opennessRank = case _ of
  "internet" -> 5
  "wide" -> 4
  "host" -> 3
  "cluster" -> 2
  "local" -> 1
  _ -> 0

-- warm = wide-open surface (earns the eye), cool = sealed; non-source hues
opennessColor :: String -> SA.Color
opennessColor = case _ of
  "internet" -> SA.RGB 188 70 45
  "wide" -> SA.RGB 200 110 40
  "host" -> SA.RGB 185 150 55
  "cluster" -> SA.RGB 120 135 150
  "local" -> SA.RGB 95 140 170
  _ -> faint

addrValue :: AddressView -> String
addrValue a = case a.kind of
  "listening" -> maybe "" (\p -> ":" <> show p) a.port
  "proxied" -> fromMaybe "" a.path
  "published" -> fromMaybe "" a.domain
  "socket" -> fromMaybe "" a.socket
  _ -> ""

clip :: Int -> String -> String
clip n s = if length s > n then take (n - 1) s <> "…" else s

-- the small-multiples rack: one thumbnail per channel, drawn in the SAME
-- coordinate space as the main view (viewBox letterboxes it small), so each is
-- spatially congruent with the big diagram. Each thumbnail IS that channel's
-- legend (it shows the actual data, not a symbol), its isolated view (read one
-- relationship without leaving the full diagram), and its toggle. All on = the
-- full composite; all off = bare neutral cards. Dot sizes are derived from the
-- thumbnail scale so they read at a constant screen size whatever the extent.
channelRack
  :: forall act m
   . (Channel -> act) -> Set Channel -> Number -> Number
  -> Array Node -> Array Edge -> Array Route -> Set String -> Set (Tuple String String)
  -> Map String NodeLive -> H.ComponentHTML act () m
channelRack toggleChan channels maxX maxY nodes edges routes cutVertsAll bridgeSetAll live =
  HH.div [ cls "graph-rack" ] (map thumb allChannels)
  where
  sc = min (150.0 / max 1.0 maxX) (96.0 / max 1.0 maxY)
  rData = 5.0 / sc
  sw = 1.4 / sc
  ew = 1.6 / sc
  bw = 3.2 / sc

  posOf id = Array.find (\n -> n.id == id) nodes
  machines = Array.sort (Array.nub (Array.mapMaybe (\n -> Array.head n.place) nodes))
  cxOf n = n.x + nodeW / 2.0
  cyOf n = n.y + nodeH / 2.0

  dot2 n fill strk = SE.circle
    [ SA.cx (cxOf n), SA.cy (cyOf n), SA.r rData
    , SA.fill fill, SA.stroke strk, SA.strokeWidth sw ]
  hollow n strk = SE.circle
    [ SA.cx (cxOf n), SA.cy (cyOf n), SA.r rData
    , SA.fill paper, SA.fillOpacity 0.0, SA.stroke strk, SA.strokeWidth sw ]
  dot n col = dot2 n col col

  seg e col w = case posOf e.from, posOf e.to of
    Just f, Just t ->
      [ SE.line [ SA.x1 (cxOf f), SA.y1 (cyOf f), SA.x2 (cxOf t), SA.y2 (cyOf t), SA.stroke col, SA.strokeWidth w ] ]
    _, _ -> []

  routeSeg r = case posOf r.from, posOf r.to of
    Just f, Just t ->
      [ SE.line [ SA.x1 (cxOf f), SA.y1 (cyOf f), SA.x2 (cxOf t), SA.y2 (cyOf t), SA.stroke traffic, SA.strokeWidth ew, SA.strokeDashArray "8 5" ] ]
    _, _ -> []

  placeColor n = case Array.head n.place of
    Just mc -> (hostStyle (fromMaybe 0 (Array.elemIndex mc machines))).ink
    Nothing -> neutral

  content = case _ of
    ChSource -> map (\n -> dot n (if n.ghost then faint else srcColor n.source)) nodes
    ChDepth -> map (\n -> if n.ghost then hollow n neutral else dot n (depthThumb n.depth)) nodes
    ChExposure -> map (\n -> maybe (hollow n neutral) (\ad -> dot n (opennessColor ad.openness)) (mostExposedView n.reach)) nodes
    ChPlacement -> map (\n -> dot n (placeColor n)) nodes
    ChRequirement -> Array.concatMap (\e -> seg e edgeColor ew) edges <> map (\n -> dot n neutral) nodes
    ChTraffic -> Array.concatMap routeSeg routes <> map (\n -> dot n neutral) nodes
    ChSpof ->
      Array.concatMap (\e -> if Set.member (normEdge e.from e.to) bridgeSetAll then seg e alarm bw else []) edges
        <> map (\n -> dot n (if Set.member n.id cutVertsAll then alarm else neutral)) nodes
    ChLive -> map
      (\n -> case Map.lookup n.id live of
          Just LiveUp -> dot n liveUpColor
          Just LiveDown -> dot n alarm
          Just LiveRedirect -> dot n liveRedirectColor
          _ -> hollow n neutral)
      nodes

  thumb ch =
    HH.button
      [ cls (if Set.member ch channels then "sm-thumb on" else "sm-thumb")
      , HE.onClick \_ -> toggleChan ch
      ]
      [ SE.svg
          [ SA.viewBox 0.0 0.0 maxX maxY, SA.width 150.0, SA.height 96.0
          , SA.class_ (H.ClassName "sm-svg")
          ]
          (content ch)
      , HH.span [ cls "sm-cap" ] [ HH.text (channelLabel ch) ]
      ]

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls c = HP.class_ (HH.ClassName c)
