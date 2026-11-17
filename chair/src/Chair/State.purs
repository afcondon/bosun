-- | The two `/state` documents the Chair reads, each through Bosun's one
-- | description of it (`bosun-protocol`), so the Chair cannot hold its own
-- | idea of either shape:
-- |
-- |   * the ROUTER's (`bosun serve`): `Bosun.Protocol.ServeState`
-- |   * a GROUP's (`bosun supervise`, `bosun docker`): `Bosun.Protocol.State`
-- |
-- | Until 2026-11-17 this module declared both shapes itself and decoded them
-- | with argonaut. The types here are now the protocol's, under the names the
-- | Chair already used. A document that cannot be read is refused with the
-- | name of the first field that is missing or wrong.
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

import Prelude

import Bosun.Protocol.ServeState as Router
import Bosun.Protocol.State as Group
import Data.Argonaut.Core (Json)
import Data.Array as Array
import Data.Either (Either)
import Data.Maybe (Maybe, fromMaybe)
import Data.Tuple (Tuple, snd)
import Foreign.Object (Object)
import Foreign.Object as Object

-- | One lazy-spawn route as the router currently finds it. `up` is not enough on
-- | its own: a route can be up because an EXTERNAL process (one serve did not
-- | start) holds the public port, and it can be down-and-unreachable because the
-- | router never managed to bind that port at all. Both are rendered, because
-- | both were previously indistinguishable from an ordinary idle route.
type RouteStatus = Router.Route

-- | One BROKERED service as the router currently finds it — a fourth bucket,
-- | not a flavour of route. There is no `internalPort` (the service keeps its
-- | own address), no `up` (readiness is whatever `probe` could establish, and
-- | for half of them nothing could), and `publicPort` is frequently absent,
-- | which is normal rather than a fault: es9-daemon is reached at
-- | `~/.es9/control.sock` and Diaphus over UDP multicast.
-- |
-- | `door` is the standing of the 307 listener on the registered public port —
-- | `none`/`open`/`aside`/`reclaim`/`blocked` (`Bosun.Serve.doorTag`). It is a
-- | separate fact from whether the daemon is running, and rendering it as one
-- | would repeat the conflation the router had to be fixed for.
type BrokerStatus = Router.Brokered

type RedirectInfo = Router.Redirect

-- | A service the router SAW and cannot use — with the port it claimed, so a
-- | refusal can be joined to the fleet row that caused it. Contrast `DriftInfo`.
type RejectInfo = Router.Rejected

-- | A public port where the registry on disk and the router's held plan
-- | disagree. `kind` is `unrouted` | `altered` | `departed`; `note` is the
-- | sentence the router already rendered, so the Chair does not re-word it.
-- |
-- | This is the one thing /state could not previously say: a row that was
-- | registered but never reached the router appeared in NO bucket — not even
-- | `rejected` — so the Chair showed nothing at all and the registration looked
-- | like it had never happened (itajara @3028, 2026-08-14 → 17).
type DriftInfo = Router.Drift

-- | Where the router's plan came from and when — enough for the Chair to say
-- | "registered <when>, not routed" without a second source.
-- |
-- | `error` is why the drift check could not be MADE (an unreadable registry, a
-- | re-plan that threw). When it is present, `drift`/`stale` are the last answer
-- | rather than a current one — a failed check must not read as agreement.
type RegistryInfo = Router.Registry

type StateView = Router.ServeState

-- | The drift list, absent-as-empty. An old router reports no drift because it
-- | cannot compute any — which is honest, if unhelpful.
driftEntries :: StateView -> Array DriftInfo
driftEntries = fromMaybe [] <<< _.drift

-- | The brokered list, absent-as-empty. A router predating broker mode brokers
-- | nothing, so empty IS the truth for it — unlike `drift`, where absent means
-- | "could not compute" and empty means "none".
brokerEntries :: StateView -> Array BrokerStatus
brokerEntries = fromMaybe [] <<< _.brokered

decodeStateView :: Json -> Either String StateView
decodeStateView = Router.readServeState

-- | A group's document, as the Chair holds it: the protocol's `Group` with its
-- | tables turned into objects, because the Chair looks services up by id.
-- | `desired` is the manual-hold indicator (down ⇒ auto-restart suspended).
type SuperviseState =
  { desired :: String
  , services :: Object String
  , supervised :: Boolean
  , supervision :: Object SupervisionRow
  -- | What the last teardown of each service actually did. Absent until a
  -- | `down` has run.
  , teardown :: Maybe (Object TeardownRow)
  }

-- | One service's row: `restarts` is what the `↻ N` badge needs, and the rest
-- | (`fails`, `gaveUp`, `lastTransitionAt`, docker's `health`) is there to draw.
type SupervisionRow = Group.Progress

-- | One service's last teardown.
-- |
-- | `settled` is read rather than derived from `verdict`, deliberately: a
-- | consumer that decides for itself which tokens mean "it stopped" gets it
-- | wrong the first time a new one appears (`killed` did, 2026-11-17), and the
-- | daemon already knows.
type TeardownRow = Group.Teardown

-- | The services whose last teardown did NOT settle — the only ones an operator
-- | needs to see. A `down` that worked should say nothing.
unsettledTeardowns :: SuperviseState -> Array (Tuple String TeardownRow)
unsettledTeardowns sv =
  Array.filter (not <<< _.settled <<< snd)
    (Object.toUnfoldable (fromMaybe Object.empty sv.teardown))

decodeSuperviseState :: Json -> Either String SuperviseState
decodeSuperviseState json = Group.readGroup json <#> \read ->
  { desired: read.desired
  , services: Object.fromFoldable read.services
  , supervised: read.supervised
  , supervision: Object.fromFoldable read.supervision
  , teardown: Object.fromFoldable <$> read.teardown
  }
