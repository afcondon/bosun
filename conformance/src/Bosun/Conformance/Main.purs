-- | purescript-go conformance harness (BUILD-PLAN Phase 4).
-- |
-- | The pure Detect pipeline over a fixed fixture, printed. No I/O beyond the
-- | final `log`, so this compiles on any backend that supports the pure-core
-- | library surface. Run via node AND via backend-go; the output must be
-- | byte-identical (the signal-box conformance pattern). The fixture mirrors
-- | the CLI demo: the §7 tilted-radio two-facet divergence + a minard tier
-- | with an uncheckable gate.
module Bosun.Conformance.Main where

import Prelude

import Bosun.Atoms (AbsPath, Port, mkAbsPath, mkHost, mkPort, mkProjectId, mkServiceId)
import Bosun.Edge (Gate(..), Requirement(..))
import Bosun.Executor (ContainerSpec(..), Executor(..), ImageRef(..))
import Bosun.Reachability (hostPort, noNetwork)
import Bosun.Health (BaseRestart(..), Probe(..))
import Bosun.Holding (ReapVerdict(..), holdingJson, holdingScript, judgeHolding, readHoldingEvidence, readReap, reapScript, reapTag, settleTeardown, strangers)
import Bosun.Substrate (TeardownVerdict(..), teardownTag)
import Bosun.Apply (applyScript)
import Bosun.Target (defaultTargets)
import Bosun.Plan (Snapshot, Status(..), plan)
import Bosun.Reconcile (reconcile)
import Bosun.Report (renderPlan, renderReport, renderScript)
import Bosun.Service (ServiceInstance, Source(..), ValidatedDeployment, mkRole)
import Bosun.Validate (validate)
import Data.Either (Either(..), either)
import Data.Foldable (intercalate)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, maybe)
import Data.Tuple (Tuple(..), snd)
import Data.Validation.Semigroup (toEither)
import Effect (Effect)
import Effect.Console (log)
import Partial.Unsafe (unsafePartial)

main :: Effect Unit
main = do
  let
    aliases = Map.singleton "tidal-frontend" (mkServiceId "82:frontend")
    r = reconcile aliases fixture
    vErrors = either identity (const []) (toEither (validate r.deployment))
  log (renderReport { conflicts: r.conflicts, divergences: r.divergences } vErrors)
  log ""
  log "--- plan over a valid fixture + observed snapshot ---"
  log planReport
  log ""
  log "--- apply script for the same plan (Phase 6B) ---"
  log applyReport
  log ""
  log "--- who holds each port (Bosun.Holding) ---"
  log holdingReport

-- | The plan column (BUILD-PLAN Phase 5). A clean three-tier deployment that
-- | validates, against an observed snapshot where the api crashed: the base
-- | pass turns `Failed` into `Restart … Crashed`, and D-E5 propagates a `Stop`
-- | backward along the worker's `BindsTo` edge — all pure, so node and
-- | backend-go must render this byte-identically too.
planReport :: String
planReport = withPlanFixture \vd ->
  renderPlan (plan vd { desired: vd, recorded: Nothing, observed: planObserved })

-- | The apply column (BUILD-PLAN Phase 6B). The *same* plan rendered as the
-- | command script `apply` would run — pure `Plan -> Array StagedCommand`, so
-- | the backend-go binary must emit the byte-identical docker/ssh/process
-- | script the node binary does. This is the headline claim, gated.
applyReport :: String
applyReport = withPlanFixture \vd ->
  renderScript (applyScript defaultTargets vd (plan vd { desired: vd, recorded: Nothing, observed: planObserved }))

withPlanFixture :: (ValidatedDeployment -> String) -> String
withPlanFixture f = case toEither (validate (reconcile Map.empty planFixture).deployment) of
  Left _ -> "plan fixture failed to validate (should not happen)"
  Right vd -> f vd

planObserved :: Snapshot
planObserved = Map.fromFoldable
  [ Tuple (mkServiceId "store:db") Running
  , Tuple (mkServiceId "store:api") Failed
  , Tuple (mkServiceId "store:worker") Running
  ]

planFixture :: Array ServiceInstance
planFixture =
  [ inst
      { source = FromRegistry
      , project = Just (mkProjectId "store")
      , localName = "store-db"
      , role = mkRole "db"
      , reachability = hostPort (port_ 5432)
      , executor = Process { cwd: absPath "/srv/store-db", command: "postgres", env: [] }
      , health = inst.health { readiness = TcpConnect (port_ 5432) }
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectId "store")
      , localName = "store-api"
      , role = mkRole "api"
      , reachability = hostPort (port_ 3000)
      , executor = Process { cwd: absPath "/srv/store-api", command: "node server.js", env: [] }
      , health = inst.health { readiness = HttpGet { port: port_ 3000, path: "/health", expectStatus: 200 } }
      , rawDeps = [ { to: "store:db", ordering: Nothing, requirement: Just (Requires OnReady) } ]
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectId "store")
      , localName = "store-worker"
      , role = mkRole "worker"
      , reachability = noNetwork
      , executor = Process { cwd: absPath "/srv/store-worker", command: "node worker.js", env: [] }
      , rawDeps = [ { to: "store:api", ordering: Nothing, requirement: Just BindsTo } ]
      }
  ]

fixture :: Array ServiceInstance
fixture =
  [ inst
      { source = FromRegistry
      , project = Just (mkProjectId "82")
      , localName = "psd3-tilted-radio"
      , host = Just (mkHost "mbp")
      , executor = Process { cwd: absPath "/Users/afc/work/afc-work/purescript-hylograph-showcases/psd3-tilted-radio", command: "npx serve", env: [] }
      , reachability = hostPort (port_ 3013)
      }
  , inst
      { source = FromCompose
      , localName = "tidal-frontend"
      , host = Just (mkHost "macmini")
      , executor = Container (ContainerSpec { source: Left (ImageRef "tidal-frontend"), internalPort: Nothing, publish: Nothing })
      , reachability = noNetwork
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectId "35")
      , localName = "minard-backend"
      , role = mkRole "api"
      , host = Just (mkHost "mbp")
      , reachability = hostPort (port_ 3000)
      }
  , inst
      { source = FromRegistry
      , project = Just (mkProjectId "35")
      , localName = "minard-frontend"
      , host = Just (mkHost "mbp")
      , reachability = hostPort (port_ 3001)
      , rawDeps = [ { to: "35:api", ordering: Nothing, requirement: Just (Requires OnHealthy) } ]
      }
  ]

inst :: ServiceInstance
inst =
  { source: FromRegistry
  , project: Nothing
  , localName: "svc"
  , role: mkRole "frontend"
  , host: Just (mkHost "mbp")
  , executor: Unmanaged "svc"
  , artifact: Nothing
  , reachability: noNetwork
  , health: { liveness: NoProbe, readiness: NoProbe, startup: Nothing }
  , restart: { base: Never, conditions: [], backoff: { minSec: 1, maxRetries: Nothing } }
  , rawDeps: []
  , rawRoutes: []
  , selectors: []
  , extra: Map.empty
  }

absPath :: String -> AbsPath
absPath s = unsafePartial (fromJust (mkAbsPath s))

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

-- | The ownership column (docs/FINDINGS-restart-ok-on-orphan.md). Evidence
-- | shaped like what the host printed on 2026-09-25 — the orphan on :3029, an
-- | owned process, a split bind — parsed, judged, rendered, and the scripts
-- | that gather and act on it. The Go column is the reference runtime, so the
-- | verdict that decides whether a restart may stop a process must lower to it
-- | byte-identically.
holdingReport :: String
holdingReport =
  intercalate "\n"
    ( map line cases
        <> [ holdingScript [ hp 3029, hp 3040 ] [ { sid: mkServiceId "friends-of-itajara", cwd: Just dir }, { sid: mkServiceId "a:b", cwd: Nothing } ]
           , reapScript orphans
           , intercalate " " (map (reapTag <<< snd) (readReap "bosun-reap:94743:reaped" orphans))
           , settled NoRecord StrangerReaped
           , settled AlreadyGone StrangerRefused
           ]
    )
  where
  dir = "/Users/afc/work/afc-work/music/friends-of-itajara"
  hp n = unsafePartial (fromJust (mkPort n))
  ev = readHoldingEvidence
    { ran: true
    , output: intercalate "\n"
        [ "#listen", "p94743", "n127.0.0.1:3029", "p77387", "n*:3030", "p5001", "n127.0.0.1:3040", "p6002", "n[::1]:3040"
        , "#ps"
        , "94743 94743 Sun Sep 20 11:34:15 2026 node server.mjs"
        , "77387 77380 Fri Sep 25 18:55:32 2026 node \"quoted\" server.mjs"
        , " 5001  5000 Fri Sep 25 10:00:00 2026 python3 -m http.server 3040"
        , " 6002  6002 Tue Sep 01 09:00:00 2026 python3 -m http.server 3040"
        , "#cwd", "p94743", "n" <> dir, "p77387", "n" <> dir, "p5001", "n/srv/site", "p6002", "n/somewhere/else"
        , "#recorded", "friends-of-itajara\t77380", "friend-b\t77380", "site\t5000", "#end"
        ]
    }
  cases =
    [ Tuple "orphan, claimable" { sid: mkServiceId "friends-of-itajara", ports: [ hp 3029 ], cwd: Just dir }
    , Tuple "orphan, foreign" { sid: mkServiceId "friends-of-itajara", ports: [ hp 3029 ], cwd: Just "/elsewhere" }
    , Tuple "ours" { sid: mkServiceId "friend-b", ports: [ hp 3030 ], cwd: Just dir }
    , Tuple "split bind" { sid: mkServiceId "site", ports: [ hp 3040 ], cwd: Just "/srv/site" }
    , Tuple "unheld" { sid: mkServiceId "nobody", ports: [ hp 3999 ], cwd: Nothing }
    , Tuple "no port" { sid: mkServiceId "nobody", ports: [], cwd: Nothing }
    ]
  line (Tuple label svc) = label <> ": " <> holdingJson (judgeHolding ev svc)
  claimed = judgeHolding ev { sid: mkServiceId "friends-of-itajara", ports: [ hp 3029 ], cwd: Just dir }
  settled own rv =
    let r = settleTeardown own claimed (map (\h -> Tuple h rv) (strangers claimed))
    in "down: " <> teardownTag own <> " + stranger " <> reapTag rv <> " -> " <> teardownTag r.verdict
         <> maybe "" (" — " <> _) r.note
  orphans = strangers (judgeHolding ev { sid: mkServiceId "friends-of-itajara", ports: [ hp 3029 ], cwd: Just dir })
