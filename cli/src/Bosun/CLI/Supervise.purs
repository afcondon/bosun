-- | `bosun supervise <compose> <registry>` — the resident keep-alive daemon
-- | (ROADMAP Stage 2 delta #2). Where `serve` is a lazy-spawn *router* (proxy +
-- | idle-reap), `supervise` is the opposite lifecycle: bring the deployment UP
-- | and KEEP it up, restarting what crashes — yet it exposes the SAME `/state` +
-- | `/control/*` HTTP surface as `serve` (the HANDOFF-CHAIR contract), so the
-- | Chair drives it with no change.
-- |
-- | The decision tier is the PURE core, unchanged: `supervise` is just `plan`
-- | run on a loop. Each tick observes the rig, plans against desired, and enacts
-- | the resulting Start/Restart changes (`baseChange` already maps `Failed →
-- | Restart`, `Down → Start`, `Running → NoOp`, `InBackoff → NoOp`). Only the
-- | watch-loop and the HTTP surface are new, and they live in the JS shim
-- | (`superviseImpl`) — the one place the no-Aff seam yields, exactly as `serve`.
-- |
-- | `desiredUp` makes a manual STOP HOLD ("stop means stop", ADR-aligned): a
-- | `POST /control/down` sets it false and suspends auto-restart until a
-- | `POST /control/up`. `POST /control/restart?service=<id>` forces ONE service
-- | to restart by marking it `Failed` in the observed snapshot and letting the
-- | pure planner do the rest (incl. D-E5 coupled co-restart) — no ref-minting,
-- | no special path.
module Bosun.CLI.Supervise (runSupervise) where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Apply (Command(..), StagedCommand, applyScript, downScript)
import Bosun.Atoms (ServiceId, mkServiceId, unServiceId)
import Bosun.CLI.Exec (execLine)
import Bosun.CLI.IO (readJsonFile, readYamlFile)
import Bosun.CLI.Observe (observeSnapshot)
import Bosun.Plan (Snapshot, Status(..), plan)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderCommand, renderReport)
import Bosun.Target (defaultTargets)
import Bosun.Validate (validate)
import Bosun.Version (version)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (intercalate, traverse_)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Uncurried (EffectFn1, EffectFn2, mkEffectFn2, runEffectFn1)

-- The resident shim's hooks. `tick` runs one observe→plan→enact round;
-- `stateBody` renders the current `/state` JSON; `control` handles a
-- `/control/<verb>?service=<arg>` POST and returns a status message.
type SuperviseConfig =
  { statusPort :: Int
  , intervalMs :: Int
  , tick :: Effect Unit
  , stateBody :: Effect String
  , control :: EffectFn2 String String String
  }

foreign import superviseImpl :: EffectFn1 SuperviseConfig Unit

defaultStatusPort :: Int
defaultStatusPort = 3996

intervalMs :: Int
intervalMs = 3000

-- | `bosun supervise [--port N] <compose> <registry>`. The status port defaults
-- | to 3996; pass `--port` to run one supervisor PER GROUP, each on its own port
-- | (a group = one deployment), so the Chair polls/controls each independently.
runSupervise :: Maybe Int -> String -> String -> Effect Unit
runSupervise mPort composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
    dep = r.deployment
  log ("bosun " <> version <> " — supervise " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate dep) of
    Left vErrors -> do
      log "cannot supervise: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> do
      desiredUp <- Ref.new true
      snapRef <- Ref.new (Map.empty :: Snapshot)
      let
        runOne sc = case sc.command of
          Manual note -> log ("  · skip (manual): " <> note)
          command -> do
            let line = renderCommand command
            res <- execLine line
            log ("  " <> (if res.ok then "✓" else "✗") <> " " <> line)

        enact label script =
          when (not (A.null script)) do
            log ("supervise: " <> label)
            traverse_ runOne (A.sortWith _.stage script)

        scriptFor :: Snapshot -> Array StagedCommand
        scriptFor obs = applyScript defaultTargets vd (plan vd { desired: vd, recorded: Nothing, observed: obs })

        bringUp = enact "bring-up" (scriptFor Map.empty)
        bringDown = enact "teardown" (downScript defaultTargets vd)

        tick = do
          up <- Ref.read desiredUp
          snap <- observeSnapshot dep
          Ref.write snap snapRef
          when up (enact "reconcile (keep-alive)" (scriptFor snap))

        stateBody = do
          snap <- Ref.read snapRef
          up <- Ref.read desiredUp
          pure (snapshotBody up snap)

        control = mkEffectFn2 \verb arg -> case verb of
          "up" -> do
            Ref.write true desiredUp
            bringUp
            pure "up: desired=up, bringing up"
          "down" -> do
            Ref.write false desiredUp
            bringDown
            pure "down: desired=down, auto-restart suspended"
          "restart" -> do
            snap <- observeSnapshot dep
            enact ("restart " <> arg) (scriptFor (Map.insert (mkServiceId arg) Failed snap))
            pure ("restart: " <> arg)
          _ -> pure ("unknown control verb: " <> verb)
      log "supervise: initial bring-up…"
      bringUp
      runEffectFn1 superviseImpl
        { statusPort: fromMaybe defaultStatusPort mPort, intervalMs, tick, stateBody, control }

-- Minimal `/state` JSON: desired up/down + each service's observed status.
-- (Mirrors Main's `statusToken`; consolidate both into a shared snapshot codec
-- in CLI.Observe later — flagged follow-up.)
snapshotBody :: Boolean -> Snapshot -> String
snapshotBody up snap =
  "{ \"desired\": \"" <> (if up then "up" else "down")
    <> "\", \"services\": { "
    <> intercalate ", " (map entry (Map.toUnfoldable snap :: Array (Tuple ServiceId Status)))
    <> " } }"
  where
  entry (Tuple sid st) = "\"" <> unServiceId sid <> "\": \"" <> statusToken st <> "\""

statusToken :: Status -> String
statusToken = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"
