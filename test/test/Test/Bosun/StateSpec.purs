-- | The two `/state` documents, as a READER takes them.
-- |
-- | `beam/conformance.sh` holds the group document's PRINTER: what the daemon
-- | writes comes back unchanged, on both runtimes. This holds the reading
-- | side, which is what the Chair runs:
-- |
-- |   * every document `supervise` has answered reads as a group document,
-- |     and says the same thing either way;
-- |   * what `docker` prints reads as a group document;
-- |   * what the running router answered reads as a router document.
module Test.Bosun.StateSpec (spec) where

import Prelude

import Bosun.Adapters.DockerPs (HealthVerdict(..))
import Bosun.Atoms (ServiceId, mkServiceId)
import Bosun.CLI.Docker as Docker
import Bosun.CLI.IO (readJsonFile)
import Bosun.Plan (Status(..))
import Bosun.Protocol.ServeState (readServeState)
import Bosun.Protocol.State (group, groupOf, readGroup, stateDoc)
import Data.Argonaut.Core (stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..), either, isLeft)
import Data.Foldable (for_)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect.Class (liftEffect)
import Hawser.Value (Value(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

sid :: String -> ServiceId
sid = mkServiceId

-- | Every document under `protocol/vectors/state/` that `supervise` wrote or
-- | could write. (The `refused-*` ones are the conformance run's. So is
-- | `from-a-newer-supervisor`: one of its invented fields is a row's `health`,
-- | which the supervise description drops and the group reader, knowing it
-- | from docker, keeps.)
superviseVectors :: Array String
superviseVectors =
  [ "after-down"
  , "every-part"
  , "live-mbp-atlantis-beam"
  , "live-mbp-brunel-node"
  , "live-mbp-minard-beam"
  , "live-mbp-root-node"
  , "live-mini-root-beam"
  ]

spec :: Spec Unit
spec = describe "Bosun.Protocol.State and ServeState (the reading side)" do

  describe "a supervise document is a group document" do
    for_ superviseVectors \name ->
      it (name <> " reads both ways and says the same") do
        json <- liftEffect (readJsonFile ("protocol/vectors/state/" <> name <> ".json"))
        let Value full = stateDoc
        let Value reader = group
        case full.fromJson json, readGroup json of
          Just doc, Right read ->
            stringify (reader.toJson read) `shouldEqual` stringify (reader.toJson (groupOf doc))
          Nothing, _ -> fail "the supervise description refused it"
          _, Left why -> fail ("the group reader refused it: " <> why)

    it "the router's document is not a group document, and the refusal says why" do
      json <- liftEffect (readJsonFile "protocol/vectors/serve-state/live-mbp-serve-node.json")
      readGroup json `shouldEqual` Left "no desired"

  describe "what docker prints is a group document" do
    let
      printed = Docker.snapshotBody "up"
        ( Map.fromFoldable
            [ Tuple (sid "edge") { status: Running, health: Healthy }
            , Tuple (sid "site") { status: Failed, health: CheckError }
            ]
        )

    it "is printed in /state's spacing, with what differs from supervise said" $
      printed `shouldEqual`
        ( "{ \"desired\": \"up\", \"supervised\": false, "
            <> "\"services\": { \"edge\": \"running\", \"site\": \"failed\" }, "
            <> "\"supervision\": { "
            <> "\"edge\": { \"restarts\": 0, \"fails\": 0, \"health\": \"healthy\", \"keepAliveOwner\": \"docker\" }, "
            <> "\"site\": { \"restarts\": 0, \"fails\": 0, \"health\": \"check-error\", \"keepAliveOwner\": \"docker\" } }, "
            <> "\"selfHeals\": true, \"keepAliveOwner\": \"docker\" }"
        )

    it "reads back as a group that is not supervised and heals itself" $
      case jsonParser printed >>= readGroup of
        Left why -> fail why
        Right read -> do
          read.supervised `shouldEqual` false
          read.selfHeals `shouldEqual` Just true
          read.phase `shouldEqual` Nothing
          map (\(Tuple name row) -> Tuple name row.health) read.supervision
            `shouldEqual` [ Tuple "edge" (Just "healthy"), Tuple "site" (Just "check-error") ]

    it "is not a supervise document: it has no phase" do
      let Value full = stateDoc
      (jsonParser printed >>= (full.fromJson >>> either' "refused")) `shouldEqual` Left "refused"

  describe "the router's document" do
    it "what the running router answered (2026-11-17) reads" do
      json <- liftEffect (readJsonFile "protocol/vectors/serve-state/live-mbp-serve-node.json")
      case readServeState json of
        Left why -> fail why
        Right read -> do
          Array.length read.routes `shouldEqual` 27
          Array.length read.redirects `shouldEqual` 6
          Array.length read.rejected `shouldEqual` 32
          map Array.length read.brokered `shouldEqual` Just 1
          read.stale `shouldEqual` Just false

    it "every part is read, and a field from a newer router is ignored" do
      json <- liftEffect (readJsonFile "protocol/vectors/serve-state/every-part.json")
      case readServeState json of
        Left why -> fail why
        Right read -> do
          map _.pid read.routes `shouldEqual` [ Just 4242, Nothing ]
          map _.bindError read.routes `shouldEqual` [ Nothing, Just "EADDRINUSE" ]
          map (map _.door) read.brokered `shouldEqual` Just [ Just "none" ]
          map (map _.kind) read.drift `shouldEqual` Just [ "unrouted" ]
          map _.publicPort read.rejected `shouldEqual` [ Nothing ]

    it "a port written as text is refused, naming the field" do
      json <- liftEffect (readJsonFile "protocol/vectors/serve-state/refused-port-is-text.json")
      case readServeState json of
        Left why -> String.contains (Pattern "routes") why `shouldEqual` true
        Right _ -> fail "read a route whose port was text"

    it "a document missing a required table is refused" do
      json <- liftEffect (readJsonFile "protocol/vectors/serve-state/refused-no-rejected.json")
      isLeft (readServeState json) `shouldEqual` true
  where
  either' :: forall a. String -> Maybe a -> Either String a
  either' why = case _ of
    Just a -> Right a
    Nothing -> Left why
