-- | BUILD-PLAN Phase 6B — `applyScript` as example tests.
-- |
-- | The command generator is pure, so we assert on the *rendered* command
-- | strings (Command is entry-73 — no `Show`; `renderCommand` is its display).
-- | Process facets become local `cd … && cmd`; macmini container facets become
-- | ssh-wrapped `docker compose up -d`; a `NoOp` contributes nothing.
module Test.Bosun.ApplySpec where

import Prelude

import Bosun.Apply (applyScript, downScript)
import Bosun.Artifact (Artifact(..), mkRef)
import Bosun.Atoms (AbsPath, EnvVar, Port, mkAbsPath, mkDomain, mkEnvVar, mkHost, mkPort, mkServiceId)
import Bosun.Reachability (Address(..), BindScope(..), Reachability(..))
import Bosun.Target (defaultTargets)
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Plan (Snapshot, Status(..), plan)
import Bosun.Report (renderCommand)
import Bosun.Service (Deployment, LooseService, mkDeployment)
import Bosun.Validate (validate)
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Data.Validation.Semigroup (toEither)
import Effect.Aff (Aff)
import Partial.Unsafe (unsafePartial)
import Test.Bosun.ValidateSpec (leaf)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

procLeaf :: String -> String -> String -> LooseService
procLeaf name cwd cmd =
  (leaf name) { launch = { executor: Process { cwd: absPath cwd, command: cmd, env: [] }, localName: name, artifact: Nothing } }

procLeafEnv :: String -> String -> String -> Array (Tuple EnvVar String) -> LooseService
procLeafEnv name cwd cmd env =
  (leaf name) { launch = { executor: Process { cwd: absPath cwd, command: cmd, env }, localName: name, artifact: Nothing } }

-- a container from a PREBUILT image (build-once-ship): apply should pull, not
-- build, this artifact.
containerLeaf :: String -> String -> LooseService
containerLeaf name host =
  (leaf name)
    { host = Just (mkHost host)
    , launch =
        { executor: Container (ContainerSpec { source: Left (ImageRef name), internalPort: Nothing, publish: Nothing })
        , localName: name
        , artifact: Just (Image (mkRef name))
        }
    }

-- a container built from a local SOURCE dir (the build-per-host anti-pattern):
-- apply should run it but flag a build-once-ship advisory.
sourceBuildLeaf :: String -> String -> String -> LooseService
sourceBuildLeaf name host ctx =
  (leaf name)
    { host = Just (mkHost host)
    , launch =
        { executor: Container (ContainerSpec { source: Left (ImageRef name), internalPort: Nothing, publish: Nothing })
        , localName: name
        , artifact: Just (SourceBuild (mkRef ctx))
        }
    }

-- a container on `host` that ALSO declares a Published (public-domain) address
-- alongside its host:80 listener — the edge/Funnel shape.
publishedLeaf :: String -> String -> LooseService
publishedLeaf name host =
  (containerLeaf name host)
    { reachability = Reachability (Set.fromFoldable
        [ Listening { bind: AllIfaces, port: port_ 80 }
        , Published (mkDomain "andrews-mac-mini.vaquita-paradise.ts.net")
        ]) }

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

snap :: Array (Tuple String Status) -> Snapshot
snap = Map.fromFoldable <<< map (\(Tuple n st) -> Tuple (mkServiceId n) st)

-- assert on the rendered command lines, in plan order
withScript :: Deployment -> Snapshot -> (Array String -> Aff Unit) -> Aff Unit
withScript d obs f = case toEither (validate d) of
  Left _ -> fail "fixture was expected to validate"
  Right vd ->
    f (map (renderCommand <<< _.command) (applyScript defaultTargets vd (plan vd { desired: vd, recorded: Nothing, observed: obs })))

-- assert on the rendered teardown (down) command lines, in reverse boot order
withDownScript :: Deployment -> (Array String -> Aff Unit) -> Aff Unit
withDownScript d f = case toEither (validate d) of
  Left _ -> fail "fixture was expected to validate"
  Right vd -> f (map (renderCommand <<< _.command) (downScript defaultTargets vd))

spec :: Spec Unit
spec = describe "Bosun.Apply" do

  -- A Process Start REAPS any prior recorded generation before launching fresh
  -- (Bosun.Substrate.daemonize) — the `down`-orphan fix. So a Start renders the
  -- same reap-then-launch as a Restart; on a clean first Start the reap finds no
  -- pidfile and `|| true` no-ops.
  it "Process Start -> local, reap-then-daemonize, recording its process group (not ssh-wrapped)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && kill -- -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null || true; i=0; while kill -0 -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null && [ \"$i\" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; ( nohup env run-a >/tmp/bosun-apply-a.log 2>&1 & ps -o pgid= -p $! | tr -d ' ' > /tmp/bosun-apply-a.pid ) &" ]

  -- A startCommand may carry a leading env-var assignment (e.g. the julia atlas:
  -- `ATLAS_PORT=3210 julia …`). Bare `nohup VAR=val prog` makes nohup exec the
  -- string `VAR=val` — the `env` prefix lets the shell-style assignment through.
  it "Process Start with an env-var prefix is launched via `env` (not eaten by nohup)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "ATLAS_PORT=3210 run-a" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && kill -- -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null || true; i=0; while kill -0 -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null && [ \"$i\" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; ( nohup env ATLAS_PORT=3210 run-a >/tmp/bosun-apply-a.log 2>&1 & ps -o pgid= -p $! | tr -d ' ' > /tmp/bosun-apply-a.pid ) &" ]

  -- The typed `x-bosun.process.env` (e.g. purerl-tidal's rebar3
  -- `ERL_LIBS=_build/default/lib`) renders as a leading `KEY=VAL ` assignment
  -- that the `nohup env <cmd>` wrapper applies — typed data, same effect as the
  -- inline-prefix path above, but inspectable instead of buried in the command.
  it "Process Start with a typed env renders leading KEY=VAL assignments" $
    withScript (mkDeployment [ procLeafEnv "a" "/srv/a" "erl -pa ebin" [ Tuple (mkEnvVar "ERL_LIBS") "_build/default/lib" ] ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && kill -- -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null || true; i=0; while kill -0 -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null && [ \"$i\" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; ( nohup env ERL_LIBS=_build/default/lib erl -pa ebin >/tmp/bosun-apply-a.log 2>&1 & ps -o pgid= -p $! | tr -d ' ' > /tmp/bosun-apply-a.pid ) &" ]

  it "a Process command that already backgrounds itself is left as-is (no group captured)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a &" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && run-a &" ]

  -- Stop kills the process GROUP Bosun recorded at launch (reaping the whole
  -- nohup→server tree) — its own processes, not whatever holds the port —
  -- tolerant of a missing file (task #8, recorded-PGID half).
  it "down: a Process Stop kills the recorded process group (Bosun's own, tolerant if absent)" $
    withDownScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) \lines ->
      lines `shouldEqual` [ "kill -- -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null || true" ]

  it "Process Restart -> kill the recorded group, then relaunch (recording the new one)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap [ Tuple "a" Failed ]) \lines ->
      lines `shouldEqual`
        [ "cd /srv/a && kill -- -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null || true; i=0; while kill -0 -\"$(cat /tmp/bosun-apply-a.pid 2>/dev/null)\" 2>/dev/null && [ \"$i\" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; ( nohup env run-a >/tmp/bosun-apply-a.log 2>&1 & ps -o pgid= -p $! | tr -d ' ' > /tmp/bosun-apply-a.pid ) &" ]

  -- A macmini container resolves to the macmini Target: ssh login, the remote
  -- compose workdir (so the file is found) and Docker Desktop's PATH (so a
  -- non-interactive ssh shell finds `docker`) — all from the target table, no
  -- host string in the planner. Its artifact is a PREBUILT image, so the launch
  -- is pull-not-build (docs/ARTIFACTS.md): `pull` then `up -d --no-build`.
  it "macmini Container Start (prebuilt image) -> ssh-wrapped pull-not-build" $
    withScript (mkDeployment [ containerLeaf "web" "macmini" ]) (snap []) \lines ->
      lines `shouldEqual`
        [ "ssh andrew@andrews-mac-mini 'cd /Users/andrew/psd3/polyglot-deploy && export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && export DOCKER_CONFIG=/Users/andrew/.docker-nocreds && docker compose pull web && docker compose up -d --no-build web'" ]

  -- A SourceBuild artifact (built per host) still launches via `up -d` (we can't
  -- do better without a shipped image), but the script carries a build-once-ship
  -- advisory `# MANUAL:` note — the drift made visible at apply time.
  it "macmini Container Start (source build) -> up -d PLUS a build-once-ship advisory" $
    withScript (mkDeployment [ sourceBuildLeaf "web" "macmini" "../site/web" ]) (snap []) \lines ->
      lines `shouldEqual`
        [ "ssh andrew@andrews-mac-mini 'cd /Users/andrew/psd3/polyglot-deploy && export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && export DOCKER_CONFIG=/Users/andrew/.docker-nocreds && docker compose up -d web'"
        , "# MANUAL: build-once-ship: web builds from source (../site/web) on the host — run `quartermaster build` to ship a prebuilt image instead (docs/PROVISIONING-SEAM.md)"
        ]

  -- A service with a Published address gets a SECOND command after its launch:
  -- `tailscale funnel` enabling its listening port on the public internet.
  it "a Published macmini service (prebuilt) ALSO emits a tailscale funnel publish step" $
    withScript (mkDeployment [ publishedLeaf "edge" "macmini" ]) (snap []) \lines ->
      lines `shouldEqual`
        [ "ssh andrew@andrews-mac-mini 'cd /Users/andrew/psd3/polyglot-deploy && export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && export DOCKER_CONFIG=/Users/andrew/.docker-nocreds && docker compose pull edge && docker compose up -d --no-build edge'"
        , "ssh andrew@andrews-mac-mini 'export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && export DOCKER_CONFIG=/Users/andrew/.docker-nocreds && tailscale funnel --bg 80'"
        ]

  it "a running service contributes no command (NoOp omitted)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap [ Tuple "a" Running ]) \lines ->
      lines `shouldEqual` []
