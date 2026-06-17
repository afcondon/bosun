-- | BUILD-PLAN Phase 6B — `applyScript` as example tests.
-- |
-- | The command generator is pure, so we assert on the *rendered* command
-- | strings (Command is entry-73 — no `Show`; `renderCommand` is its display).
-- | Process facets become local `cd … && cmd`; macmini container facets become
-- | ssh-wrapped `docker compose up -d`; a `NoOp` contributes nothing.
module Test.Bosun.ApplySpec where

import Prelude

import Bosun.Apply (applyScript)
import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkDomain, mkHost, mkPort, mkServiceId)
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
  (leaf name) { launch = { executor: Process { cwd: absPath cwd, command: cmd, env: [] }, localName: name } }

containerLeaf :: String -> String -> LooseService
containerLeaf name host =
  (leaf name)
    { host = Just (mkHost host)
    , launch =
        { executor: Container (ContainerSpec { source: Left (ImageRef name), internalPort: Nothing, publish: Nothing })
        , localName: name
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

spec :: Spec Unit
spec = describe "Bosun.Apply" do

  it "Process Start -> local, daemonized (long-running service, not ssh-wrapped)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && nohup env run-a >/tmp/bosun-apply-a.log 2>&1 &" ]

  -- A startCommand may carry a leading env-var assignment (e.g. the julia atlas:
  -- `ATLAS_PORT=3210 julia …`). Bare `nohup VAR=val prog` makes nohup exec the
  -- string `VAR=val` — the `env` prefix lets the shell-style assignment through.
  it "Process Start with an env-var prefix is launched via `env` (not eaten by nohup)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "ATLAS_PORT=3210 run-a" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && nohup env ATLAS_PORT=3210 run-a >/tmp/bosun-apply-a.log 2>&1 &" ]

  it "a Process command that already backgrounds itself is left as-is" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a &" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && run-a &" ]

  -- A macmini container resolves to the macmini Target: ssh login, the remote
  -- compose workdir (so the file is found) and Docker Desktop's PATH (so a
  -- non-interactive ssh shell finds `docker`) — all from the target table, no
  -- host string in the planner.
  it "macmini Container Start -> ssh-wrapped docker compose up, in the remote workdir with PATH" $
    withScript (mkDeployment [ containerLeaf "web" "macmini" ]) (snap []) \lines ->
      lines `shouldEqual`
        [ "ssh andrew@andrews-mac-mini 'cd /Users/andrew/psd3/polyglot-deploy && export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && docker compose up -d web'" ]

  -- A service with a Published address gets a SECOND command after its launch:
  -- `tailscale funnel` enabling its listening port on the public internet.
  it "a Published macmini service ALSO emits a tailscale funnel publish step" $
    withScript (mkDeployment [ publishedLeaf "edge" "macmini" ]) (snap []) \lines ->
      lines `shouldEqual`
        [ "ssh andrew@andrews-mac-mini 'cd /Users/andrew/psd3/polyglot-deploy && export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && docker compose up -d edge'"
        , "ssh andrew@andrews-mac-mini 'export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH && tailscale funnel --bg 80'"
        ]

  it "a running service contributes no command (NoOp omitted)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap [ Tuple "a" Running ]) \lines ->
      lines `shouldEqual` []
