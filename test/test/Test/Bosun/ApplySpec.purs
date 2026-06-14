-- | BUILD-PLAN Phase 6B — `applyScript` as example tests.
-- |
-- | The command generator is pure, so we assert on the *rendered* command
-- | strings (Command is entry-73 — no `Show`; `renderCommand` is its display).
-- | Process facets become local `cd … && cmd`; macmini container facets become
-- | ssh-wrapped `docker compose up -d`; a `NoOp` contributes nothing.
module Test.Bosun.ApplySpec where

import Prelude

import Bosun.Apply (applyScript)
import Bosun.Atoms (AbsPath, mkAbsPath, mkHost, mkServiceId)
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Plan (Snapshot, Status(..), plan)
import Bosun.Report (renderCommand)
import Bosun.Service (Deployment, LooseService, mkDeployment)
import Bosun.Validate (validate)
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust)
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

snap :: Array (Tuple String Status) -> Snapshot
snap = Map.fromFoldable <<< map (\(Tuple n st) -> Tuple (mkServiceId n) st)

-- assert on the rendered command lines, in plan order
withScript :: Deployment -> Snapshot -> (Array String -> Aff Unit) -> Aff Unit
withScript d obs f = case toEither (validate d) of
  Left _ -> fail "fixture was expected to validate"
  Right vd ->
    f (map (renderCommand <<< _.command) (applyScript vd (plan vd { desired: vd, recorded: Nothing, observed: obs })))

spec :: Spec Unit
spec = describe "Bosun.Apply" do

  it "Process Start -> local, daemonized (long-running service, not ssh-wrapped)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && nohup run-a >/tmp/bosun-apply-a.log 2>&1 &" ]

  it "a Process command that already backgrounds itself is left as-is" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a &" ]) (snap []) \lines ->
      lines `shouldEqual` [ "cd /srv/a && run-a &" ]

  it "macmini Container Start -> ssh-wrapped docker compose up" $
    withScript (mkDeployment [ containerLeaf "web" "macmini" ]) (snap []) \lines ->
      lines `shouldEqual` [ "ssh andrew@andrews-mac-mini 'docker compose up -d web'" ]

  it "a running service contributes no command (NoOp omitted)" $
    withScript (mkDeployment [ procLeaf "a" "/srv/a" "run-a" ]) (snap [ Tuple "a" Running ]) \lines ->
      lines `shouldEqual` []
