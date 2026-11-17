-- | `/state`, as a group supervisor says it: described once.
-- |
-- | `bosun supervise` answers `GET /state` with one JSON document. Until
-- | 2026-11-16 the daemon built it by joining strings and each reader
-- | declared its own idea of the shape. This module is the one description:
-- | the daemon prints through it (`printState`), a PureScript reader reads
-- | through it (`readState`), and `protocol/STATE.md` is generated from it
-- | (`document`).
-- |
-- | Two properties of this wire decide how it is described.
-- |
-- | **It may grow.** Supervisors on different machines are not updated
-- | together, and one Chair reads them all. So every record here is an open
-- | record (`Hawser.Message.openRecordOf`): a reader takes the fields it
-- | knows and ignores the rest, and adding a field breaks no reader. Taking
-- | a field away, or changing what one holds, does.
-- |
-- | **Its bytes are read by shell scripts.** `printState` keeps the spacing
-- | the hand-built document had (`{ "desired": "up", ... }`), so anything
-- | that greps for `"restarts": 0` still matches. One thing changed on
-- | purpose: a time is printed as a whole number of milliseconds
-- | (`1794690259979`), where JavaScript's `show` wrote `1794690259979.0` and
-- | the BEAM's wrote `1.79469025997900000000e+12`.
-- |
-- | The words a field can hold (`running`, `reaped`, `ours`) are strings
-- | here, not constructors, for the first reason: a reader must be able to
-- | carry a word that a newer supervisor invented.
module Bosun.Protocol.State
  ( StateDoc
  , Supervision
  , Teardown
  , Holder
  , stateDoc
  , supervision
  , teardown
  , holder
  , printState
  , printHolder
  , readState
  , spaced
  , document
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Json
import Data.Maybe (Maybe)
import Data.String as String
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import Hawser.Document as Document
import Hawser.Message (Message(..), Shape(..), field, message, openRecordOf, optional)
import Hawser.Value (Value(..), arrayOf, boolean, fromText, named, nullable, number, string, tableOf, whole)

-- | The whole document. `services` and the three tables beside it are keyed
-- | by service id, in the order the supervisor holds them.
type StateDoc =
  { desired :: String
  , phase :: String
  , supervised :: Boolean
  , services :: Array (Tuple String String)
  , supervision :: Array (Tuple String Supervision)
  , teardown :: Maybe (Array (Tuple String Teardown))
  , holders :: Maybe (Array (Tuple String Holder))
  }

-- | What the supervisor has done about one service.
type Supervision =
  { restarts :: Int
  , fails :: Int
  , lastTransitionAt :: Number
  , suspendedUntil :: Maybe Number
  , retryCap :: Maybe Int
  , gaveUp :: Boolean
  }

-- | What the last `down` established about one service.
type Teardown = { verdict :: String, settled :: Boolean, at :: Number }

-- | Whose process is listening on one service's port.
type Holder =
  { verdict :: String
  , claimable :: Maybe Boolean
  , pids :: Maybe (Array Int)
  , ours :: Maybe (Array Int)
  , detail :: Maybe String
  }

-- | A time: milliseconds since 1970, a whole number.
time :: Value Number
time = named "time in ms" number

stateMessage :: Message StateDoc
stateMessage = message "state" "The group, as its supervisor sees it now." $
  { desired: _, phase: _, supervised: _, services: _, supervision: _, teardown: _, holders: _ }
    <$> field "desired" _.desired string "`up` or `down`: whether the supervisor is keeping the group up. Follows from `phase`"
    <*> field "phase" _.phase string "the state of the group's lifecycle machine (`machines/supervise-group.json`), such as `raised` or `held`"
    <*> field "supervised" _.supervised boolean "always true: this is a supervisor, not `bosun serve`"
    <*> field "services" _.services (tableOf string) "each service's status: `running`, `starting`, `in-backoff`, `failed`, `down`, `completed-ok` or `unknown`"
    <*> field "supervision" _.supervision (tableOf supervision) "each service's supervision row"
    <*> optional "teardown" _.teardown (tableOf teardown) "what the last `down` found, per service. Left out when there is nothing to say"
    <*> optional "holders" _.holders (tableOf holder) "who holds each service's TCP port. Services with no port are left out, and so is the field when none has one"

supervisionMessage :: Message Supervision
supervisionMessage = message "supervision row" "What the supervisor has done about one service." $
  { restarts: _, fails: _, lastTransitionAt: _, suspendedUntil: _, retryCap: _, gaveUp: _ }
    <$> field "restarts" _.restarts whole "how many times it has been relaunched"
    <*> field "fails" _.fails whole "failures in a row since it last ran well"
    <*> field "lastTransitionAt" _.lastTransitionAt time "when its status last changed"
    <*> field "suspendedUntil" _.suspendedUntil (nullable time) "while backing off, when the next try is due"
    <*> field "retryCap" _.retryCap (nullable whole) "the most failures in a row before the supervisor stops trying, where the service sets one"
    <*> field "gaveUp" _.gaveUp boolean "true when `fails` has reached `retryCap`: nothing more happens until someone restarts it"

teardownMessage :: Message Teardown
teardownMessage = message "teardown row" "What the last `down` established about one service." $
  { verdict: _, settled: _, at: _ }
    <$> field "verdict" _.verdict string "`reaped`, `killed`, `already-gone`, `no-record`, `survived`, `refused` or `unreadable`"
    <*> field "settled" _.settled boolean "true when the verdict establishes that the service is down: `reaped`, `killed` or `already-gone`"
    <*> field "at" _.at time "when it was judged"

holderMessage :: Message Holder
holderMessage = message "holder row" "Whose process is listening on one service's port." $
  { verdict: _, claimable: _, pids: _, ours: _, detail: _ }
    <$> field "verdict" _.verdict string "`ours`, `stranger`, `none` or `unobservable`"
    <*> optional "claimable" _.claimable boolean "for a stranger: true when it runs from the service's own directory, so a restart may replace it"
    <*> optional "pids" _.pids (arrayOf whole) "the processes listening"
    <*> optional "ours" _.ours (arrayOf whole) "for a stranger: listeners this supervisor did start, beside it"
    <*> optional "detail" _.detail string "who the stranger is, or why the port could not be read"

-- | The document as a value. Open: see the module comment.
stateDoc :: Value StateDoc
stateDoc = openOf stateMessage

supervision :: Value Supervision
supervision = openOf supervisionMessage

teardown :: Value Teardown
teardown = openOf teardownMessage

holder :: Value Holder
holder = openOf holderMessage

openOf :: forall r. Message r -> Value r
openOf (Message { name, shape }) = openRecordOf name shape

-- | The document as the daemon answers it.
printState :: StateDoc -> String
printState = printWith stateDoc

-- | One holder row, as it appears inside the document.
printHolder :: Holder -> String
printHolder = printWith holder

printWith :: forall a. Value a -> a -> String
printWith (Value value) = value.toJson >>> spaced

-- | Read a document. `Nothing` when it is not JSON, lacks a described field,
-- | or holds a value of another type in one. Undescribed fields are ignored.
readState :: String -> Maybe StateDoc
readState = fromText stateDoc

-- | JSON in the spacing `/state` has always had: `{ "a": 1, "b": [2, 3] }`,
-- | and `{  }` for an empty object. Strings and numbers are argonaut's.
spaced :: Json -> String
spaced = Json.caseJson
  (const "null")
  (if _ then "true" else "false")
  (Json.fromNumber >>> Json.stringify)
  (Json.fromString >>> Json.stringify)
  (\items -> "[" <> String.joinWith ", " (map spaced items) <> "]")
  ( \object ->
      "{ "
        <> String.joinWith ", "
          ( (Object.toUnfoldable object :: Array (Tuple String Json)) <#> \(Tuple key item) ->
              Json.stringify (Json.fromString key) <> ": " <> spaced item
          )
        <> " }"
  )

-- | The tables of `protocol/STATE.md`, one for each record.
document :: String
document = String.joinWith "\n\n"
  [ section stateMessage
  , section supervisionMessage
  , section teardownMessage
  , section holderMessage
  ]
  where
  section :: forall r. Message r -> String
  section (Message { name, meaning, shape: Shape shape }) =
    "### The " <> name <> "\n\n" <> meaning <> "\n\n"
      <> Document.tableWith [ "Field", "Holds", "Meaning" ]
        (shape.fields <#> \described -> "| `" <> described.key <> "` | " <> described.says <> " | " <> described.meaning <> " |")
