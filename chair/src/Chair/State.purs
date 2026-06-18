-- | The `/state` contract — the shape `bosun serve`'s status endpoint emits,
-- | decoded with a real codec so the dashboard fails loudly if serve's JSON ever
-- | drifts. These are RUNTIME-VIEW types (up?, pid), distinct from the plan-side
-- | `Bosun.Serve.Route` (cwd, launchCommand): /state reports what is running, not
-- | how to launch it.
module Chair.State
  ( RouteStatus
  , RedirectInfo
  , RejectInfo
  , StateView
  , decodeStateView
  , SuperviseState
  , SupervisionRow
  , decodeSuperviseState
  ) where

import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError, decodeJson)
import Data.Either (Either)
import Data.Maybe (Maybe)
import Foreign.Object (Object)

type RouteStatus =
  { serviceId :: String
  , publicPort :: Int
  , internalPort :: Int
  , up :: Boolean
  , pid :: Maybe Int
  }

type RedirectInfo =
  { serviceId :: String
  , publicPort :: Int
  , host :: String
  , target :: String
  }

type RejectInfo = { serviceId :: String, reason :: String }

type StateView =
  { routes :: Array RouteStatus
  , redirects :: Array RedirectInfo
  , rejected :: Array RejectInfo
  }

-- argonaut-codecs derives the record decoder; `Maybe Int` for `pid` makes it
-- optional/nullable, matching serve emitting `pid: null` when a backend is down.
decodeStateView :: Json -> Either JsonDecodeError StateView
decodeStateView = decodeJson

-- | The OTHER `/state` shape — what `bosun supervise` emits (NOT serve's
-- | routes/redirects/rejected, despite the handoff's "same shape" claim). It's a
-- | group desired-state plus a serviceId → status-token map:
-- |   { "desired": "up"|"down", "services": { "<serviceId>": "running"|… } }
-- | Keyed by canonical serviceId, which is exactly the Chair's correlation key —
-- | the `services` object maps node↔status through the same `canonOf` bridge as
-- | serve. `desired` is the manual-hold indicator (down ⇒ auto-restart suspended).
-- | One service's supervision badge data (ADR D-S1). Decoded MINIMALLY on
-- | purpose — argonaut's record decoder ignores the other keys the daemon emits
-- | (`fails`, `lastTransitionAt`, `suspendedUntil`), so a shape hiccup in those
-- | can never break the core status decode. `restarts` is what the `↻ N` badge
-- | needs; widen this row when the sparkline/“Xs ago” work lands.
type SupervisionRow = { restarts :: Int }

type SuperviseState =
  { desired :: String
  , services :: Object String
  -- additive D-S1 fields; `Maybe` so plain serve / a pre-D-S1 supervise binary
  -- (which omit them) still decode.
  , supervised :: Maybe Boolean
  , supervision :: Maybe (Object SupervisionRow)
  }

decodeSuperviseState :: Json -> Either JsonDecodeError SuperviseState
decodeSuperviseState = decodeJson
