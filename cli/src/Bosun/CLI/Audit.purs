-- | `bosun serve --audit [registry]` (BOSUN-SERVE.md §5, P2) — a one-shot
-- | spawn-test of every admitted route, WITHOUT becoming resident.
-- |
-- | For each routable service it spawns the backend (on the internal port, so it
-- | can't collide with whatever holds the public port), waits for it to bind,
-- | records up/down + elapsed, then tears it down. This is the diagnostic that
-- | answers "would `serve` actually be able to bring each of these up?" before
-- | you cut over from SDI — and the spine of the chaos/stress harness.
-- |
-- | Pure admission (`servePlan`) decides WHAT to test; the effectful probing is
-- | one foreign (`auditImpl`), mirroring the serve shim's spawn + readiness.
module Bosun.CLI.Audit
  ( runAudit
  ) where

import Prelude

import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.CLI.IO (readJsonFile, readJsonUrl)
import Bosun.CLI.Serve (registryUrl)
import Bosun.Reconcile (reconcile)
import Bosun.Serve (Route, servePlan)
import Bosun.Version (version)
import Data.Array as A
import Data.Foldable (traverse_)
import Data.Map as Map
import Data.Maybe (Maybe, maybe)
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)

type AuditResult =
  { serviceId :: String, publicPort :: Int, ok :: Boolean, ms :: Int, message :: String }

-- Spawn each route's backend, wait for its internal port, tear it down; return a
-- result per route. Sequential and self-cleaning.
foreign import auditImpl :: EffectFn1 (Array Route) (Array AuditResult)

runAudit :: Maybe String -> Effect Unit
runAudit src = do
  registryJson <- maybe (readJsonUrl registryUrl) readJsonFile src
  let
    plan = servePlan (reconcile Map.empty (ingestRegistry registryJson)).deployment
    label = maybe (registryUrl <> " (live)") identity src
  log ("bosun " <> version <> " — serve --audit " <> label)
  log ""
  log ("auditing " <> show (A.length plan.routes) <> " routable service(s) — spawn, probe, tear down:")
  log ""
  results <- runEffectFn1 auditImpl plan.routes
  traverse_ (log <<< renderResult) results
  let
    up = A.length (A.filter _.ok results)
    down = A.length results - up
  log ""
  log ("audit: " <> show up <> " came up, " <> show down <> " did NOT"
        <> " (" <> show (A.length plan.redirects) <> " remote/redirect, "
        <> show (A.length plan.rejected) <> " not routable — not audited)")

renderResult :: AuditResult -> String
renderResult r =
  "  " <> (if r.ok then "✓" else "✗") <> " " <> show r.publicPort <> " " <> r.serviceId
    <> " — " <> r.message <> " (" <> show r.ms <> "ms)"
