-- | WHO HOLDS A SERVICE'S PORT — owned versus merely observed.
-- |
-- | Found 2026-09-25 (docs/FINDINGS-restart-ok-on-orphan.md): a `restart` of
-- | `friends-of-itajara` answered `{"ok":true}` twice while a five-day-old
-- | process went on serving :3029. Bosun can only stop what it recorded
-- | launching; the process on the port was an orphan it had never launched, so
-- | the reap hit a dead pgid, the relaunch died on EADDRINUSE, and the TCP probe
-- | — which asks whether SOMETHING answers — found the old code answering and
-- | reported `running`. Every signal was true, and none of them measured whose
-- | process it was.
-- |
-- | This is the other face of the 2026-07-31 fix. Dropping `probe: process` for
-- | TCP services made supervise ADOPT an incumbent instead of relaunching into
-- | EADDRINUSE forever — and adoption without ownership is exactly a process the
-- | group observes and cannot restart.
-- |
-- | Same discipline as `Substrate`'s teardown: the shell gathers evidence
-- | (`holdingScript`), the pure core weighs it (`readHoldingEvidence` →
-- | `judgeHolding`), so the verdict is unit-testable and lowers to the Go column
-- | unchanged. The evidence is every LISTENER on the port — IPv4 and IPv6 both,
-- | because a split bind is how a week-old process kept serving :3040 while a
-- | fresh one bound beside it (2026-09-01).
module Bosun.Holding
  ( Pid
  , mkPid
  , unPid
  , Pgid
  , unPgid
  , Holder
  , HoldingEvidence
  , Holding(..)
  , holdingTag
  , tcpPorts
  , holdingScript
  , readHoldingEvidence
  , judgeHolding
  , strangers
  , describeHolder
  , holdingJson
  , ReapVerdict(..)
  , reapTag
  , reapScript
  , readReap
  , reapSettled
  , jsonString
  ) where

import Prelude

import Bosun.Atoms (Port, ServiceId, unPort, unServiceId)
import Bosun.Reachability (Address(..), Reachability, addresses)
import Bosun.Substrate (pidPath, shellQuote)
import Data.Array as A
import Data.Foldable (all, foldl, intercalate)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as S
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))

newtype Pid = Pid Int

derive instance Eq Pid
derive instance Ord Pid
derive newtype instance Show Pid

mkPid :: Int -> Pid
mkPid = Pid

unPid :: Pid -> Int
unPid (Pid n) = n

newtype Pgid = Pgid Int

derive instance Eq Pgid
derive instance Ord Pgid
derive newtype instance Show Pgid

unPgid :: Pgid -> Int
unPgid (Pgid n) = n

-- | One process listening on a service's port, as the host describes it.
-- | `started` is `ps -o lstart` verbatim — for a human, never compared.
type Holder =
  { pid :: Pid
  , pgid :: Pgid
  , started :: String
  , command :: String
  , cwd :: Maybe String
  }

-- | Everything one run of `holdingScript` established. `readable` is false when
-- | the shell never reached its end marker (or the host has no `lsof`), in
-- | which case nothing below it may be read as "nobody is listening".
type HoldingEvidence =
  { readable :: Boolean
  , listeners :: Map Int (Array Pid)
  , procs :: Map Pid Holder
  , recorded :: Map String Pgid
  , physical :: Map String String
  }

-- | Whose process is on the service's port.
-- |
-- | `Stranger` keeps our own listeners beside the strangers, because the
-- | split-bind case is both at once: our fresh launch on IPv4 and an orphan on
-- | IPv6, where the orphan is the one a browser reaches.
data Holding
  = NoPort
    -- ^ the service binds no TCP port; ownership is not a question for it
  | Unheld
    -- ^ nothing is listening on its port
  | Ours (Array Holder)
    -- ^ every listener is in the process group this supervisor recorded
  | Stranger { holders :: Array Holder, ours :: Array Holder, claimable :: Boolean }
    -- ^ something this group did not start holds the port. `claimable`: every
    -- such listener runs from the service's own registered directory, so it is
    -- (all but certainly) an earlier incarnation of this service
  | Unobservable String
    -- ^ cannot tell, and says why — never read as Unheld

holdingTag :: Holding -> String
holdingTag = case _ of
  NoPort -> "no-port"
  Unheld -> "none"
  Ours _ -> "ours"
  Stranger _ -> "stranger"
  Unobservable _ -> "unobservable"

-- | The TCP ports a service listens on — every one, not only the most exposed.
tcpPorts :: Reachability -> Array Port
tcpPorts r = A.mapMaybe portOf (Set.toUnfoldable (addresses r))
  where
  portOf = case _ of
    Listening l -> Just l.port
    _ -> Nothing

-- | The evidence-gathering shell line: one `lsof` over every port asked about
-- | (both address families), one `ps` and one cwd lookup over the pids it found,
-- | and for each named service its recorded pgid and the PHYSICAL form of its
-- | registered directory. `lsof` reports a process's cwd with every symlink
-- | resolved, so `/tmp/x` has to be compared as `/private/tmp/x` on macOS or a
-- | genuine earlier incarnation reads as foreign. Section markers let the reader
-- | tell "ran and found nobody" from "never ran".
holdingScript :: Array Port -> Array { sid :: ServiceId, cwd :: Maybe String } -> String
holdingScript ports svcs =
  intercalate "\n"
    [ "command -v lsof >/dev/null 2>&1 || { echo '#no-lsof'; exit 0; }"
    , "L=$(lsof -nP " <> intercalate " " (map (\p -> "-iTCP:" <> show (unPort p)) ports) <> " -sTCP:LISTEN -Fpn 2>/dev/null)"
    , "echo '#listen'; printf '%s\\n' \"$L\""
    , "P=$(printf '%s\\n' \"$L\" | sed -n 's/^p//p' | sort -u | paste -sd, -)"
    , "echo '#ps'; [ -n \"$P\" ] && ps -o pid=,pgid=,lstart=,command= -p \"$P\""
    , "echo '#cwd'; [ -n \"$P\" ] && lsof -a -d cwd -p \"$P\" -Fpn 2>/dev/null"
    , "echo '#recorded'"
    ]
    <> lines (map recordedLine svcs)
    <> "\necho '#physical'"
    <> lines (A.mapMaybe physicalLine svcs)
    <> "\necho '#end'"
  where
  lines xs = if A.null xs then "" else "\n" <> intercalate "\n" xs

  recordedLine svc =
    "printf '%s\\t%s\\n' " <> shellQuote (unServiceId svc.sid)
      <> " \"$(cat " <> pidPath svc.sid <> " 2>/dev/null)\""

  physicalLine svc = svc.cwd <#> \dir ->
    "printf '%s\\t%s\\n' " <> shellQuote (unServiceId svc.sid)
      <> " \"$(cd " <> shellQuote dir <> " 2>/dev/null && pwd -P)\""

-- | Weigh what the shell printed.
readHoldingEvidence :: { ran :: Boolean, output :: String } -> HoldingEvidence
readHoldingEvidence { ran, output } =
  if not ran || not (A.elem "#end" ls) then unreadable
  else
    { readable: true
    , listeners: listenersOf (section "#listen")
    , procs: foldl addCwd procTable (cwdPairs (section "#cwd"))
    , recorded: Map.fromFoldable (A.mapMaybe recordedOf (section "#recorded"))
    , physical: Map.fromFoldable (A.mapMaybe physicalOf (section "#physical"))
    }
  where
  ls = map S.trim (S.split (Pattern "\n") output)

  unreadable = { readable: false, listeners: Map.empty, procs: Map.empty, recorded: Map.empty, physical: Map.empty }

  section marker =
    case A.elemIndex marker ls of
      Nothing -> []
      Just i -> A.takeWhile (not <<< isMarker) (A.drop (i + 1) ls)

  isMarker l = S.take 1 l == "#"

  procTable = Map.fromFoldable (map (\h -> Tuple h.pid h) (A.mapMaybe psRow (section "#ps")))

  addCwd m (Tuple pid dir) = Map.update (\h -> Just h { cwd = Just dir }) pid m

  recordedOf l = case S.split (Pattern "\t") l of
    [ sid, n ] -> map (\g -> Tuple sid (Pgid g)) (positive n)
    _ -> Nothing

  physicalOf l = case S.split (Pattern "\t") l of
    [ sid, dir ] | dir /= "" -> Just (Tuple sid dir)
    _ -> Nothing

-- `lsof -F` emits a `p<pid>` line opening each process set, then one line per
-- field of each open file; only `n` (the name, `*:3029` / `[::1]:3029`) is
-- wanted here. The port is whatever follows the last colon.
listenersOf :: Array String -> Map Int (Array Pid)
listenersOf = _.acc <<< foldl step { cur: Nothing, acc: Map.empty }
  where
  step st l = case SCU.take 1 l of
    "p" -> st { cur = map Pid (positive (SCU.drop 1 l)) }
    "n" -> case st.cur, portAfterColon (SCU.drop 1 l) of
      Just pid, Just port -> st { acc = Map.alter (Just <<< addOnce pid <<< fromMaybe []) port st.acc }
      _, _ -> st
    _ -> st
  addOnce pid xs = if A.elem pid xs then xs else A.snoc xs pid

portAfterColon :: String -> Maybe Int
portAfterColon s = do
  i <- S.lastIndexOf (Pattern ":") s
  Int.fromString (S.drop (i + 1) s)

-- `ps -o pid=,pgid=,lstart=,command=`: two numbers, a five-token date, then the
-- command, which may itself contain spaces.
psRow :: String -> Maybe Holder
psRow l = case A.filter (_ /= "") (S.split (Pattern " ") l) of
  toks | A.length toks >= 8 -> do
    pid <- A.index toks 0 >>= positive
    pgid <- A.index toks 1 >>= positive
    pure
      { pid: Pid pid
      , pgid: Pgid pgid
      , started: intercalate " " (A.slice 2 7 toks)
      , command: intercalate " " (A.drop 7 toks)
      , cwd: Nothing
      }
  _ -> Nothing

cwdPairs :: Array String -> Array (Tuple Pid String)
cwdPairs = _.acc <<< foldl step { cur: Nothing, acc: [] }
  where
  step st l = case SCU.take 1 l of
    "p" -> st { cur = map Pid (positive (SCU.drop 1 l)) }
    "n" -> case st.cur of
      Just pid -> st { acc = A.snoc st.acc (Tuple pid (SCU.drop 1 l)) }
      Nothing -> st
    _ -> st

positive :: String -> Maybe Int
positive s = case Int.fromString (S.trim s) of
  Just n | n > 1 -> Just n
  _ -> Nothing

-- | Judge one service against the evidence. A listener is OURS when its process
-- | group is the one this supervisor recorded for the service; anything else on
-- | the port is a stranger. A stranger is CLAIMABLE only if it runs from the
-- | service's registered directory — the condition under which stopping it is
-- | replacing this service rather than killing whatever happened to hold a port,
-- | which in general is the wrong reflex.
judgeHolding
  :: HoldingEvidence
  -> { sid :: ServiceId, ports :: Array Port, cwd :: Maybe String }
  -> Holding
judgeHolding ev svc
  | A.null svc.ports = NoPort
  | not ev.readable = Unobservable "the port lookup did not complete (is lsof installed?)"
  | otherwise =
      case A.partition isOurs holders of
        { yes: [], no: [] } -> Unheld
        { yes, no: [] } -> Ours yes
        { yes, no } -> Stranger { holders: no, ours: yes, claimable: all fromHere no }
  where
  pids = A.nub (A.concatMap (\p -> fromMaybe [] (Map.lookup (unPort p) ev.listeners)) svc.ports)

  holders = A.mapMaybe (\pid -> Map.lookup pid ev.procs) pids

  recorded = Map.lookup (unServiceId svc.sid) ev.recorded

  isOurs h = Just h.pgid == recorded

  -- The physical form when the host could resolve it, else the registered
  -- string: a directory that no longer exists still names where the service
  -- was meant to run.
  want = case Map.lookup (unServiceId svc.sid) ev.physical of
    Just dir -> Just dir
    Nothing -> svc.cwd

  fromHere h = case want, h.cwd of
    Just w, Just have -> sameDir w have
    _, _ -> false

sameDir :: String -> String -> Boolean
sameDir a b = norm a == norm b
  where
  norm s = if S.length s > 1 then fromMaybe s (S.stripSuffix (Pattern "/") s) else s

-- | The strangers, if any.
strangers :: Holding -> Array Holder
strangers = case _ of
  Stranger s -> s.holders
  _ -> []

-- | One holder, for a sentence: "pid 94743 (node server.mjs, since Sun Sep 20
-- | 11:34:15 2026, in /…/friends-of-itajara)".
describeHolder :: Holder -> String
describeHolder h =
  "pid " <> show (unPid h.pid)
    <> " (" <> h.command
    <> ", since " <> h.started
    <> maybeIn h.cwd
    <> ")"
  where
  maybeIn = case _ of
    Just d -> ", in " <> d
    Nothing -> ""

-- | The `/state` form. ADDITIVE: the `services` map keeps its status words, so
-- | every existing decoder reads it unchanged, and this says whose process the
-- | status is about — which is the whole of acceptance criterion 3.
holdingJson :: Holding -> String
holdingJson h =
  "{ \"verdict\": " <> jsonString (holdingTag h) <> fields <> " }"
  where
  fields = case h of
    Ours hs -> ", \"pids\": " <> pidList hs
    Stranger s ->
      ", \"claimable\": " <> (if s.claimable then "true" else "false")
        <> ", \"pids\": " <> pidList s.holders
        <> ", \"ours\": " <> pidList s.ours
        <> ", \"detail\": " <> jsonString (intercalate "; " (map describeHolder s.holders))
    Unobservable why -> ", \"detail\": " <> jsonString why
    _ -> ""
  pidList hs = "[" <> intercalate ", " (map (show <<< unPid <<< _.pid) hs) <> "]"

-- | A JSON string literal. The hand-built `/state` never needed one while every
-- | value was an identifier; a command line or a path can hold anything.
jsonString :: String -> String
jsonString s = "\"" <> foldl (\acc c -> acc <> esc c) "" (SCU.toCharArray s) <> "\""
  where
  esc = case _ of
    '"' -> "\\\""
    '\\' -> "\\\\"
    '\n' -> "\\n"
    '\r' -> "\\r"
    '\t' -> "\\t"
    c | c < ' ' -> ""
    c -> SCU.singleton c

-- ── replacing a claimable stranger ───────────────────────────────────────────

-- | What stopping one stranger established. Same shape as the teardown
-- | taxonomy, trimmed to what can happen to a process we did not launch.
data ReapVerdict
  = StrangerReaped    -- ^ signalled, and it is gone
  | StrangerGone      -- ^ already gone by the time we looked
  | StrangerRefused   -- ^ the kernel would not deliver the signal (not ours to kill)
  | StrangerSurvived  -- ^ still alive after TERM, the release window, and KILL
  | ReapUnreadable    -- ^ the script said nothing about it

derive instance Eq ReapVerdict

instance Show ReapVerdict where
  show = reapTag

reapTag :: ReapVerdict -> String
reapTag = case _ of
  StrangerReaped -> "reaped"
  StrangerGone -> "already-gone"
  StrangerRefused -> "refused"
  StrangerSurvived -> "survived"
  ReapUnreadable -> "unreadable"

-- | Did it establish that the port's old holder is gone?
reapSettled :: ReapVerdict -> Boolean
reapSettled = case _ of
  StrangerReaped -> true
  StrangerGone -> true
  _ -> false

-- | Stop each stranger: TERM its process group, wait up to 5s, KILL if it is
-- | still there, and say which. Two guards, because this signals a group Bosun
-- | never recorded: a pgid of 0 or 1 is never signalled, and a stranger that
-- | shares THIS supervisor's own group is signalled by pid alone — otherwise
-- | replacing it would take the supervisor down with it.
reapScript :: Array Holder -> String
reapScript hs =
  intercalate "\n" ([ "me=$(ps -o pgid= -p $PPID | tr -d ' ')" ] <> map one hs)
  where
  one h =
    let
      p = show (unPid h.pid)
      g = show (unPgid h.pgid)
      tok v = "echo 'bosun-reap:" <> p <> ":" <> v <> "'"
      alive = "ps -p " <> p <> " >/dev/null 2>&1"
      target = "$( [ " <> g <> " -gt 1 ] && [ \"" <> g <> "\" != \"$me\" ] && echo -" <> g <> " || echo " <> p <> " )"
    in
      "t=" <> target <> "; "
        <> "if ! " <> alive <> "; then " <> tok "already-gone" <> "; "
        <> "elif ! kill -TERM -- \"$t\" 2>/dev/null; then " <> tok "refused" <> "; "
        <> "else i=0; while " <> alive <> " && [ \"$i\" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; "
        <> alive <> " && { kill -KILL -- \"$t\" 2>/dev/null; sleep 0.5; }; "
        <> "if " <> alive <> "; then " <> tok "survived" <> "; else " <> tok "reaped" <> "; fi; fi"

-- | Read the verdict for each stranger back out of what the script printed.
readReap :: String -> Array Holder -> Array (Tuple Holder ReapVerdict)
readReap output = map (\h -> Tuple h (verdictFor (show (unPid h.pid))))
  where
  ls = map S.trim (S.split (Pattern "\n") output)
  verdictFor p = case A.findMap (S.stripPrefix (Pattern ("bosun-reap:" <> p <> ":"))) ls of
    Just "reaped" -> StrangerReaped
    Just "already-gone" -> StrangerGone
    Just "refused" -> StrangerRefused
    Just "survived" -> StrangerSurvived
    _ -> ReapUnreadable
