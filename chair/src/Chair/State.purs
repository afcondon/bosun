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
  ) where

import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError, decodeJson)
import Data.Either (Either)
import Data.Maybe (Maybe)

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
