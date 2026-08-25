-- | The `/state` contract — the shape `bosun serve`'s status endpoint emits,
-- | decoded with a real codec so the dashboard fails loudly if serve's JSON ever
-- | drifts. These are RUNTIME-VIEW types (up?, pid), distinct from the plan-side
-- | `Bosun.Serve.Route` (cwd, launchCommand): /state reports what is running, not
-- | how to launch it.
module Chair.State
  ( RouteStatus
  , BrokerStatus
  , RedirectInfo
  , RejectInfo
  , DriftInfo
  , RegistryInfo
  , StateView
  , driftEntries
  , brokerEntries
  , decodeStateView
  , SuperviseState
  , SupervisionRow
  , TeardownRow
  , unsettledTeardowns
  , decodeSuperviseState
  ) where

import Prelude ((<<<), not)

import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError, decodeJson)
import Data.Either (Either)
import Data.Array as Array
import Data.Maybe (Maybe, fromMaybe)
import Data.Tuple (Tuple, snd)
import Foreign.Object (Object)
import Foreign.Object as Object

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

-- | One BROKERED service as the router currently finds it — a fourth bucket,
-- | not a flavour of route, and it needs its own type because almost nothing in
-- | `RouteStatus` applies. There is no `internalPort` (the service keeps its own
-- | address), no `up` (readiness is whatever `probe` could establish, and for
-- | half of them nothing could), and `publicPort` is frequently absent, which is
-- | normal rather than a fault: es9-daemon is reached at `~/.es9/control.sock`
-- | and link-spike over UDP multicast.
-- |
-- | Every field but `serviceId` is `Maybe`, for the reason the router's own
-- | additive fields are: a router binary predating broker mode emits none of
-- | this, and the Chair must degrade rather than fail to decode a fleet.
-- |
-- | `door` is the standing of the 307 listener on the registered public port —
-- | `none`/`open`/`aside`/`reclaim`/`blocked` (`Bosun.Serve.doorTag`). It is a
-- | separate fact from whether the daemon is running, and rendering it as one
-- | would repeat the conflation the router had to be fixed for.
type BrokerStatus =
  { serviceId :: String
  , publicPort :: Maybe Int
  -- where it actually is, once running — the payload of `/where`
  , at :: Maybe String
  , transport :: Maybe String
  -- which readiness check the plan chose; `"none"` means NOTHING WAS CHECKED,
  -- never that a check failed
  , probe :: Maybe String
  -- did the router start this one? `Nothing` covers both "no" and an older
  -- router, which is why it is not rendered as "down"
  , pid :: Maybe Int
  , door :: Maybe String
  , doorCheckedAt :: Maybe String
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
  -- additive, same convention. Until this was read, `/state` reported brokered
  -- services and the Chair showed them NOWHERE — the same "registered and
  -- invisible" class the drift work exists to close, one bucket along
  -- (RELAY-STALL-AND-BROKER-MODE.md §7.1).
  , brokered :: Maybe (Array BrokerStatus)
  }

-- | The drift list, absent-as-empty. An old router reports no drift because it
-- | cannot compute any — which is honest, if unhelpful.
driftEntries :: StateView -> Array DriftInfo
driftEntries = fromMaybe [] <<< _.drift

-- | The brokered list, absent-as-empty. A router predating broker mode brokers
-- | nothing, so empty IS the truth for it — unlike `drift`, where absent means
-- | "could not compute" and empty means "none".
brokerEntries :: StateView -> Array BrokerStatus
brokerEntries = fromMaybe [] <<< _.brokered

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
  -- | What the last teardown of each service actually did. Absent until a
  -- | `down` has run, and absent entirely from a supervise binary that predates
  -- | it — hence `Maybe`, like the two above.
  , teardown :: Maybe (Object TeardownRow)
  }

-- | One service's last teardown.
-- |
-- | `settled` is read rather than derived from `verdict`, deliberately: a
-- | consumer that decides for itself which of six tokens mean "it stopped" gets
-- | it wrong the first time a seventh appears, and the daemon already knows.
type TeardownRow =
  { verdict :: String
  , settled :: Boolean
  , at :: Number
  }

-- | The services whose last teardown did NOT settle — the only ones an operator
-- | needs to see. A `down` that worked should say nothing.
unsettledTeardowns :: SuperviseState -> Array (Tuple String TeardownRow)
unsettledTeardowns sv =
  Array.filter (not <<< _.settled <<< snd)
    (Object.toUnfoldable (fromMaybe Object.empty sv.teardown))

decodeSuperviseState :: Json -> Either JsonDecodeError SuperviseState
decodeSuperviseState = decodeJson
