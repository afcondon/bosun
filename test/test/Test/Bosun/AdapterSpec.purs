-- | The ingestion edge: parsing `startCommand` strings into `Executor`s, and
-- | decoding the registry `/api/ports` JSON into loose `ServiceInstance`s.
module Test.Bosun.AdapterSpec where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Adapters.StartCommand (parseStartCommand)
import Bosun.Adapters.Targets (ingestTargets)
import Bosun.Artifact (Artifact(..), ArtifactRef(..))
import Bosun.Atoms (mkEnvVar, mkHost, unAbsPath)
import Bosun.Executor (Executor(..), ExecutorMechanism(..), mechanism)
import Bosun.Health (BaseRestart(..), Probe(..))
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

    it "x-bosun.process { cwd, command } => a native Process executor, not a Container" do
      let
        pf = """{"services":{
          "es9-daemon":{"x-bosun":{"host":"mbp","process":{"cwd":"/abs/es9","command":"./run"},"expose":[{"host":57120}]}},
          "purerl-tidal":{"depends_on":["es9-daemon"],"x-bosun":{"host":"mbp","process":{"cwd":"/abs/tidal","command":"erl -noshell"}}}
        }}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> do
          let svcs = ingestCompose j
          case find (\s -> s.localName == "es9-daemon") svcs of
            Nothing -> fail "es9-daemon not ingested"
            Just s -> do
              mechanism s.executor `shouldEqual` MechProcess
              exposureLabel (classify s.reachability) `shouldEqual` "host:57120"
          -- depends_on still wires the boot DAG for a Process service
          case find (\s -> s.localName == "purerl-tidal") svcs of
            Nothing -> fail "purerl-tidal not ingested"
            Just s -> map _.to s.rawDeps `shouldEqual` [ "es9-daemon" ]

    it "x-bosun.process.env { K: v } parses into the Process executor's typed env" do
      let pf = """{"services":{
        "tidal":{"x-bosun":{"host":"mbp","process":{"cwd":"/abs/tidal","command":"erl -pa ebin","env":{"ERL_LIBS":"_build/default/lib"}}}}
      }}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "tidal") (ingestCompose j) of
          Nothing -> fail "tidal not ingested"
          Just s -> case s.executor of
            Process p -> p.env `shouldEqual` [ Tuple (mkEnvVar "ERL_LIBS") "_build/default/lib" ]
            _ -> fail "expected a Process executor"

    it "x-bosun.artifact { kind, source, pin } parses into a declared Artifact" do
      let pf = """{"services":{
        "website":{"build":{"context":"../site/web"},"x-bosun":{"host":"macmini","artifact":{"kind":"image","source":"hylograph/website","pin":"sha256:abc"}}}
      }}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "website") (ingestCompose j) of
          Nothing -> fail "website not ingested"
          Just s -> case s.artifact of
            Just (Image (ArtifactRef r)) -> do
              r.source `shouldEqual` "hylograph/website"
              r.pin `shouldEqual` Just "sha256:abc"
            _ -> fail "expected a declared Image artifact"

    it "a relative or missing x-bosun.process cwd is NOT a Process (falls through to Unmanaged)" do
      let pf = """{"services":{"bad":{"x-bosun":{"process":{"cwd":"relative/dir","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "bad") (ingestCompose j) of
          Nothing -> fail "bad not ingested"
          Just s -> mechanism s.executor `shouldEqual` MechUnmanaged

    -- The honest probe for a UDP/no-network daemon: a TCP probe of its (UDP) port
    -- would mis-read it, so `x-bosun.probe: process` selects process-existence.
    it "x-bosun.probe: process => a ProcessAlive readiness probe (overrides the port)" do
      let pf = """{"services":{"d":{"x-bosun":{"host":"mbp","probe":"process","process":{"cwd":"/abs/d","command":"./run"},"expose":[{"host":57120}]}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> do
            (s.health.readiness == ProcessAlive) `shouldEqual` true
            (s.health.liveness == ProcessAlive) `shouldEqual` true

    -- The exec probe: the only reading that answers "is it up, WHOEVER started
    -- it". `process` asks "is the group I recorded alive", which is Down for a
    -- perfectly healthy hand-started daemon — and a supervisor that believes
    -- that launches a second copy into a bind it cannot win.

    it "x-bosun.probe: exec => a HostExec probe carrying the check" do
      let pf = """{"services":{"d":{"x-bosun":{"probe":"exec","check":["CMD","lsof","-i","UDP:57130"],"process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> (s.health.readiness == HostExec [ "CMD", "lsof", "-i", "UDP:57130" ]) `shouldEqual` true

    it "a bare-string check is accepted as a shell line" do
      let pf = """{"services":{"d":{"x-bosun":{"probe":"exec","check":"lsof -i UDP:57130","process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> (s.health.readiness == HostExec [ "CMD-SHELL", "lsof -i UDP:57130" ]) `shouldEqual` true

    it "probe: exec with no check falls back rather than probing an empty line" do
      -- An empty command line would exit 0 in a shell and read every service as
      -- up — the most dangerous possible default for a liveness probe.
      let pf = """{"services":{"d":{"x-bosun":{"probe":"exec","process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> (s.health.readiness == NoProbe) `shouldEqual` true

    -- Restart policy. Before this was readable, EVERY compose service was
    -- ingested as retry-forever, whatever the file said — which is how
    -- `fh2-daemon` came to be relaunched 2,912 times with the module switched
    -- off. Compose has its own vocabulary for this and Bosun now reads it.

    it "compose's own restart: key is read (no => Never)" do
      let pf = """{"services":{"d":{"restart":"no","x-bosun":{"process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> (s.restart.base == Never) `shouldEqual` true

    it "the on-failure:N form carries its retry cap" do
      let pf = """{"services":{"d":{"restart":"on-failure:3","x-bosun":{"process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> do
            (s.restart.base == OnFailure) `shouldEqual` true
            s.restart.backoff.maxRetries `shouldEqual` Just 3

    it "x-bosun.restart adds the backoff window compose cannot say" do
      let pf = """{"services":{"d":{"restart":"on-failure","x-bosun":{"restart":{"minSec":30,"maxRetries":5},"process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> do
            (s.restart.base == OnFailure) `shouldEqual` true
            s.restart.backoff.minSec `shouldEqual` 30
            s.restart.backoff.maxRetries `shouldEqual` Just 5

    it "a service that declares nothing keeps the old retry-forever behaviour" do
      let pf = """{"services":{"d":{"x-bosun":{"process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> do
            (s.restart.base == UnlessStopped) `shouldEqual` true
            s.restart.backoff.maxRetries `shouldEqual` Nothing

    it "an unrecognised restart value falls back rather than failing the ingest" do
      -- A typo in one restart key must not cost you the whole rig.
      let pf = """{"services":{"d":{"restart":"sometimes","x-bosun":{"process":{"cwd":"/abs/d","command":"./run"}}}}}"""
      case jsonParser pf of
        Left e -> fail ("fixture did not parse: " <> e)
        Right j -> case find (\s -> s.localName == "d") (ingestCompose j) of
          Nothing -> fail "d not ingested"
          Just s -> (s.restart.base == UnlessStopped) `shouldEqual` true

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
