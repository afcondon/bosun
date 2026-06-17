-- | Go-column proof: the FULL `bosun apply` CLI, reading REAL files.
-- |
-- | Where `ApplyMain` hardcodes a fixture (so its only foreign is os-exec),
-- | THIS harness is the real `runApply` pipeline end to end: it reads the
-- | compose + registry files off disk, ingests them through the adapters,
-- | reconciles, validates, plans, and executes the apply script. The point is
-- | to drive the Json-decoding path (`Data.Argonaut.Core` + `Foreign.Object`)
-- | and real file/argv I/O through backend-go — the foreigns the hardcoded
-- | conformance harnesses never exercised — so the GO BINARY performs a real,
-- | file-driven deploy, not a compiled-in one.
-- |
-- | It declares its own foreigns (`readJsonImpl` / `readYamlImpl` / `argv` /
-- | `execLineImpl`) rather than depending on the `bosun-cli` package, so the
-- | Go shims are self-contained `Bosun_Conformance_ApplyCliMain_*` symbols
-- | (same self-contained pattern as `ApplyMain`). On node it runs off the
-- | sibling `.js`; on Go off the hand-written shims copied in at build time.
-- |
-- | Usage:  apply-cli <compose.{yml,json}> <registry.json>
module Bosun.Conformance.ApplyCliMain where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Apply (Command(..), StagedCommand, applyScript)
import Bosun.Target (defaultTargets)
import Bosun.Plan (plan)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Report (renderCommand, renderReport, renderScript)
import Bosun.Validate (validate)
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)

type ExecResult = { ok :: Boolean, code :: Int, message :: String }

foreign import readJsonImpl :: EffectFn1 String Json
foreign import readYamlImpl :: EffectFn1 String Json
foreign import execLineImpl :: EffectFn1 String ExecResult
foreign import argv :: Effect (Array String)

readJsonFile :: String -> Effect Json
readJsonFile = runEffectFn1 readJsonImpl

readYamlFile :: String -> Effect Json
readYamlFile = runEffectFn1 readYamlImpl

execLine :: String -> Effect ExecResult
execLine = runEffectFn1 execLineImpl

main :: Effect Unit
main = do
  args <- argv
  case args of
    [ "--dry-run", composePath, registryPath ] -> runDryRun composePath registryPath
    [ composePath, registryPath ] -> runApply composePath registryPath
    _ -> log "usage: apply-cli [--dry-run] <compose.{yml,json}> <registry.json>"

-- | Print the apply script WITHOUT executing it — the pure `Plan -> script`
-- | rendered. Used to diff the Go column against node on a rich YAML compose
-- | without touching any real system (the macmini fixture would otherwise ssh).
runDryRun :: String -> String -> Effect Unit
runDryRun composePath registryPath = do
  composeJson <- readComposeFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  case toEither (validate r.deployment) of
    Left vErrors ->
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd ->
      log (renderScript (applyScript defaultTargets vd (plan vd { desired: vd, recorded: Nothing, observed: Map.empty })))

-- | Mirrors `Bosun.CLI.Main.runApply` (observed = empty: a from-scratch boot).
runApply :: String -> String -> Effect Unit
runApply composePath registryPath = do
  composeJson <- readComposeFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    r = reconcile (buildAliases insts) insts
  log ("apply-cli — apply " <> composePath <> " + " <> registryPath)
  log ""
  case toEither (validate r.deployment) of
    Left vErrors -> do
      log "cannot apply: the deployment does not validate —"
      log ""
      log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
    Right vd -> do
      let
        script = applyScript defaultTargets vd (plan vd { desired: vd, recorded: Nothing, observed: Map.empty })
        stages = A.groupBy (\a b -> a.stage == b.stage) script
      if A.null stages then log "apply: nothing to do — the rig already matches desired state."
      else runStages 1 (map NEA.toArray stages)

-- | Compose files are YAML, but docker also accepts JSON; read JSON directly
-- | when the path ends `.json` so the JSON-only column can run before the YAML
-- | foreign lands.
readComposeFile :: String -> Effect Json
readComposeFile path
  | String.contains (String.Pattern ".json") path = readJsonFile path
  | otherwise = readYamlFile path

runStages :: Int -> Array (Array StagedCommand) -> Effect Unit
runStages n stages = case A.uncons stages of
  Nothing -> log "\napply: done."
  Just { head: stage, tail: rest } -> do
    log ("stage " <> show n <> ":")
    ok <- runStage stage
    if ok then runStages (n + 1) rest
    else log "\napply: ABORTED — a command failed; dependents were not started."

runStage :: Array StagedCommand -> Effect Boolean
runStage cmds = do
  results <- traverseEff runOne cmds
  pure (A.all identity results)
  where
  runOne sc = case sc.command of
    Manual note -> do
      log ("  · skip (manual): " <> note)
      pure true
    command -> do
      let line = renderCommand command
      res <- execLine line
      log ("  " <> (if res.ok then "✓" else "✗ (" <> show res.code <> ")") <> " " <> line)
      pure res.ok

-- local traverse over Effect (avoid pulling Data.Traversable's class machinery
-- through a 2nd foreign surface; a plain fold is enough here)
traverseEff :: forall a b. (a -> Effect b) -> Array a -> Effect (Array b)
traverseEff f xs = case A.uncons xs of
  Nothing -> pure []
  Just { head, tail } -> do
    y <- f head
    ys <- traverseEff f tail
    pure (A.cons y ys)
