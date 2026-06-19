-- | The Menagerie Gnomon column (docs/MENAGERIE.md) — "can the Go BINARY be the
-- | resident process SUPERVISOR?"
-- |
-- | The resident counterpart to the pure `SuperviseMain` (which proves the tick
-- | transition byte-identical) and to DockerMain/ServeMain. It runs the REAL
-- | `Bosun.CLI.Supervise.superviseResident` (not a re-implementation) over the
-- | SAME Menagerie cast as `scripts/menagerie-conf.sh`'s node column — so the two
-- | columns are a faithful BEHAVIOURAL parity test, the point of the rig: a
-- | byte-diff can't catch "recorded pgid ≠ live", but two binaries actually
-- | supervising three real processes can.
-- |
-- | The fixture is the compose.yml content embedded as a JSON literal and run
-- | through the REAL `ingestCompose` adapter (not hand-built `ServiceInstance`s),
-- | so the derived service ids / ports / executors are IDENTICAL to what the node
-- | CLI gets from `fixtures/menagerie/compose.yml` — which is what makes the
-- | `/state` cross-runtime diff meaningful. Embedding (vs a file read) keeps the
-- | harness I/O-free, so the foreign surface beyond the pure core / Console is:
-- |
-- |   · `Data.Argonaut.Parser._jsonParser`        — parse the embedded fixture
-- |   · `Bosun.CLI.Observe.probe{Http,Tcp,Socket,PgidAlive}Impl` — readiness /
-- |     liveness probes (NEW Go twins: conformance/go/bosun_probe_foreign.go)
-- |   · `Bosun.CLI.Exec.execLineImpl`             — launch / reap (os-exec)
-- |   · `Bosun.CLI.Resident.residentImpl` / `_nowMs` — the /state + /control shim
-- |
-- | …each with a hand-written Go twin in conformance/go/, copied into the build
-- | by scripts/menagerie-conf.sh. Runs on node too (its existing `.js` foreigns),
-- | so the script drives BOTH columns through the same assertions + diffs /state.
module Bosun.Conformance.MenagerieMain where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.CLI.Resident (runResident)
import Bosun.CLI.Supervise (superviseResident)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Target (defaultTargets)
import Bosun.Validate (validate)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)

-- | Control surface on :8788 — the SAME port the node column uses, run
-- | SEQUENTIALLY by the script (node column first, killed, then this), so the
-- | reuse is fine and the two `/state` snapshots are directly comparable.
main :: Effect Unit
main = case jsonParser composeJson of
  Left e -> log ("menagerie (Go column): bad embedded fixture: " <> e)
  Right j -> do
    let
      insts = ingestCompose j
      r = reconcile (buildAliases insts) insts
    case toEither (validate r.deployment) of
      Left _ -> log "menagerie (Go column): fixture failed to validate (should not happen)"
      Right vd -> superviseResident defaultTargets (Just 8788) r.deployment vd >>= runResident

-- The JSON equivalent of fixtures/menagerie/compose.yml. Kept in sync by hand
-- (3 services); the node column reads the YAML, this embeds the same content, and
-- BOTH go through `ingestCompose` — identical ServiceInstances out.
composeJson :: String
composeJson =
  """
  { "services":
    { "ticker":
      { "ports": ["8790:8790"]
      , "x-bosun": { "host": "mbp", "process":
          { "cwd": "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures/menagerie/bin"
          , "command": "python3 ticker.py 8790" } } }
    , "slowboot":
      { "ports": ["8791:8791"]
      , "x-bosun": { "host": "mbp", "process":
          { "cwd": "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures/menagerie/bin"
          , "command": "python3 slowboot.py 8791" } } }
    , "forker":
      { "ports": ["8792:8792"]
      , "x-bosun": { "host": "mbp", "process":
          { "cwd": "/Users/afc/work/afc-work/ShapedSteer/bosun/fixtures/menagerie/bin"
          , "command": "python3 forker.py 8792" } } }
    }
  }
  """
