-- | Ingest a docker-compose file (already parsed from YAML to `Json` by the
-- | CLI's js-yaml FFI) into loose `ServiceInstance`s — the *containerised*
-- | facet partner to the registry's native facet.
-- |
-- | Each `services:` entry becomes a `ServiceInstance`: `build`/`image` -> a
-- | `Container` executor, `ports:` -> a `hostPort` reachability (binds every
-- | interface, like `0.0.0.0:p`; else `noNetwork`, behind the edge),
-- | `depends_on:` -> `rawDeps` (array form = `Requires OnStarted`; map
-- | form reads `condition:`), `healthcheck:` presence -> a readiness probe,
-- | `profiles:` -> `Selector`s. Pure; compose runs on the macmini, so the host
-- | is tagged `macmini` (the deploy target — configurable later).
-- |
-- | PHASE 3B SCOPE: unmodeled fields (networks, container_name, build details
-- | beyond context) are dropped rather than stashed in `extra`; the
-- | byte-identical round-trip (`extra` passthrough) is Phase 6.
module Bosun.Adapters.Compose (ingestCompose) where

import Prelude

import Bosun.Artifact (Artifact(..), ArtifactRef(..))
import Bosun.Atoms (AbsPath, EnvVar, Port, mkAbsPath, mkDomain, mkEnvVar, mkGitWorkdir, mkHost, mkPort, mkRoutePath, mkServiceId, mkUrl)
import Bosun.Edge (DepOrdering(..), Gate(..), Requirement(..))
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Publish (PublishChannel(..))
import Bosun.Reachability (Address(..), BindScope(..), Reachability(..), hostPort, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..), RestartPolicy, defaultRestart)
import Bosun.Selector (Selector(..))
import Bosun.Service (RawDep, RawRoute, ServiceInstance, Source(..), mkRole)
import Control.Alt ((<|>))
import Data.Argonaut.Core (Json, fromString, toArray, toNumber, toObject, toString)
import Data.Array as A
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as String
import Data.Tuple (Tuple(..), uncurry)
import Foreign.Object (Object)
import Foreign.Object as FO

ingestCompose :: Json -> Array ServiceInstance
ingestCompose json = fromMaybe [] do
  root <- toObject json
  servicesJson <- FO.lookup "services" root
  services <- toObject servicesJson
  pure (A.mapMaybe (uncurry decodeService) (FO.toUnfoldable services))

decodeService :: String -> Json -> Maybe ServiceInstance
decodeService name sj = do
  o <- toObject sj
  pure
    { source: FromCompose
    , project: Nothing
    , localName: name
    , role: mkRole (roleFromName name)
    , host: Just (mkHost (placeHost o))   -- finest placement level (x-bosun.place last, else x-bosun.host, else default)
    , executor: executorOf name o
    , artifact: xbosunArtifact o   -- declared `x-bosun.artifact` (else reconcile derives it)
    , reachability: fromMaybe (maybe noNetwork hostPort (publishPort o)) (xbosunExpose o)
    , health: let pr = effProbe o in { liveness: pr, readiness: pr, startup: Nothing }
    , restart: restartOf o
    , rawDeps: dependsOn o <> xbosunDeps o
    , rawRoutes: xbosunRoutes o
    , selectors: map Profile (strArray o "profiles")
    , extra: placeExtra o   -- PROTOTYPE carrier for the failure-domain path (View.placePath)
    }

-- | The restart policy: compose's OWN `restart:` key first, refined by
-- | `x-bosun.restart`.
-- |
-- | Compose already has this vocabulary (`no` | `always` | `on-failure` |
-- | `on-failure:N` | `unless-stopped`), so Bosun reads it rather than inventing
-- | a parallel spelling — the lingua-franca claim is worth nothing if the
-- | adapter ignores the source format's own word for the thing. `x-bosun.restart`
-- | adds only what compose CANNOT say: the backoff window, and a retry cap on a
-- | base mode other than `on-failure`.
-- |
-- | A file that declares nothing gets `defaultRestart` — `unless-stopped`,
-- | uncapped — which is exactly what every compose service got before this was
-- | readable, so no existing spec changes behaviour by being re-read.
restartOf :: Object Json -> RestartPolicy
restartOf o = { base, conditions: [], backoff: { minSec, maxRetries } }
  where
  xb = (FO.lookup "x-bosun" o >>= toObject) >>= \x -> FO.lookup "restart" x >>= toObject

  -- `on-failure:3` carries a cap in the same token; everything else is a bare mode.
  native = case String.split (Pattern ":") <$> str o "restart" of
    Just [ mode ] -> { mode: baseOf mode, cap: Nothing }
    Just [ mode, n ] -> { mode: baseOf mode, cap: Int.fromString n }
    _ -> { mode: Nothing, cap: Nothing }

  base = fromMaybe defaultRestart.base
    ((xb >>= \x -> str x "base" >>= baseOf) <|> native.mode)

  minSec = fromMaybe defaultRestart.backoff.minSec (xb >>= \x -> intAt x "minSec")

  maxRetries = (xb >>= \x -> intAt x "maxRetries") <|> native.cap

-- Compose's spelling of the base mode. `no` is compose's word for it and
-- `never` is the model's; both are accepted so a hand-written x-bosun block
-- reads naturally. An unrecognised value falls back to the default rather than
-- failing the ingest — a typo in a restart key must not cost you the whole rig.
baseOf :: String -> Maybe BaseRestart
baseOf = case _ of
  "no" -> Just Never
  "never" -> Just Never
  "always" -> Just Always
  "on-failure" -> Just OnFailure
  "unless-stopped" -> Just UnlessStopped
  _ -> Nothing

intAt :: Object Json -> String -> Maybe Int
intAt ob k = FO.lookup k ob >>= toNumber >>= Int.fromNumber

-- "tidal-frontend" -> "frontend"; "edge" -> "edge"
roleFromName :: String -> String
roleFromName name = fromMaybe name (A.last (String.split (Pattern "-") name))

executorOf :: String -> Object Json -> Executor
executorOf name o = case xbosunStatic o of
  -- `x-bosun.static: { channel, url, … }` declares a static-site deployment
  -- to a CDN; mutually exclusive by intent with process/container, and
  -- checked highest precedence so a stray `image:` on a static service won't
  -- accidentally make Bosun think it's a docker workload.
  Just st -> st
  Nothing -> case xbosunProcess o of
    -- `x-bosun.process: { cwd, command }` declares a NATIVE process, not a
    -- container — so a compose overlay can model a native-process deployment
    -- (dev servers, the Atlantis daemon tier) with all of compose's depends_on
    -- boot-order machinery. Takes precedence; such a service has no image/build.
    Just proc -> proc
    Nothing -> case FO.lookup "image" o >>= toString of
      Just img -> Container (ContainerSpec { source: Left (ImageRef img), internalPort: Nothing, publish: publishPort o })
      Nothing -> case FO.lookup "build" o >>= toObject of
        Just b -> Container (ContainerSpec
          { source: Right (BuildContext { context: fromMaybe "" (str b "context"), dockerfile: str b "dockerfile" })
          , internalPort: Nothing
          , publish: publishPort o
          })
        Nothing -> Unmanaged name

-- | `x-bosun.process: { cwd: <abs>, command: <str>, env?: { K: v } }` → a
-- | `Process` executor. Requires an ABSOLUTE cwd (the SDI footgun, enforced by
-- | `mkAbsPath`); a missing/relative cwd or absent command ⇒ `Nothing` (falls
-- | back to the container/unmanaged path). `env` is optional, typed launch
-- | environment (e.g. rebar3's `ERL_LIBS=_build/default/lib` for a BEAM service)
-- | — irreducible launch knowledge that wants a typed home, not to be buried in
-- | the command string. Mirrors compose's native `environment:` / launchd's
-- | `EnvironmentVariables`.
xbosunProcess :: Object Json -> Maybe Executor
xbosunProcess o = do
  xb <- FO.lookup "x-bosun" o >>= toObject
  pr <- FO.lookup "process" xb >>= toObject
  cwd <- str pr "cwd" >>= mkAbsPath
  command <- str pr "command"
  pure (Process { cwd, command, env: envOf pr })

-- | `x-bosun.static: { channel: "<one of three>", url: "<https://…>", … }` →
-- | a `StaticCDN` executor. The `channel:` string dispatches to the
-- | publish-channel variant; per-channel fields are required for that variant
-- | and unused fields are ignored at ingest. A missing/unknown `channel`, a
-- | missing/invalid `url`, or missing per-channel fields ⇒ `Nothing` (falls
-- | through to the process / container / unmanaged path). The validator's
-- | UrlCollision / ChannelCollision / StaticReadinessMismatch checks then
-- | guard the structural cases past ingest.
-- |
-- | Shapes:
-- |   channel: cloudflare-pages-git
-- |     cfProject, workdir, branch, subdir
-- |   channel: cloudflare-pages-wrangler
-- |     cfProject, artifactDir
-- |   channel: github-pages-repo-dir
-- |     workdir, branch, servingDir
xbosunStatic :: Object Json -> Maybe Executor
xbosunStatic o = do
  xb <- FO.lookup "x-bosun" o >>= toObject
  st <- FO.lookup "static" xb >>= toObject
  channel <- str st "channel"
  url <- str st "url" >>= mkUrl
  publish <- case channel of
    "cloudflare-pages-git" -> do
      cfProject <- str st "cfProject"
      workdir <- str st "workdir" >>= mkGitWorkdir
      branch <- str st "branch"
      let subdir = fromMaybe "" (str st "subdir")
      pure (CloudflarePagesGit { cfProject, workdir, branch, subdir })
    "cloudflare-pages-wrangler" -> do
      cfProject <- str st "cfProject"
      artifactDir <- str st "artifactDir" >>= mkAbsPath
      pure (CloudflarePagesWrangler { cfProject, artifactDir })
    "github-pages-repo-dir" -> do
      workdir <- str st "workdir" >>= mkGitWorkdir
      branch <- str st "branch"
      let servingDir = fromMaybe "" (str st "servingDir")
      pure (GitHubPagesRepoDir { workdir, branch, servingDir })
    _ -> Nothing
  pure (StaticCDN { publish, url })

-- | `x-bosun.artifact: { kind, source, pin? }` → the DECLARED artifact
-- | (docs/ARTIFACTS.md): the single content declaration `reconcile` prefers over
-- | the heuristic `artifactOf`. `kind` ∈ static-dir | binary | bundle(+runtime)
-- | | source-build | image; `pin` is an optional digest/revision/tag that fixes
-- | "what content". Absent or unknown-kind ⇒ `Nothing` (reconcile derives it
-- | from the executor instead).
xbosunArtifact :: Object Json -> Maybe Artifact
xbosunArtifact o = do
  xb <- FO.lookup "x-bosun" o >>= toObject
  a <- FO.lookup "artifact" xb >>= toObject
  kind <- str a "kind"
  source <- str a "source"
  let ref = ArtifactRef { source, pin: str a "pin" }
  case kind of
    "static-dir" -> Just (StaticDir ref)
    "binary" -> Just (Binary ref)
    "bundle" -> Just (BundleRuntime ref)
    "bundle+runtime" -> Just (BundleRuntime ref)
    "source-build" -> Just (SourceBuild ref)
    "image" -> Just (Image ref)
    _ -> Nothing

-- `x-bosun.process.env { KEY: "val", … }` → typed launch env. Non-string values
-- are skipped (launch env is strings); absent ⇒ `[]`.
envOf :: Object Json -> Array (Tuple EnvVar String)
envOf pr = case FO.lookup "env" pr >>= toObject of
  Nothing -> []
  Just eo -> A.mapMaybe pair (FO.toUnfoldable eo :: Array (Tuple String Json))
  where
  pair (Tuple k vj) = (\v -> Tuple (mkEnvVar k) v) <$> toString vj

-- first "host:container" entry -> the published host port
publishPort :: Object Json -> Maybe Port
publishPort o = do
  pj <- FO.lookup "ports" o
  ps <- toArray pj
  first <- A.head ps
  s <- toString first
  hostPart <- A.head (String.split (Pattern ":") s)
  Int.fromString hostPart >>= mkPort

-- a healthcheck present -> a (non-NoProbe) readiness signal
probeOf :: Object Json -> Probe
probeOf o = if isJust (FO.lookup "healthcheck" o) then ExecCmd (healthTest o) else NoProbe

-- | The effective probe: an explicit `x-bosun.probe` overrides the healthcheck.
-- | `process` ⇒ `ProcessAlive` (observe by process existence — the right signal
-- | for a UDP/socket/no-network daemon a TCP probe would mis-read; the es9/link
-- | OSC daemons and the fh2 socket daemon). `socket` ⇒ `SocketReady` if an
-- | `x-bosun.expose [{socket}]` is present. `http` ⇒ `HttpGet` with sane HTTPS
-- | defaults (port 443, path "/", expect 200) — the right signal for a
-- | StaticCDN service whose probe target is the live URL; the prober uses the
-- | URL from the executor, not these placeholder fields. Else fall back to
-- | the healthcheck.
effProbe :: Object Json -> Probe
effProbe o = case (FO.lookup "x-bosun" o >>= toObject) >>= \xb -> str xb "probe" of
  Just "process" -> ProcessAlive
  -- `exec` ⇒ run `x-bosun.check` on the host and read its exit code. The probe
  -- to reach for when the service is a SINGLETON someone else might have
  -- started (a hand-start, a `deepstar up`, a previous session): it asks "is it
  -- up" rather than `process`'s "did I start it", and so does not answer Down
  -- about a daemon that is plainly running and then lose a bind race to it.
  Just "exec" -> maybe (probeOf o) HostExec (checkCmd o)
  Just "socket" -> maybe (probeOf o) SocketReady (socketAddr o)
  Just "http" -> maybe NoProbe (\p -> HttpGet { port: p, path: "/", expectStatus: 200 }) (mkPort 443)
  _ -> probeOf o

-- `x-bosun.check`, the command line the `exec` probe runs. Accepts docker's
-- `test:` array form (with or without a leading CMD/CMD-SHELL, which the prober
-- strips) and a bare string for the common one-liner.
checkCmd :: Object Json -> Maybe (Array String)
checkCmd o = do
  xb <- FO.lookup "x-bosun" o >>= toObject
  j <- FO.lookup "check" xb
  cmd <- (toArray j <#> A.mapMaybe toString) <|> (toString j <#> \line -> [ "CMD-SHELL", line ])
  if A.null cmd then Nothing else Just cmd

-- the first unix-socket path in `x-bosun.expose`, if any
socketAddr :: Object Json -> Maybe AbsPath
socketAddr o = do
  xb <- FO.lookup "x-bosun" o >>= toObject
  arr <- FO.lookup "expose" xb >>= toArray
  A.head (A.mapMaybe (\j -> toObject j >>= \ob -> str ob "socket" >>= mkAbsPath) arr)

healthTest :: Object Json -> Array String
healthTest o = fromMaybe [] do
  hc <- FO.lookup "healthcheck" o >>= toObject
  arr <- FO.lookup "test" hc >>= toArray
  pure (A.mapMaybe toString arr)

dependsOn :: Object Json -> Array RawDep
dependsOn o = case FO.lookup "depends_on" o of
  Nothing -> []
  Just dj -> case toArray dj of
    Just arr -> A.mapMaybe (\x -> toString x <#> \n -> rawDep n OnStarted) arr
    Nothing -> case toObject dj of
      Just obj -> map (uncurry (\n cj -> rawDep n (gateOf cj))) (FO.toUnfoldable obj)
      Nothing -> []

rawDep :: String -> Gate -> RawDep
rawDep n gate = { to: n, ordering: Just StartAfter, requirement: Just (Requires gate) }

gateOf :: Json -> Gate
gateOf cj = case toObject cj >>= str' "condition" of
  Just "service_healthy" -> OnHealthy
  Just "service_completed_successfully" -> OnCompleted
  _ -> OnStarted
  where
  str' k ob = FO.lookup k ob >>= toString

-- | The full requirement gradient compose can't natively express, carried in a
-- | service's `x-bosun.requires:` map (target -> kind). compose `x-` keys are
-- | the sanctioned home for "the stuff that has no other format" (the overlay
-- | philosophy, applied inline). Each entry adds a typed dependency edge:
-- |
-- |   web:
-- |     x-bosun:
-- |       requires:
-- |         logger-sidecar: binds-to     # ●●-side of the §4.3 gradient
-- |         external-vault: requisite
-- |         metrics: wants
xbosunDeps :: Object Json -> Array RawDep
xbosunDeps o = fromMaybe [] do
  xb <- FO.lookup "x-bosun" o >>= toObject
  reqs <- FO.lookup "requires" xb >>= toObject
  pure (map (uncurry (\n kj -> typedDep n (fromMaybe "requires" (toString kj)))) (FO.toUnfoldable reqs))

typedDep :: String -> String -> RawDep
typedDep n kind = { to: n, ordering: Just StartAfter, requirement: Just (reqOf kind) }

reqOf :: String -> Requirement
reqOf = case _ of
  "wants" -> Wants
  "requisite" -> Requisite
  "binds-to" -> BindsTo
  "part-of" -> PartOf
  _ -> Requires OnStarted

-- | Reverse-proxy routes (the traffic channel, §3.6/D-5) — compose has no native
-- | place for them, so they ride in `x-bosun.routes: [{ path, to }]`. Each is a
-- | data/traffic edge from this (proxy) service to a backend, NOT a lifecycle
-- | edge — kept in a separate graph.
xbosunRoutes :: Object Json -> Array RawRoute
xbosunRoutes o = fromMaybe [] do
  xb <- FO.lookup "x-bosun" o >>= toObject
  arr <- FO.lookup "routes" xb >>= toArray
  pure (A.mapMaybe decodeRoute arr)
  where
  decodeRoute rj = do
    ro <- toObject rj
    to <- str ro "to"
    path <- str ro "path"
    pure { to, path: mkRoutePath path }

-- | `x-bosun.expose: [ {host|internal|loopback: <port>} | {socket: <path>} |
-- |   {domain: <name>} | {proxy: <id>, path: <p>} ]` — the full reachability the
-- | compose `ports:` default (always `0.0.0.0`, i.e. `host`) can't express:
-- | bind scope (loopback / internal), unix sockets, public domains, and
-- | COMPOSITION (a Set of addresses). Present ⇒ REPLACES the ports default.
xbosunExpose :: Object Json -> Maybe Reachability
xbosunExpose o = do
  xb <- FO.lookup "x-bosun" o >>= toObject
  arr <- FO.lookup "expose" xb >>= toArray
  pure (Reachability (Set.fromFoldable (A.mapMaybe decodeAddress arr)))

decodeAddress :: Json -> Maybe Address
decodeAddress j = do
  o <- toObject j
  listen o "host" AllIfaces
    <|> listen o "internal" Internal
    <|> listen o "loopback" Loopback
    <|> (Socket <$> (str o "socket" >>= mkAbsPath))
    <|> (Published <<< mkDomain <$> str o "domain")
    <|> proxied o
  where
  listen ob key scope = (\p -> Listening { bind: scope, port: p }) <$> portAt ob key
  proxied ob = do
    pid <- str ob "proxy"
    pth <- str ob "path"
    pure (Proxied { proxy: mkServiceId pid, path: mkRoutePath pth })

portAt :: Object Json -> String -> Maybe Port
portAt o key = FO.lookup key o >>= toNumber >>= Int.fromNumber >>= mkPort

-- | `x-bosun.host: <name>` — place a compose service on a named host (else the
-- | default deploy target). Lets a single fixture span hosts for the
-- | placement / cross-host-edge / co-location experiments.
xbosunHost :: Object Json -> Maybe String
xbosunHost o = (FO.lookup "x-bosun" o >>= toObject) >>= \xb -> str xb "host"

-- | `x-bosun.place: [coarse, …, fine]` — the failure-domain PATH (e.g.
-- | `[mini-1, data-1]`: host data-1 lives on machine mini-1). Co-location is a
-- | shared prefix; two hosts on one machine share level 0 → an illusory mirror
-- | is visible spatially. Falls back to `x-bosun.host` (single level).
xbosunPlace :: Object Json -> Array String
xbosunPlace o = fromMaybe [] do
  xb <- FO.lookup "x-bosun" o >>= toObject
  arr <- FO.lookup "place" xb >>= toArray
  pure (A.mapMaybe toString arr)

-- finest placement level → the `host` atom (keeps cross-host marking working)
placeHost :: Object Json -> String
placeHost o = case A.last (xbosunPlace o) of
  Just h -> h
  Nothing -> fromMaybe "macmini" (xbosunHost o)

-- PROTOTYPE: stash the path in extra["place"] as a "/"-joined string for
-- View.placePath to read, pending a first-class core `Placement` field.
placeExtra :: Object Json -> Map.Map String Json
placeExtra o = case xbosunPlace o of
  p | not (A.null p) -> Map.singleton "place" (fromString (String.joinWith "/" p))
  _ -> Map.empty

strArray :: Object Json -> String -> Array String
strArray o k = fromMaybe [] (FO.lookup k o >>= toArray <#> A.mapMaybe toString)

str :: Object Json -> String -> Maybe String
str o k = FO.lookup k o >>= toString
