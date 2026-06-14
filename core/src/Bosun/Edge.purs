-- | DESIGN §3.4 — typed dependency edges (systemd's taxonomy, corrected).
-- |
-- | Ordering ⟂ requirement: a real edge usually *combines* them (the
-- | canonical `Wants=`+`After=` pair), so a `DepEdge` is a **product**, not a
-- | flat sum; and the requirement axis is a *gradient*, not one pair. The
-- | reverse-proxy route is a separate *data/traffic* edge (`RouteEdge`),
-- | never a lifecycle edge — three graphs over the same nodes (§3.6, D-5).
module Bosun.Edge where

import Prelude

import Bosun.Atoms (AbsPath, EnvVar, Port, RoutePath, ServiceId)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)

-- | An edge in the DEPENDENCY graph. Both axes optional; a real edge commonly
-- | asserts both.
type DepEdge =
  { from        :: ServiceId
  , to          :: ServiceId
  , ordering    :: Maybe DepOrdering
  , requirement :: Maybe Requirement
  , provenance  :: Provenance
  }

-- | DESIGN §3.4 calls this `Ordering`; renamed to avoid the clash with
-- | `Prelude.Ordering`. systemd `After=` / `Before=`.
data DepOrdering = StartAfter | StartBefore
derive instance Eq DepOrdering
derive instance Generic DepOrdering _
instance Show DepOrdering where show = genericShow

-- | The requirement gradient (systemd): soft → hard-with-gate → must-pre-exist
-- | → crash-coupled → reverse-only.
data Requirement
  = Wants            -- best-effort; absent is OK            (systemd Wants=)
  | Requires Gate    -- hard; wait per the gate              (systemd Requires= + condition)
  | Requisite        -- must ALREADY be active; never auto-start (an external dep)
  | BindsTo          -- Requires + crash-coupling: I stop if it stops unexpectedly
  | PartOf           -- reverse-only: its stop/restart propagates to me; its start does not
derive instance Eq Requirement
derive instance Generic Requirement _
instance Show Requirement where show = genericShow

-- | compose `condition:*`; k8s gates. Only `Requires gate` *waits*.
data Gate = OnStarted | OnReady | OnHealthy | OnCompleted
derive instance Eq Gate
derive instance Ord Gate
derive instance Generic Gate _
instance Show Gate where show = genericShow

-- | Pulumi: most edges are inferred from dataflow; only genuinely external
-- | ordering is hand-`Declared`.
data Provenance = Declared | Inferred DataRef
derive instance Eq Provenance
derive instance Generic Provenance _
instance Show Provenance where show = genericShow

data DataRef = ViaPort Port | ViaSocket AbsPath | ViaEnv EnvVar
derive instance Eq DataRef
derive instance Generic DataRef _
instance Show DataRef where show = genericShow

-- | A data/traffic edge (reverse-proxy route). Informs the route table and an
-- | *inferred* companion dep edge, but is not itself ordering (§3.6, D-5).
type RouteEdge = { proxy :: ServiceId, backend :: ServiceId, path :: RoutePath }
