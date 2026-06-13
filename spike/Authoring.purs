-- | SPIKE: can PureScript's rows-as-type-level-sets give us Propellor-grade
-- | authoring combinators that only typecheck against compatible endpoints?
-- |
-- | A Service is phantom-indexed by a ROW of capability tags. Rows are
-- | unordered (this is the win over Propellor's order-sensitive type-level
-- | LIST). `Prim.Row.Cons` as a membership test; `Lacks` to enforce set
-- | semantics on construction. Zero dependencies — only Prim builtins.
module Authoring where

import Prim.Row (class Cons, class Lacks)

-- Phantom payload marking "this capability is present".
data Present

-- Opaque runtime carrier (the real record is elided in the spike).
data ServiceImpl = ServiceImpl
data RouteEdge   = RouteEdge
data DepEdge     = DepEdge

-- The service, indexed by its capability SET.
newtype Service (caps :: Row Type) = Service ServiceImpl

-- ── Builders: each mints a service with a specific capability set ──────────

-- A static CDN site: reachable (has a public URL), but not lifecycle-managed
-- by us and with no readiness probe.
mkStaticSite :: Service ( reachable :: Present )
mkStaticSite = Service ServiceImpl

-- A process with a readiness probe: reachable + has readiness + lifecycle.
mkProcessReady :: Service ( reachable :: Present, hasReadiness :: Present, lifecycle :: Present )
mkProcessReady = Service ServiceImpl

-- A background worker: lifecycle-managed, but NoNetwork → NOT reachable.
mkWorker :: Service ( lifecycle :: Present )
mkWorker = Service ServiceImpl

-- ── Capability-building combinator (set semantics via Lacks) ───────────────

-- Attach a readiness probe. `Lacks` makes adding it twice a TYPE ERROR — you
-- cannot put the same capability in the set twice (genuine set behaviour).
withReadiness
  :: forall caps caps'
   . Lacks "hasReadiness" caps
  => Cons "hasReadiness" Present caps caps'
  => Service caps
  -> Service caps'
withReadiness (Service i) = Service i

-- ── Edge combinators: the compatibility constraints live in the types ──────

-- A proxy may route to a backend ONLY IF the backend is `reachable`.
routeTo
  :: forall proxyCaps backendCaps tail
   . Cons "reachable" Present tail backendCaps
  => Service proxyCaps
  -> Service backendCaps
  -> RouteEdge
routeTo _ _ = RouteEdge

-- A "wait until ready" edge may gate on an upstream ONLY IF it has readiness.
-- (This makes `UncheckableGate` a COMPILE error, not a validate-time one.)
requiresReady
  :: forall downCaps upCaps tail
   . Cons "hasReadiness" Present tail upCaps
  => Service downCaps
  -> Service upCaps
  -> DepEdge
requiresReady _ _ = DepEdge

-- Co-life (BindsTo): both endpoints must be lifecycle-managed (never a CDN).
bindsTo
  :: forall aCaps bCaps t1 t2
   . Cons "lifecycle" Present t1 aCaps
  => Cons "lifecycle" Present t2 bCaps
  => Service aCaps
  -> Service bCaps
  -> DepEdge
bindsTo _ _ = DepEdge

-- ── POSITIVE cases: these MUST compile ─────────────────────────────────────

-- proxy can be anything; backend (static site) is reachable ✓
okRoute :: RouteEdge
okRoute = routeTo mkWorker mkStaticSite

-- upstream (process) has a readiness probe ✓
okGate :: DepEdge
okGate = requiresReady mkWorker mkProcessReady

-- both lifecycle-managed ✓
okBind :: DepEdge
okBind = bindsTo mkWorker mkProcessReady

-- build a capability set up: worker had no readiness, now it does ✓
workerWithReadiness :: Service ( hasReadiness :: Present, lifecycle :: Present )
workerWithReadiness = withReadiness mkWorker

-- and now it can be gated on ✓
okGateBuilt :: DepEdge
okGateBuilt = requiresReady mkStaticSite workerWithReadiness
