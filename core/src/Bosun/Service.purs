-- | DESIGN §3.7 — the public face of the loose/tight service types.
-- |
-- | Re-exports `Bosun.Service.Internal` MINUS the three tight-type minters
-- | (`mkServiceRef`/`mkBootOrder`/`mkValidatedDeployment`). External code gets
-- | the types and the `un*` accessors but cannot forge a proof — only
-- | `Bosun.Validate` (which imports Internal directly) can. The tight
-- | constructors are absent from the import list below, so they are private to
-- | the core.
module Bosun.Service
  ( module Reexport
  ) where

import Bosun.Service.Internal
  ( Source(..)
  , Role, mkRole, unRole
  , RawDep, RawRoute, LaunchSpec
  , ServiceInstance
  , LooseDep, LooseRoute, LooseService
  , Deployment, mkDeployment, deploymentServices
  , ServiceRef, unServiceRef
  , BootOrder, unBootOrder
  , ResolvedDep, ResolvedRoute
  , Service
  , ValidatedDeploymentR, ValidatedDeployment, unValidatedDeployment
  ) as Reexport
