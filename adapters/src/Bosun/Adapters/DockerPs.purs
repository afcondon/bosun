-- | The ingestion edge for a Docker substrate's observation (docs/EXECUTORS.md).
-- |
-- | Where `Compose`/`Registry` parse *desired* config, this parses *observed*
-- | reality: the JSON `docker inspect` prints, turned into a per-service
-- | `ContainerObs` (status for the planner + a `HealthVerdict` for the Chair's
-- | badge). It is the Docker analog of the process supervisor's pgid reading —
-- | but Docker supplies honest readiness for free via the container `Health`
-- | block, the very signal the rig daemons lacked.
-- |
-- | We observe one `inspect` deeper than `docker compose ps` on purpose: `ps`
-- | collapses the healthcheck to a single `Health` string, so a check that
-- | **could not run** (the binary is missing — `ExitCode: -1`,
-- | `"executable file not found"`) is indistinguishable from a service that is
-- | genuinely **unhealthy** (the check ran and returned non-zero). The
-- | `.State.Health.Log[]` entries — only in `inspect` — carry the exit code and
-- | output that tell them apart. A broken check yields **no readiness signal**,
-- | so the container honestly degrades to the no-healthcheck case (liveness IS
-- | readiness ⇒ `Running`) rather than being false-redded as `Failed`; the
-- | distinct `CheckError` verdict lets the Chair show "⚠ check misconfigured"
-- | over a live service instead of a spurious red.
-- |
-- | Pure on purpose: the ssh round-trip lives in the CLI (`Bosun.CLI.Docker`),
-- | but the *decision* `container → ContainerObs` is total and pinnable to the
-- | node≡Go conformance discipline (it is real classification logic, the kind
-- | EXECUTORS.md says to conformance-pin).
module Bosun.Adapters.DockerPs
  ( HealthVerdict(..)
  , ContainerObs
  , healthVerdictToken
  , classifyInspect
  , parseDockerInspect
  ) where

import Prelude

import Bosun.Atoms (ServiceId)
import Bosun.Plan (Status(..))
import Data.Argonaut.Core (Json, fromObject, toArray, toNumber, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as A
import Data.Either (either)
import Data.Foldable (any)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as FO

-- | The healthcheck verdict, with the distinction `ps` cannot make: a check that
-- | **could not run** (`CheckError`) versus one that ran and failed
-- | (`Unhealthy`). `NoCheck` is "no healthcheck declared"; `NotRunning` is the
-- | display verdict for a stopped/absent container.
data HealthVerdict
  = Healthy
  | Unhealthy
  | CheckError
  | HStarting
  | NoCheck
  | NotRunning

derive instance Eq HealthVerdict

-- | The `/state` health token (the value of `supervision.<id>.health`). Adding
-- | `"check-error"` / `"none"` is additive — a new *value* in an existing string
-- | field, not a new key — so the Chair's decoder is unaffected (it can switch on
-- | the value when it wants the badge, or display it verbatim until then).
healthVerdictToken :: HealthVerdict -> String
healthVerdictToken = case _ of
  Healthy -> "healthy"
  Unhealthy -> "unhealthy"
  CheckError -> "check-error"
  HStarting -> "starting"
  NoCheck -> "none"
  NotRunning -> "down"

-- | What the observer caches per service: the planner-facing `status` and the
-- | Chair-facing `health` verdict. (The planner only ever sees `_.status`; the
-- | richer `health` rides the additive `/state` `supervision` field.)
type ContainerObs = { status :: Status, health :: HealthVerdict }

-- | `(container State.Status, health verdict) → ContainerObs`. A `running`
-- | container's status is decided by its readiness verdict; a broken check
-- | (`CheckError`) or no check (`NoCheck`) both fall back to liveness-is-
-- | readiness (`Running`), never `Failed` — we do not over-claim health, but we
-- | also do not false-red a live service whose *check* is the thing that's
-- | broken. An unhealthy check that genuinely ran ⇒ `Failed` (Docker's own
-- | `restart:` policy relaunches it — Bosun reports, does not act). Anything
-- | unrecognised is `Down` (PRINCIPLES.md — never silently `Running`).
classifyInspect :: { state :: String, rawHealth :: HealthVerdict } -> ContainerObs
classifyInspect { state, rawHealth } = case state of
  "running" -> { status: runningStatus, health: rawHealth }
  "restarting" -> { status: Starting, health: HStarting }
  "exited" -> down
  "created" -> down
  "paused" -> down
  "dead" -> { status: Failed, health: NotRunning }
  _ -> down
  where
  down = { status: Down, health: NotRunning }
  runningStatus = case rawHealth of
    Healthy -> Running
    NoCheck -> Running
    CheckError -> Running          -- broken check ⇒ no readiness signal ⇒ liveness IS readiness
    HStarting -> Starting
    Unhealthy -> Failed
    NotRunning -> Running

-- | Parse `docker inspect … --format "{{json .}}"` (one full container object per
-- | line; the single-array form is also tolerated) into a `Map ServiceId
-- | ContainerObs`. The compose service name lives in the container's
-- | `.Config.Labels["com.docker.compose.service"]` label; it bridges docker's
-- | container to Bosun's reconciled id via `names`. Every known service is seeded
-- | as a stopped container, then overridden by what `inspect` reports — so a
-- | container absent from the output (never created, or removed) honestly reads
-- | `Down`, and the `/state` map always covers the whole deployment.
parseDockerInspect :: Map String ServiceId -> String -> Map ServiceId ContainerObs
parseDockerInspect names out = Map.union observed baseDown
  where
  baseDown = Map.fromFoldable (map (\sid -> Tuple sid down) (A.fromFoldable (Map.values names)))
  observed = Map.fromFoldable (A.mapMaybe entry (parseObjs out))
  down = { status: Down, health: NotRunning }

  entry :: Object Json -> Maybe (Tuple ServiceId ContainerObs)
  entry container = do
    svc <- dig [ "Config", "Labels", "com.docker.compose.service" ] container >>= toString
    sid <- Map.lookup svc names
    let
      state = fromMaybe "" (dig [ "State", "Status" ] container >>= toString)
      rawHealth = healthOf (dig [ "State", "Health" ] container >>= toObject)
    pure (Tuple sid (classifyInspect { state, rawHealth }))

-- | Navigate a path of object keys from a starting object, returning the `Json`
-- | reached (or `Nothing` if any key is missing or a step is not an object).
dig :: Array String -> Object Json -> Maybe Json
dig keys o = case A.uncons keys of
  Nothing -> Just (fromObject o)
  Just { head, tail } -> FO.lookup head o >>= digJson tail

digJson :: Array String -> Json -> Maybe Json
digJson keys j = case A.uncons keys of
  Nothing -> Just j
  Just { head, tail } -> toObject j >>= FO.lookup head >>= digJson tail

-- | Reduce a container's `.State.Health` block to a `HealthVerdict`. Absent ⇒
-- | `NoCheck`. Present: docker's aggregate `Status` decides, except that an
-- | `unhealthy` whose **last** log entry shows the probe could not be executed
-- | (`ExitCode: -1`, or output naming a missing executable) is reclassified
-- | `CheckError` — the check is broken, not the service.
healthOf :: Maybe (Object Json) -> HealthVerdict
healthOf Nothing = NoCheck
healthOf (Just h) = case fromMaybe "" (FO.lookup "Status" h >>= toString) of
  "healthy" -> Healthy
  "starting" -> HStarting
  "unhealthy" -> if lastLogIsExecError h then CheckError else Unhealthy
  _ -> NoCheck

-- | Did the most recent healthcheck *fail to run* (as opposed to run and fail)?
-- | `ExitCode == -1` is docker's sentinel for "the probe could not be executed";
-- | the output substrings corroborate the missing-binary case the Chair found
-- | live (`exec: "curl": executable file not found in $PATH`).
lastLogIsExecError :: Object Json -> Boolean
lastLogIsExecError h = maybe false fromEntry lastEntry
  where
  lastEntry = (FO.lookup "Log" h >>= toArray) >>= A.last >>= toObject
  fromEntry entry =
    (FO.lookup "ExitCode" entry >>= toNumber) == Just (-1.0)
      || execNotFound (fromMaybe "" (FO.lookup "Output" entry >>= toString))
  execNotFound out = any (\m -> String.contains (Pattern m) out) execErrorMarkers

execErrorMarkers :: Array String
execErrorMarkers = [ "executable file not found", "no such file or directory" ]

-- Split the output into lines, parse each non-blank line, and expand any line
-- that is a JSON array into its element objects (so both the NDJSON
-- `--format "{{json .}}"` form and a plain single-array `inspect` yield a flat
-- `Array (Object Json)`).
parseObjs :: String -> Array (Object Json)
parseObjs out =
  A.filter (not <<< String.null <<< String.trim) (String.split (Pattern "\n") out)
    # A.mapMaybe (\l -> either (const Nothing) Just (jsonParser l))
    # A.concatMap expand
  where
  expand j = case toArray j of
    Just arr -> A.mapMaybe toObject arr
    Nothing -> maybe [] pure (toObject j)
