-- | `/state`, as the router says it: described once.
-- |
-- | `bosun serve` answers `GET /state` with a document of its own. It is not
-- | a group document (`Bosun.Protocol.State`): a router has routes, not
-- | supervised services, and most of what it reports (a port it could not
-- | bind, a service it refused, a registry row it has not seen) has no place
-- | in a group.
-- |
-- | The router is written in JavaScript (`cli/src/Bosun/CLI/Serve.js`) and
-- | builds this document there, so unlike the group document it is not
-- | PRINTED through this description. It is READ through it: by the Chair,
-- | and by a test that reads a document the running router answered
-- | (`protocol/vectors/serve-state/`). When the router moves to PureScript on
-- | the BEAM, it prints through this too.
-- |
-- | Every record is open, for the reason the group document's are: a reader
-- | built before a field was added must still read the document.
module Bosun.Protocol.ServeState
  ( ServeState
  , Route
  , Brokered
  , Redirect
  , Rejected
  , Drift
  , Registry
  , serveState
  , readServeState
  , document
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Json
import Data.Either (Either, note)
import Data.Maybe (Maybe)
import Data.String as String
import Hawser.Document as Document
import Hawser.Message (Message(..), Shape(..), field, message, openRecordOf, optional)
import Hawser.Value (Value, arrayOf, boolean, string, whole)

-- | The whole document.
type ServeState =
  { routes :: Array Route
  , redirects :: Array Redirect
  , rejected :: Array Rejected
  , brokered :: Maybe (Array Brokered)
  , drift :: Maybe (Array Drift)
  , stale :: Maybe Boolean
  , registry :: Maybe Registry
  }

-- | One lazy-spawn route as the router finds it now.
type Route =
  { serviceId :: String
  , publicPort :: Int
  , internalPort :: Int
  , up :: Boolean
  , pid :: Maybe Int
  , external :: Maybe Boolean
  , externalCheckedAt :: Maybe String
  , adoptedBackend :: Maybe Boolean
  , adoptedBackendAt :: Maybe String
  , bound :: Maybe Boolean
  , bindError :: Maybe String
  }

-- | One brokered service: the router says where it is and does not carry
-- | its traffic.
type Brokered =
  { serviceId :: String
  , publicPort :: Maybe Int
  , at :: Maybe String
  , url :: Maybe String
  , transport :: Maybe String
  , probe :: Maybe String
  , pid :: Maybe Int
  , bound :: Maybe Boolean
  , bindError :: Maybe String
  , door :: Maybe String
  , doorCheckedAt :: Maybe String
  }

-- | A port answered with a redirect to another host.
type Redirect = { serviceId :: String, publicPort :: Int, host :: String, target :: String }

-- | A service the router saw and cannot use.
type Rejected = { serviceId :: String, publicPort :: Maybe Int, reason :: String }

-- | A port where the registry on disk and the router's plan disagree.
type Drift = { serviceId :: String, publicPort :: Int, kind :: String, note :: String }

-- | Where the router's plan came from, and when.
type Registry =
  { source :: String
  , plannedAt :: Maybe String
  , modifiedAt :: Maybe String
  , error :: Maybe String
  }

-- | A time as the router writes it: ISO 8601 text, such as
-- | `2026-11-17T09:23:18.311Z`. (The group document writes milliseconds.)
moment :: Value String
moment = string

stateMessage :: Message ServeState
stateMessage = message "router state" "The router, as it finds itself now." $
  { routes: _, redirects: _, rejected: _, brokered: _, drift: _, stale: _, registry: _ }
    <$> field "routes" _.routes (arrayOf route) "the lazy-spawn routes"
    <*> field "redirects" _.redirects (arrayOf redirect) "ports answered with a redirect to another host"
    <*> field "rejected" _.rejected (arrayOf rejected) "services the router saw and cannot use"
    <*> optional "brokered" _.brokered (arrayOf brokered) "services the router locates and does not carry"
    <*> optional "drift" _.drift (arrayOf drift) "ports where the registry on disk and the router's plan disagree. Empty means none; when `registry.error` is set it is the last answer, not a current one"
    <*> optional "stale" _.stale boolean "true when `drift` is not empty"
    <*> optional "registry" _.registry registry "where the plan came from"

routeMessage :: Message Route
routeMessage = message "route" "One lazy-spawn route." $
  { serviceId: _, publicPort: _, internalPort: _, up: _, pid: _, external: _, externalCheckedAt: _, adoptedBackend: _, adoptedBackendAt: _, bound: _, bindError: _ }
    <$> field "serviceId" _.serviceId string "the service, as the registry names it"
    <*> field "publicPort" _.publicPort whole "the registered port, which the router listens on"
    <*> field "internalPort" _.internalPort whole "the port the backend is launched on"
    <*> field "up" _.up boolean "true when something is serving this route: a backend the router started, one it relays to, or an outside process holding the public port"
    <*> optional "pid" _.pid whole "the backend's process, when the router started it"
    <*> optional "external" _.external boolean "true when a process the router did not start holds the public port itself"
    <*> optional "externalCheckedAt" _.externalCheckedAt moment "when that was last probed"
    <*> optional "adoptedBackend" _.adoptedBackend boolean "true when the router relays to a backend it did not start, so there is no `pid` and no idle stop"
    <*> optional "adoptedBackendAt" _.adoptedBackendAt moment "when that was last probed"
    <*> optional "bound" _.bound boolean "true when the router holds the public port. False and not `external` means nothing is listening, so no request can arrive"
    <*> optional "bindError" _.bindError string "why the router could not bind the port"

brokeredMessage :: Message Brokered
brokeredMessage = message "brokered service" "A service the router locates and does not carry." $
  { serviceId: _, publicPort: _, at: _, url: _, transport: _, probe: _, pid: _, bound: _, bindError: _, door: _, doorCheckedAt: _ }
    <$> field "serviceId" _.serviceId string "the service"
    <*> optional "publicPort" _.publicPort whole "its registered port. Often absent, which is normal: a socket or a UDP service has none"
    <*> optional "at" _.at string "where it is, once running"
    <*> optional "url" _.url string "the same as a URL, when it has one"
    <*> optional "transport" _.transport string "how it is reached, such as `http` or `unix`"
    <*> optional "probe" _.probe string "which readiness check the plan chose. `none` means nothing was checked, not that a check failed"
    <*> optional "pid" _.pid whole "its process, when the router started it"
    <*> optional "bound" _.bound boolean "true when the router holds the registered port to answer with a redirect"
    <*> optional "bindError" _.bindError string "why the router could not bind that port"
    <*> optional "door" _.door string "the standing of that listener: `none`, `open`, `aside`, `reclaim` or `blocked`"
    <*> optional "doorCheckedAt" _.doorCheckedAt moment "when that was last probed"

redirectMessage :: Message Redirect
redirectMessage = message "redirect" "A port answered with a redirect to another host." $
  { serviceId: _, publicPort: _, host: _, target: _ }
    <$> field "serviceId" _.serviceId string "the service"
    <*> field "publicPort" _.publicPort whole "the port that redirects"
    <*> field "host" _.host string "the host the service runs on"
    <*> field "target" _.target string "where the redirect sends a request"

rejectedMessage :: Message Rejected
rejectedMessage = message "refusal" "A service the router saw and cannot use." $
  { serviceId: _, publicPort: _, reason: _ }
    <$> field "serviceId" _.serviceId string "the service"
    <*> optional "publicPort" _.publicPort whole "the port it asked for"
    <*> field "reason" _.reason string "why, as a sentence"

driftMessage :: Message Drift
driftMessage = message "drift entry" "A port where the registry on disk and the router's plan disagree." $
  { serviceId: _, publicPort: _, kind: _, note: _ }
    <$> field "serviceId" _.serviceId string "the service"
    <*> field "publicPort" _.publicPort whole "the port"
    <*> field "kind" _.kind string "`unrouted`, `altered` or `departed`"
    <*> field "note" _.note string "the disagreement, as a sentence"

registryMessage :: Message Registry
registryMessage = message "registry" "Where the router's plan came from, and when." $
  { source: _, plannedAt: _, modifiedAt: _, error: _ }
    <$> field "source" _.source string "the registry file"
    <*> optional "plannedAt" _.plannedAt moment "when the router last planned from it"
    <*> optional "modifiedAt" _.modifiedAt moment "when the file last changed"
    <*> optional "error" _.error string "why the drift check could not be made. When set, `drift` and `stale` are not current"

route :: Value Route
route = openOf routeMessage

brokered :: Value Brokered
brokered = openOf brokeredMessage

redirect :: Value Redirect
redirect = openOf redirectMessage

rejected :: Value Rejected
rejected = openOf rejectedMessage

drift :: Value Drift
drift = openOf driftMessage

registry :: Value Registry
registry = openOf registryMessage

-- | The document as a value.
serveState :: Value ServeState
serveState = openOf stateMessage

openOf :: forall r. Message r -> Value r
openOf (Message { name, shape }) = openRecordOf name shape

-- | Read the router's document from parsed JSON, with the reason when it
-- | cannot be read: the first top-level field that is missing or wrong.
readServeState :: Json -> Either String ServeState
readServeState json = do
  object <- note "not a JSON object" (Json.toObject json)
  let Message { shape: Shape shape } = stateMessage
  shape.fromJson object

-- | The tables of `protocol/STATE.md`'s router section.
document :: String
document = String.joinWith "\n\n"
  [ section stateMessage
  , section routeMessage
  , section brokeredMessage
  , section redirectMessage
  , section rejectedMessage
  , section driftMessage
  , section registryMessage
  ]
  where
  section :: forall r. Message r -> String
  section (Message { name, meaning, shape: Shape shape }) =
    "### The " <> name <> "\n\n" <> meaning <> "\n\n"
      <> Document.tableWith [ "Field", "Holds", "Meaning" ]
        (shape.fields <#> \described -> "| `" <> described.key <> "` | " <> described.says <> " | " <> described.meaning <> " |")
