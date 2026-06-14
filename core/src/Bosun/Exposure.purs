-- | DESIGN §3.3 — `Exposure`, how a service is reached, as a sum.
-- |
-- | Note `UnixSocket`: the music rig's daemons (es9-daemon, fh2 daemon) are
-- | real services reached by socket, not port. A model that assumed
-- | "service ⇒ TCP port" couldn't even describe half the infrastructure.
module Bosun.Exposure where

import Prelude

import Bosun.Atoms (AbsPath, Domain, Port, RoutePath, ServiceId)

data Exposure
  = HostPort     Port                                      -- published to host (3000:3000)
  | InternalPort Port                                      -- network-internal; siblings reach it
  | ProxyRoute   { proxy :: ServiceId, path :: RoutePath } -- behind edge/ingress; the route is an EDGE too
  | PublicDomain Domain                                    -- CDN / ingress host
  | UnixSocket   AbsPath                                   -- ~/.es9/control.sock, ~/.fh2/control.sock
  | NoNetwork                                              -- worker / one-shot

derive instance Eq Exposure
