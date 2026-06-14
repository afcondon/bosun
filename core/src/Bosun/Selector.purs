-- | DESIGN §3.6 — `Selector`, the second edge type (Containment).
-- |
-- | Membership, not dependency — and **never topo-sorted** (that's a category
-- | error every profile/namespace system invites). The universal invariant: a
-- | selector must be *closed under `Requires`* — one type, three tools' worth
-- | of footguns (compose frontend-without-backend, kustomize Deployment
-- | without its ConfigMap, systemd target pulling an unsatisfied unit).
module Bosun.Selector where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)

data Selector
  = Profile       String   -- compose profiles: ("core","minard","tidal","full",…)
  | Namespace     String   -- k8s
  | SystemdTarget String   -- multi-user.target
  | Workspace     String   -- terraform
derive instance Eq Selector
derive instance Ord Selector
derive instance Generic Selector _
instance Show Selector where show = genericShow
