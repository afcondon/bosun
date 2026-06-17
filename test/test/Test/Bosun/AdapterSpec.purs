-- | The ingestion edge: parsing `startCommand` strings into `Executor`s, and
-- | decoding the registry `/api/ports` JSON into loose `ServiceInstance`s.
module Test.Bosun.AdapterSpec where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Adapters.StartCommand (parseStartCommand)
import Bosun.Adapters.Targets (ingestTargets)
import Bosun.Atoms (mkHost, unAbsPath)
import Bosun.Executor (Executor(..), ExecutorMechanism(..), mechanism)
import Bosun.Health (Probe(..))
import Bosun.Reachability (classify)
import Bosun.Reconcile (exposureLabel)
import Bosun.Selector (Selector(..))
import Bosun.Target (ExecLoc(..), resolveTarget, unSshDest)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (find, length)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

spec :: Spec Unit
spec = describe "Bosun.Adapters" do

  describe "parseStartCommand" do
    it "parses 'cd /abs && cmd' into a Process with that cwd and command" do
      case parseStartCommand "cd /Users/afc/work/x && npx serve public -p 3013" of
        Process p -> do
          unAbsPath p.cwd `shouldEqual` "/Users/afc/work/x"
          p.command `shouldEqual` "npx serve public -p 3013"
        _ -> fail "expected a Process"

    it "keeps a multi-&& tail as the command" do
      case parseStartCommand "cd /a && make build && make start" of
        Process p -> p.command `shouldEqual` "make build && make start"
        _ -> fail "expected a Process"

    it "the SDI footgun 'node router.mjs' (no cd) is Unmanaged, not a Process" do
      case parseStartCommand "node router.mjs" of
        Unmanaged _ -> pure unit
        _ -> fail "expected Unmanaged (no absolute cwd anchor)"

    it "an empty/NULL command is Unmanaged" do
      case parseStartCommand "" of
        Unmanaged _ -> pure unit
        _ -> fail "expected Unmanaged"

  describe "ingestRegistry" do
    let
      fixture =
        """{"servers":[
          {"role":"frontend","projectSlug":"urj","projectName":"tilted-radio","port":3013,"host":"mbp","startCommand":"cd /x && npx serve"},
          {"role":"api","projectSlug":"minard","projectName":"minard","port":3000,"host":"mbp","startCommand":""}
        ]}"""

    it "decodes each server row into a ServiceInstance" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let svcs = ingestRegistry j
          length svcs `shouldEqual` 2
          map _.localName svcs `shouldEqual` [ "tilted-radio", "minard" ]
          map (exposureLabel <<< classify <<< _.reachability) svcs `shouldEqual` [ "host:3013", "host:3000" ]
          map (mechanism <<< _.executor) svcs `shouldEqual` [ MechProcess, MechUnmanaged ]

  describe "ingestCompose" do
    let
      fixture =
        """{"services":{
          "tidal-frontend":{"profiles":["tidal","full"],"build":{"context":"../x/psd3-tilted-radio"},"healthcheck":{"test":["CMD","wget","-q","http://localhost/"]}},
          "tidal-backend":{"profiles":["tidal","full"],"build":{"context":"../x/purerl-tidal"},"ports":["3012:3012"],"healthcheck":{"test":["CMD","wget"]}},
          "edge":{"profiles":["full"],"build":{"context":"../x/edge"},"ports":["80:80"],"depends_on":["website"]}
        }}"""

    it "decodes services with build => Container, ports => HostPort, healthcheck => readiness" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let svcs = ingestCompose j
          length svcs `shouldEqual` 3
          case find (\s -> s.localName == "tidal-backend") svcs of
            Nothing -> fail "tidal-backend not ingested"
            Just s -> do
              exposureLabel (classify s.reachability) `shouldEqual` "host:3012"
              mechanism s.executor `shouldEqual` MechContainer
              (s.health.readiness == NoProbe) `shouldEqual` false   -- healthcheck => a probe

    it "decodes depends_on (array form) into a Requires-OnStarted edge" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j ->
          case find (\s -> s.localName == "edge") (ingestCompose j) of
            Nothing -> fail "edge not ingested"
            Just s -> map _.to s.rawDeps `shouldEqual` [ "website" ]

    it "decodes profiles into Selectors; a portless service is NoNetwork (behind the edge)" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j ->
          case find (\s -> s.localName == "tidal-frontend") (ingestCompose j) of
            Nothing -> fail "tidal-frontend not ingested"
            Just s -> do
              s.selectors `shouldEqual` [ Profile "tidal", Profile "full" ]
              exposureLabel (classify s.reachability) `shouldEqual` "none"

  describe "ingestTargets" do
    let
      fixture =
        """{
          "macmini": {"ssh":"andrew@andrews-mac-mini","address":"andrews-mac-mini","workdir":"/Users/andrew/psd3/polyglot-deploy","env":{"PATH":"/usr/local/bin:$PATH"}},
          "buildbox": {"workdir":"/srv"}
        }"""

    it "decodes an ssh host into a RemoteSsh target with workdir + env prefix" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let t = resolveTarget (ingestTargets j) (Just (mkHost "macmini"))
          case t.exec of
            RemoteSsh d -> unSshDest d `shouldEqual` "andrew@andrews-mac-mini"
            LocalExec -> fail "expected RemoteSsh"
          t.address `shouldEqual` "andrews-mac-mini"
          map unAbsPath t.workdir `shouldEqual` Just "/Users/andrew/psd3/polyglot-deploy"
          t.envPrefix `shouldEqual` [ Tuple "PATH" "/usr/local/bin:$PATH" ]

    it "a host with no ssh key is LocalExec; address defaults to the host name" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let t = resolveTarget (ingestTargets j) (Just (mkHost "buildbox"))
          case t.exec of
            LocalExec -> pure unit
            RemoteSsh _ -> fail "expected LocalExec (no ssh key)"
          t.address `shouldEqual` "buildbox"

    it "an unmapped host resolves to the safe local default (never an accidental ssh)" do
      case jsonParser fixture of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let t = resolveTarget (ingestTargets j) (Just (mkHost "unknown-host"))
          case t.exec of
            LocalExec -> pure unit
            RemoteSsh _ -> fail "expected LocalExec for an unmapped host"
