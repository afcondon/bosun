-- | The `/analyze` + `/state` WIRE CONTRACT for Bosun's Chair (and now Brunel).
-- |
-- | Flat, display-oriented **view types** projected from the IR at each rung of
-- | the loose→tight MISU ladder, plus bidirectional `codec-argonaut` codecs. The
-- | codecs are *values* (entry-73 house rule), defined once here and shared by
-- | every end: `chair-server` ENCODES an `AnalyzeResult`, a Halogen frontend
-- | DECODES it with the same codec value — so the contract cannot drift.
-- |
-- | Extracted from `Bosun.View` (2026-07-22) so a CLIENT can depend on the
-- | contract WITHOUT the reconcile engine: every type here is a flat record of
-- | primitives (or of other view types) — no IR, no engine. `Bosun.View` keeps
-- | the projections (IR → these types) and re-exports this module, so nothing
-- | that imported the types from `Bosun.View` changes.
module Bosun.Protocol where

import Prelude

import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Compat as CAC
import Data.Codec.Argonaut.Record as CAR
import Data.Maybe (Maybe(..))
import Data.Profunctor (dimap)

-- ── view types (the wire shapes) ─────────────────────────────────────────────

type DepView = { to :: String, ordering :: Maybe String, requirement :: Maybe String }
type RouteView = { to :: String, path :: String }
type ExecutorView = { mechanism :: String, detail :: String }

-- | One inbound address, projected for the exposure badge — the `Address` glob
-- | (NAME·HOST·PORT·PATH·SINK) as a flat record the badge renderer reads. Only
-- | the cells relevant to the kind are populated; `openness` carries the spine.
type AddressView =
  { kind     :: String         -- listening | proxied | published | socket
  , bind     :: Maybe String   -- listening: all | loopback | internal | <host>
  , port     :: Maybe Int      -- listening
  , path     :: Maybe String   -- proxied
  , proxy    :: Maybe String   -- proxied
  , domain   :: Maybe String   -- published
  , socket   :: Maybe String   -- socket
  , openness :: String         -- none | local | cluster | host | wide | internet
  }

-- | RUNG 1 — a single ingested instance, loose/open, per (source × unit).
type ServiceInstanceView =
  { source    :: String
  , project   :: Maybe String
  , localName :: String
  , role      :: String
  , host      :: Maybe String
  -- placement as a failure-domain PATH, coarse→fine (e.g. ["mini-1","data-1"]);
  -- co-location = a shared prefix. `host` stays the finest level for back-compat.
  , place     :: Array String
  , executor  :: ExecutorView
  , exposure  :: String
  , reachability :: Array AddressView
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

-- | One node of the DECLARED supervisor topology, flattened depth-first so the
-- | Chair renders it as an indented tree (`depth` = indent). `groupPort = Just p`
-- | marks a sub-supervisor (its live `/state` is on `p`); `Nothing` is a leaf.
type TopologyEntry =
  { name      :: String
  , port      :: Maybe Int      -- the service's own exposed port, if any
  , groupPort :: Maybe Int      -- Just ⇒ a sub-supervisor; its /state port
  , compose   :: Maybe String   -- a group's own compose (for the detail graph)
  , registry  :: Maybe String
  , parent    :: Maybe String
  , mechanism :: String
  , depth     :: Int
  }

-- ── codecs (codec-argonaut; one value, shared by both ends) ──────────────────

depViewCodec :: CA.JsonCodec DepView
depViewCodec = CAR.object "DepView"
  { to: CA.string, ordering: CAC.maybe CA.string, requirement: CAC.maybe CA.string }

routeViewCodec :: CA.JsonCodec RouteView
routeViewCodec = CAR.object "RouteView" { to: CA.string, path: CA.string }

executorViewCodec :: CA.JsonCodec ExecutorView
executorViewCodec = CAR.object "ExecutorView" { mechanism: CA.string, detail: CA.string }

addressViewCodec :: CA.JsonCodec AddressView
addressViewCodec = CAR.object "AddressView"
  { kind: CA.string
  , bind: CAC.maybe CA.string
  , port: CAC.maybe CA.int
  , path: CAC.maybe CA.string
  , proxy: CAC.maybe CA.string
  , domain: CAC.maybe CA.string
  , socket: CAC.maybe CA.string
  , openness: CA.string
  }

serviceInstanceViewCodec :: CA.JsonCodec ServiceInstanceView
serviceInstanceViewCodec = CAR.object "ServiceInstanceView"
  { source: CA.string
  , project: CAC.maybe CA.string
  , localName: CA.string
  , role: CA.string
  , host: CAC.maybe CA.string
  , place: CA.array CA.string
  , executor: executorViewCodec
  , exposure: CA.string
  , reachability: CA.array addressViewCodec
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

topologyEntryCodec :: CA.JsonCodec TopologyEntry
topologyEntryCodec = CAR.object "TopologyEntry"
  { name: CA.string
  , port: CAC.maybe CA.int
  , groupPort: CAC.maybe CA.int
  , compose: CAC.maybe CA.string
  , registry: CAC.maybe CA.string
  , parent: CAC.maybe CA.string
  , mechanism: CA.string
  , depth: CA.int
  }

topologyCodec :: CA.JsonCodec (Array TopologyEntry)
topologyCodec = CA.array topologyEntryCodec

-- ── the request contract (frontend → chair-server) ───────────────────────────

-- | A user correction to the auto-derived alias map. `Merge` says "these
-- | ingested names are one service"; `Split` removes a name from the map so it
-- | falls back to its own identity.
data AliasOverride
  = Merge { canonical :: String, names :: Array String }
  | Split { name :: String }
derive instance Eq AliasOverride

-- | What the Chair POSTs to `/analyze`. `compose` / `registry` are source
-- | locators the server resolves at its edge.
type AnalyzeRequest =
  { compose   :: Maybe String
  , registry  :: Maybe String
  , overrides :: Array AliasOverride
  }

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
