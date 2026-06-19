-- | The Docker observation parse (`Bosun.Adapters.DockerPs`) — the mode-2
-- | substrate's read edge. The `container → ContainerObs` classification is real
-- | decision logic (EXECUTORS.md says conformance-pin it), so it gets example
-- | tests here: docker's `Health` is the readiness signal a `running` container
-- | still gates on; a **broken** healthcheck (probe could not run) is told apart
-- | from a genuinely **unhealthy** one and does NOT false-red the service; an
-- | absent container honestly reads `Down`; unknown states never over-claim.
module Test.Bosun.DockerPsSpec where

import Prelude

import Bosun.Adapters.DockerPs (HealthVerdict(..), classifyInspect, healthVerdictToken, parseDockerInspect)
import Bosun.Atoms (ServiceId, mkServiceId)
import Bosun.Plan (Status(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- Status has no Show; compare via a local token (same trick as SupervisorSpec).
tok :: Status -> String
tok = case _ of
  Running -> "running"
  Starting -> "starting"
  InBackoff -> "in-backoff"
  Failed -> "failed"
  Down -> "down"
  CompletedOk -> "completed-ok"
  Unknown _ -> "unknown"

names :: Map.Map String ServiceId
names = Map.fromFoldable
  [ Tuple "website" (mkServiceId "polyglot:website")
  , Tuple "edge" (mkServiceId "polyglot:edge")
  ]

-- Build a minimal `docker inspect --format "{{json .}}"` line for one container.
inspectLine :: String -> String -> String -> String
inspectLine svc state healthJson =
  "{\"State\":{\"Status\":\"" <> state <> "\"" <> healthJson
    <> "},\"Config\":{\"Labels\":{\"com.docker.compose.service\":\"" <> svc <> "\"}}}"

spec :: Spec Unit
spec = describe "Bosun.Adapters.DockerPs" do

  describe "classifyInspect" do
    it "running + Healthy ⇒ Running" $
      tok (classifyInspect { state: "running", rawHealth: Healthy }).status `shouldEqual` "running"
    it "running + HStarting ⇒ Starting (healthcheck not yet passing)" $
      tok (classifyInspect { state: "running", rawHealth: HStarting }).status `shouldEqual` "starting"
    it "running + Unhealthy ⇒ Failed (check ran, returned non-zero)" $
      tok (classifyInspect { state: "running", rawHealth: Unhealthy }).status `shouldEqual` "failed"
    it "running + CheckError ⇒ Running, NOT failed (broken check ≠ broken service)" do
      let obs = classifyInspect { state: "running", rawHealth: CheckError }
      tok obs.status `shouldEqual` "running"
      healthVerdictToken obs.health `shouldEqual` "check-error"
    it "running + NoCheck ⇒ Running (liveness is readiness)" $
      tok (classifyInspect { state: "running", rawHealth: NoCheck }).status `shouldEqual` "running"
    it "restarting ⇒ Starting" $
      tok (classifyInspect { state: "restarting", rawHealth: NoCheck }).status `shouldEqual` "starting"
    it "exited ⇒ Down" $
      tok (classifyInspect { state: "exited", rawHealth: NoCheck }).status `shouldEqual` "down"
    it "dead ⇒ Failed" $
      tok (classifyInspect { state: "dead", rawHealth: NoCheck }).status `shouldEqual` "failed"
    it "an unrecognised state never over-claims — ⇒ Down" $
      tok (classifyInspect { state: "weird", rawHealth: Healthy }).status `shouldEqual` "down"

  describe "parseDockerInspect" do
    let
      lookupStatus svc snap = map (\o -> tok o.status) (Map.lookup (mkServiceId svc) snap)
      lookupHealth svc snap = map (\o -> healthVerdictToken o.health) (Map.lookup (mkServiceId svc) snap)

    it "maps each container to its canonical id by the compose-service label" do
      let
        out =
          inspectLine "website" "running" ",\"Health\":{\"Status\":\"healthy\",\"Log\":[]}"
            <> "\n"
            <> inspectLine "edge" "running" ",\"Health\":{\"Status\":\"starting\",\"Log\":[]}"
        snap = parseDockerInspect names out
      lookupStatus "polyglot:website" snap `shouldEqual` Just "running"
      lookupStatus "polyglot:edge" snap `shouldEqual` Just "starting"

    it "a broken healthcheck (ExitCode -1) reads Running + check-error, not failed" do
      let
        out = inspectLine "edge" "running"
          ",\"Health\":{\"Status\":\"unhealthy\",\"Log\":[{\"ExitCode\":-1,\"Output\":\"exec: \\\"curl\\\": executable file not found in $PATH\"}]}"
        snap = parseDockerInspect names out
      lookupStatus "polyglot:edge" snap `shouldEqual` Just "running"
      lookupHealth "polyglot:edge" snap `shouldEqual` Just "check-error"

    it "a check that ran and failed (ExitCode 1) is genuinely unhealthy ⇒ Failed" do
      let
        out = inspectLine "edge" "running"
          ",\"Health\":{\"Status\":\"unhealthy\",\"Log\":[{\"ExitCode\":1,\"Output\":\"wget: can't connect to remote host: Connection refused\"}]}"
        snap = parseDockerInspect names out
      lookupStatus "polyglot:edge" snap `shouldEqual` Just "failed"
      lookupHealth "polyglot:edge" snap `shouldEqual` Just "unhealthy"

    -- real specimen from the mini (minard-backend, 2026-06-18): a connected-but-
    -- non-2xx app check. Exit 8 ≠ -1 and the output names no missing binary, so
    -- it is genuinely unhealthy — NOT mistaken for a broken check.
    it "ExitCode 8 (connected, non-2xx) is genuinely unhealthy ⇒ Failed, not check-error" do
      let
        out = inspectLine "website" "running"
          ",\"Health\":{\"Status\":\"unhealthy\",\"Log\":[{\"ExitCode\":8,\"Output\":\"\"}]}"
        snap = parseDockerInspect names out
      lookupStatus "polyglot:website" snap `shouldEqual` Just "failed"
      lookupHealth "polyglot:website" snap `shouldEqual` Just "unhealthy"

    it "the single-array form (a plain `docker inspect`) is also accepted" do
      let
        out = "[" <> inspectLine "website" "running" ",\"Health\":{\"Status\":\"healthy\",\"Log\":[]}"
          <> "," <> inspectLine "edge" "exited" "" <> "]"
        snap = parseDockerInspect names out
      lookupStatus "polyglot:website" snap `shouldEqual` Just "running"
      lookupStatus "polyglot:edge" snap `shouldEqual` Just "down"

    it "a container with no Health block reads NoCheck (liveness is readiness)" do
      let
        out = inspectLine "website" "running" ""
        snap = parseDockerInspect names out
      lookupStatus "polyglot:website" snap `shouldEqual` Just "running"
      lookupHealth "polyglot:website" snap `shouldEqual` Just "none"

    it "a known service absent from inspect output reads Down (seeded, then overridden)" do
      let
        out = inspectLine "website" "running" ",\"Health\":{\"Status\":\"healthy\",\"Log\":[]}"
        snap = parseDockerInspect names out
      lookupStatus "polyglot:website" snap `shouldEqual` Just "running"
      lookupStatus "polyglot:edge" snap `shouldEqual` Just "down"

    it "empty output ⇒ every known service Down" do
      let snap = parseDockerInspect names ""
      lookupStatus "polyglot:website" snap `shouldEqual` Just "down"
      lookupStatus "polyglot:edge" snap `shouldEqual` Just "down"
