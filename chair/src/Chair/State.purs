-- | The `/state` contract — the shape `bosun serve`'s status endpoint emits,
-- | decoded with a real codec so the dashboard fails loudly if serve's JSON ever
-- | drifts. These are RUNTIME-VIEW types (up?, pid), distinct from the plan-side
-- | `Bosun.Serve.Route` (cwd, launchCommand): /state reports what is running, not
-- | how to launch it.
module Chair.State
  ( RouteStatus
  , RedirectInfo
  , RejectInfo
  , DriftInfo
  , RegistryInfo
  , StateView
  , driftEntries
  , decodeStateView
  , SuperviseState
  , SupervisionRow
  , decodeSuperviseState
  ) where

import Prelude ((<<<))

import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError, decodeJson)
import Data.Either (Either)
import Data.Maybe (Maybe, fromMaybe)
import Foreign.Object (Object)

-- | One lazy-spawn route as the router currently finds it. `up` is not enough on
-- | its own: a route can be up because an EXTERNAL process (one serve did not
-- | start) holds the public port, and it can be down-and-unreachable because the
-- | router never managed to bind that port at all. Both are rendered, because
-- | both were previously indistinguishable from an ordinary idle route.
-- |
-- | The four additive fields are `Maybe` so a router binary predating them still
-- | decodes (the same convention as `drift`).
type RouteStatus =
  { serviceId :: String
  , publicPort :: Int
  , internalPort :: Int
  , up :: Boolean
  , pid :: Maybe Int
  -- served by a process serve did not spawn; it holds the public port itself
  , external :: Maybe Boolean
  -- when that adoption claim was last probed — `up` is only as good as this
  , externalCheckedAt :: Maybe String
  -- does the router hold the public port? `false` + not external ⇒ nothing is
  -- listening, so no request can arrive and lazy-spawn can never fire
  , bound :: Maybe Boolean
  , bindError :: Maybe String
  }

type RedirectInfo =
  { serviceId :: String
  , publicPort :: Int
  , host :: String
  , target :: String
  }

-- | A service the router SAW and cannot use — with the port it claimed, so a
-- | refusal can be joined to the fleet row that caused it. Contrast `DriftInfo`.
type RejectInfo = { serviceId :: String, publicPort :: Maybe Int, reason :: String }

-- | A public port where the registry on disk and the router's held plan
-- | disagree. `kind` is `unrouted` | `altered` | `departed`; `note` is the
-- | sentence the router already rendered, so the Chair does not re-word it.
-- |
-- | This is the one thing /state could not previously say: a row that was
-- | registered but never reached the router appeared in NO bucket — not even
-- | `rejected` — so the Chair showed nothing at all and the registration looked
-- | like it had never happened (itajara @3028, 2026-08-14 → 17).
type DriftInfo = { serviceId :: String, publicPort :: Int, kind :: String, note :: String }

-- | Where the router's plan came from and when — enough for the Chair to say
-- | "registered <when>, not routed" without a second source.
-- |
-- | `error` is why the drift check could not be MADE (an unreadable registry, a
-- | re-plan that threw). When it is present, `drift`/`stale` are the last answer
-- | rather than a current one — a failed check must not read as agreement.
type RegistryInfo =
  { source :: String
  , plannedAt :: Maybe String
  , modifiedAt :: Maybe String
  , error :: Maybe String
  }

type StateView =
  { routes :: Array RouteStatus
  , redirects :: Array RedirectInfo
  , rejected :: Array RejectInfo
  -- additive; `Maybe` so a router binary predating the drift work still decodes
  -- (the same convention as `supervision` below — and the very drift class this
  -- field exists to expose applies to Bosun's own parts).
  , drift :: Maybe (Array DriftInfo)
  , registry :: Maybe RegistryInfo
  }

-- | The drift list, absent-as-empty. An old router reports no drift because it
-- | cannot compute any — which is honest, if unhelpful.
driftEntries :: StateView -> Array DriftInfo
driftEntries = fromMaybe [] <<< _.drift

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
