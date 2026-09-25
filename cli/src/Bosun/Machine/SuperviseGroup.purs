-- | GENERATED FILE — do not edit.
-- |
-- | Regenerate with `scripts/machine-vocabulary.sh`.
-- | Source: `machines/supervise-group.json` (glassbox format 2).
-- |
-- | This module is the machine's **alphabet**, and deliberately nothing else.
-- | It declares which states exist and which commands exist; it says nothing
-- | about which state leads to which, so it cannot disagree with the artifact
-- | about behaviour. The transitions stay in the JSON, singular.
-- |
-- | Regenerating is not what makes this safe — the host's vocabulary check
-- | compares these names with the artifact at boot, so a module left stale is a
-- | startup failure rather than a silent drift.
module Bosun.Machine.SuperviseGroup
  ( Phase
  , Cases
  , Events
  , Commands
  , Refusals
  , Excuses
  , phases
  , events
  , commands
  , refusals
  ) where

import Prelude (Unit)

import Type.Proxy (Proxy(..))

-- | The states this machine can be in.
-- |
-- | `Unit` because a Glassbox state is an opaque identifier and carries
-- | nothing with it.
type Phase :: Row Type
type Phase =
  ( "adopting" :: Unit
  , "held" :: Unit
  , "lowering" :: Unit
  , "raised" :: Unit
  , "raising" :: Unit
  , "reloading" :: Unit
  , "restarting" :: Unit
  )

-- | The same states as a row of **handlers**.
-- |
-- | This is what a renderer annotates its `Variant.match` record with, and the
-- | annotation is what makes a forgotten state say `PropertyIsMissing` — which
-- | names the label — instead of a row-unification failure that does not.
type Cases :: Type -> Row Type
type Cases b =
  ( "adopting" :: Unit -> b
  , "held" :: Unit -> b
  , "lowering" :: Unit -> b
  , "raised" :: Unit -> b
  , "raising" :: Unit -> b
  , "reloading" :: Unit -> b
  , "restarting" :: Unit -> b
  )

-- | The events this machine will answer to.
-- |
-- | A host that names an event through this row cannot send one the
-- | machine has never heard of — which a bare `EventId` could not prevent,
-- | because every misspelling is a perfectly good string.
type Events :: Row Type
type Events =
  ( "done" :: Unit
  , "down" :: Unit
  , "rejected" :: Unit
  , "reload" :: Unit
  , "reloaded" :: Unit
  , "restart" :: Unit
  , "tick" :: Unit
  , "up" :: Unit
  )

-- | The commands this machine can ask its host to carry out.
type Commands :: Type -> Row Type
type Commands v =
  ( "bring-up" :: v
  , "forget-changed-launches" :: v
  , "forget-launch-memory" :: v
  , "re-ingest" :: v
  , "reconcile" :: v
  , "restart-one" :: v
  , "stop-changed" :: v
  , "swap-spec" :: v
  , "tear-down" :: v
  )

-- | The refusals this machine can answer with.
type Refusals :: Row Type
type Refusals =
  ( "busy" :: Unit
  , "held-by-foreigner" :: Unit
  , "no-reload-source" :: Unit
  , "no-such-service" :: Unit
  , "not-raised" :: Unit
  )

-- | The same refusals as a row of handlers, so a host must say what each
-- | one means. A refusal that reaches nobody is the failure the
-- | Stay/Refuse distinction exists to prevent.
type Excuses :: Type -> Row Type
type Excuses b =
  ( "busy" :: Unit -> b
  , "held-by-foreigner" :: Unit -> b
  , "no-reload-source" :: Unit -> b
  , "no-such-service" :: Unit -> b
  , "not-raised" :: Unit -> b
  )

phases :: Proxy Phase
phases = Proxy

events :: Proxy Events
events = Proxy

commands :: Proxy (Commands Unit)
commands = Proxy

refusals :: Proxy Refusals
refusals = Proxy
