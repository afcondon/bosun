-- | `Bosun.ProcessTitle`: what a launched process is called in `ps`.
module Test.Bosun.ProcessTitleSpec where

import Prelude

import Bosun.Atoms (mkEnvVar, mkServiceId)
import Bosun.ProcessTitle (groupOfComposePath, mkGroupName, processTitle, titledCommand, titledEnv, titledShellLine, unGroupName)
import Data.Tuple (Tuple(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = describe "Bosun.ProcessTitle" do

  -- beam/bosun derives the supervisor's own name by the same rule, in shell.
  describe "groupOfComposePath" do
    it "is the directory the compose file is in" do
      unGroupName (groupOfComposePath "fixtures/atlantis/compose.yml") `shouldEqual` "atlantis"
      unGroupName (groupOfComposePath "/Users/x/bosun/fixtures/macmini-router/compose.yml") `shouldEqual` "macmini-router"
      unGroupName (groupOfComposePath "./fixtures//router/compose.yml") `shouldEqual` "router"
    it "is the file's own name when it is given with no directory" do
      unGroupName (groupOfComposePath "compose.yml") `shouldEqual` "compose"
      unGroupName (groupOfComposePath "./rig.compose.yml") `shouldEqual` "rig"
    it "replaces what a title cannot carry" $
      unGroupName (groupOfComposePath "my rigs/compose.yml") `shouldEqual` "my-rigs"

  describe "processTitle" do
    it "is <group>:<service>" $
      processTitle (mkGroupName "atlantis") (mkServiceId "triggerfish") `shouldEqual` "atlantis:triggerfish"
    it "replaces what a title cannot carry" $
      processTitle (mkGroupName "a b") (mkServiceId "x:y z") `shouldEqual` "a-b:x-y-z"

  describe "titledEnv" do
    it "adds NODE_OPTIONS after the service's own variables" $
      titledEnv "g:s" [ Tuple (mkEnvVar "A") "1" ]
        `shouldEqual` [ Tuple (mkEnvVar "A") "1", Tuple (mkEnvVar "NODE_OPTIONS") "--title=g:s" ]
    it "adds the title to a NODE_OPTIONS the service sets, in place" $
      titledEnv "g:s" [ Tuple (mkEnvVar "NODE_OPTIONS") "--no-warnings", Tuple (mkEnvVar "A") "1" ]
        `shouldEqual` [ Tuple (mkEnvVar "NODE_OPTIONS") "--no-warnings --title=g:s", Tuple (mkEnvVar "A") "1" ]
    it "an empty NODE_OPTIONS becomes the title alone" $
      titledEnv "g:s" [ Tuple (mkEnvVar "NODE_OPTIONS") "" ]
        `shouldEqual` [ Tuple (mkEnvVar "NODE_OPTIONS") "--title=g:s" ]

  describe "titledCommand" do
    it "writes the title in after node" $
      titledCommand "g:s" "node server/run.js" `shouldEqual` "node --title=g:s server/run.js"
    it "looks past leading assignments" $
      titledCommand "g:s" "PORT=3100 BASE=http://x:1 node --experimental-sqlite run.js"
        `shouldEqual` "PORT=3100 BASE=http://x:1 node --title=g:s --experimental-sqlite run.js"
    it "leaves a command whose program is not node" do
      titledCommand "g:s" "npx serve -p 3000" `shouldEqual` "npx serve -p 3000"
      titledCommand "g:s" "./run.sh node" `shouldEqual` "./run.sh node"
      titledCommand "g:s" "nodemon x.js" `shouldEqual` "nodemon x.js"
      titledCommand "g:s" "" `shouldEqual` ""
    it "leaves a command that already has a title" $
      titledCommand "g:s" "node --title=mine run.js" `shouldEqual` "node --title=mine run.js"

  describe "titledShellLine" do
    it "exports the title after anything NODE_OPTIONS already holds, then runs the command" $
      titledShellLine "serve:web" "node server.mjs 23050"
        `shouldEqual` "export NODE_OPTIONS=\"${NODE_OPTIONS:+$NODE_OPTIONS }--title=serve:web\"; node --title=serve:web server.mjs 23050"
