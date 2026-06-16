-- | BUILD-PLAN Phase 6C (Go column) — "can the Go BINARY do the devops?"
-- |
-- | A deliberately I/O-free effectful harness: it hardcodes a tiny hello-world
-- | deployment (two background HTTP servers), runs the *pure* core to a command
-- | script (`reconcile -> validate -> plan -> applyScript`), then EXECUTES each
-- | command via `execLine`. Because the fixture is hardcoded, the ONLY foreign
-- | beyond the pure-core/Console surface is `execLineImpl` (os-exec) — so the
-- | backend-go transpile needs exactly one new Go shim (see docs/PHASE-6C-GO.md),
-- | not Go ports of js-yaml / fs / argv. Compiles + runs on node too (its `.js`
-- | foreign), so you can verify the harness before the Go column.
-- |
-- | Distinct ports (8773/8774) and dir (/tmp/bosun-hello-go) from the node CLI
-- | hello fixture, so a Go-launched server is unambiguously the Go binary's.
module Bosun.Conformance.ApplyMain where

import Prelude

import Bosun.Apply (Command(..), StagedCommand, applyScript)
import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkHost, mkPort, mkProjectSlug)
import Bosun.Executor (Executor(..))
import Bosun.Reachability (hostPort)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Plan (plan)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderCommand)
import Bosun.Service (ServiceInstance, Source(..), mkRole)
import Bosun.Validate (validate)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Partial.Unsafe (unsafePartial)

-- The execution edge, declared HERE so its Go shim is
-- `Bosun_Conformance_ApplyMain_execLineImpl` — one self-contained foreign.
type ExecResult = { ok :: Boolean, code :: Int, message :: String }
foreign import execLineImpl :: EffectFn1 String ExecResult

execLine :: String -> Effect ExecResult
execLine = runEffectFn1 execLineImpl

main :: Effect Unit
main = do
  let r = reconcile Map.empty helloFixture
  case toEither (validate r.deployment) of
    Left _ -> log "apply (Go column): fixture failed to validate (should not happen)"
    Right vd -> do
      let script = applyScript vd (plan vd { desired: vd, recorded: Nothing, observed: Map.empty })
      log ("apply (Go column): " <> show (Array.length script) <> " command(s)")
      traverse_ runStep script
      log "apply (Go column): done."

runStep :: StagedCommand -> Effect Unit
runStep sc = case sc.command of
  Manual note -> log ("  · skip (manual): " <> note)
  command -> do
    let line = renderCommand command
    res <- execLine line
    log ("  " <> (if res.ok then "OK  " else "FAIL ") <> line)

helloFixture :: Array ServiceInstance
helloFixture =
  [ server "hello-greeter" "greeter" 8773
  , server "hello-echoer" "echoer" 8774
  ]

server :: String -> String -> Int -> ServiceInstance
server name role port =
  { source: FromRegistry
  , project: Just (mkProjectSlug "hellogo")
  , localName: name
  , role: mkRole role
  , host: Just (mkHost "mbp")
  , executor: Process
      { cwd: absPath "/tmp/bosun-hello-go"
      , command: "nohup python3 -m http.server " <> show port <> " >" <> role <> ".log 2>&1 &"
      , env: []
      }
  , reachability: hostPort (port_ port)
  , health: { liveness: NoProbe, readiness: TcpConnect (port_ port), startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))
