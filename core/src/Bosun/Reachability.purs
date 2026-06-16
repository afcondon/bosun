-- | ADDRESS-TYPE.md §2 — `Reachability`, a service's inbound surface as a
-- | *set of addresses*, refining `Bosun.Exposure` along the axis the old sum
-- | could not express: **bind scope** (`0.0.0.0` vs `127.0.0.1`).
-- |
-- | This is the richer type the Pillar-3 exposure badge wanted to render and
-- | the IR could not supply. `Exposure` is NOT retired — it survives as the
-- | lossy projection `classify :: Reachability -> Exposure`, so every existing
-- | consumer keeps compiling by reading `classify s.reachability` until it
-- | chooses to read the richer type directly (ADDRESS-TYPE §4, §7).
-- |
-- | MISU (§5): illegal addresses stay unrepresentable — you cannot build a
-- | portless `Listening`. The one trade is that "exactly one way to be reached"
-- | is no longer free-by-construction (composition is real); `Set` still dedups
-- | identical addresses for free.
module Bosun.Reachability
  ( Reachability(..)
  , Address(..)
  , BindScope(..)
  , Openness(..)
  , addresses
  , noNetwork
  , listening
  , hostPort
  , internalPort
  , loopbackPort
  , proxyRoute
  , publicDomain
  , unixSocket
  , classify
  , openness
  , maxOpenness
  ) where

import Prelude

import Bosun.Atoms (AbsPath, Domain, Host, Port, RoutePath, ServiceId)
import Bosun.Exposure (Exposure(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set

-- | How a service can be reached. `Set.empty` = no inbound surface (the old
-- | `NoNetwork`, now a principled degenerate case rather than a constructor).
newtype Reachability = Reachability (Set Address)

derive instance Eq Reachability
derive instance Ord Reachability

-- | One inbound address — a tight sum reusing the atoms (§2). The viz projects
-- | this onto a uniform NAME·HOST·PORT·PATH·SINK stack; the type stays tight.
data Address
  = Listening { bind :: BindScope, port :: Port }        -- a network listener
  | Proxied   { proxy :: ServiceId, path :: RoutePath }  -- behind a reverse proxy at a path
  | Published Domain                                     -- a public DNS name (CDN / ingress)
  | Socket    AbsPath                                    -- a unix-domain socket (es9 / fh2 daemons)

derive instance Eq Address
derive instance Ord Address

-- | Where a listener binds — the security-relevant scope `HostPort`/
-- | `InternalPort` could not grade. Closes gap (1): `0.0.0.0` vs `127.0.0.1`.
data BindScope
  = AllIfaces        -- 0.0.0.0 / [::]  — every interface (widest surface)
  | HostIface Host   -- a specific host/interface (opaque Host: tailnet / LAN / public)
  | Internal         -- cluster/network-internal only (k8s ClusterIP)
  | Loopback         -- 127.0.0.1 / ::1 — same machine only

derive instance Eq BindScope
derive instance Ord BindScope

-- | The exposure spine — derived, not stored (derive-don't-store). Drives the
-- | viz colour-ramp and scope-aware security checks. Ordered NoneOpen < … <
-- | InternetWide; `max` picks the most-exposed member of a composite.
data Openness = NoneOpen | LocalOnly | ClusterOnly | HostScoped | WideOpen | InternetWide

derive instance Eq Openness
derive instance Ord Openness

-- ── accessor ─────────────────────────────────────────────────────────────────

addresses :: Reachability -> Set Address
addresses (Reachability s) = s

-- ── smart constructors (mirror the old `Exposure` constructors) ──────────────

-- | No inbound surface — worker / one-shot (old `NoNetwork`).
noNetwork :: Reachability
noNetwork = Reachability Set.empty

-- | A single listener with an explicit bind scope.
listening :: BindScope -> Port -> Reachability
listening bind port = Reachability (Set.singleton (Listening { bind, port }))

-- | Published to the host on every interface — the docker `ports: "3000:3000"`
-- | semantics (binds `0.0.0.0`). The faithful replacement for old `HostPort`.
hostPort :: Port -> Reachability
hostPort = listening AllIfaces

-- | Network-internal; siblings reach it (old `InternalPort`).
internalPort :: Port -> Reachability
internalPort = listening Internal

-- | Loopback-only — reachable from the same machine (newly expressible).
loopbackPort :: Port -> Reachability
loopbackPort = listening Loopback

-- | Behind a reverse proxy at a path (old `ProxyRoute`).
proxyRoute :: { proxy :: ServiceId, path :: RoutePath } -> Reachability
proxyRoute r = Reachability (Set.singleton (Proxied r))

-- | A public DNS name — CDN / ingress (old `PublicDomain`).
publicDomain :: Domain -> Reachability
publicDomain d = Reachability (Set.singleton (Published d))

-- | A unix-domain socket (old `UnixSocket`).
unixSocket :: AbsPath -> Reachability
unixSocket a = Reachability (Set.singleton (Socket a))

-- ── projection back to the old sum (ADDRESS-TYPE §4) ─────────────────────────

-- | The lossy projection that keeps every existing consumer compiling. Single
-- | addresses map exactly per the §3 table; a composite collapses to its
-- | most-exposed member — and that loss IS the evidence the old type could not
-- | represent composition.
classify :: Reachability -> Exposure
classify (Reachability s) = case mostExposed s of
  Nothing -> NoNetwork
  Just a -> classifyAddress a

classifyAddress :: Address -> Exposure
classifyAddress = case _ of
  Socket a -> UnixSocket a
  Published d -> PublicDomain d
  Proxied r -> ProxyRoute r
  Listening { bind, port } -> case bind of
    Internal -> InternalPort port
    Loopback -> InternalPort port
    AllIfaces -> HostPort port
    HostIface _ -> HostPort port

-- | Where a single address sits on the exposure ramp.
openness :: Address -> Openness
openness = case _ of
  Socket _ -> LocalOnly
  Published _ -> InternetWide
  Proxied _ -> HostScoped
  Listening { bind } -> case bind of
    Loopback -> LocalOnly
    Internal -> ClusterOnly
    HostIface _ -> HostScoped
    AllIfaces -> WideOpen

-- | The most-exposed member of a whole reachability (empty ⇒ `NoneOpen`).
maxOpenness :: Reachability -> Openness
maxOpenness (Reachability s) =
  foldl (\acc a -> max acc (openness a)) NoneOpen (Set.toUnfoldable s :: Array Address)

mostExposed :: Set Address -> Maybe Address
mostExposed s = foldl pick Nothing (Set.toUnfoldable s :: Array Address)
  where
  pick acc a = case acc of
    Nothing -> Just a
    Just b -> Just (if openness a > openness b then a else b)
