-- | The pure `/analyze` orchestration (MVP-PLAN workstream B, pure half).
-- |
-- | Runs the whole loose→tight ladder over already-parsed source `Json` and
-- | projects each rung to the wire `AnalyzeResult`. This is the one function
-- | the Chair's analysis backend calls; `chair-server` is just the I/O shell
-- | that reads the files, calls this, and serialises the result. Pure and
-- | total — the no-Aff seam holds (DESIGN §8): all uncertainty (file reads,
-- | yaml parsing) stays at the server edge, never here.
-- |
-- | Lives in `adapters` (not `core`) because it needs the ingest functions;
-- | the view types + codecs it produces live in `core`'s `Bosun.View`.
module Bosun.Analyze
  ( AnalyzeInput
  , analyze
  ) where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Bosun.Reconcile (buildAliases, reconcile)
import Bosun.Validate (validate)
import Bosun.View (AliasOverride, AnalyzeResult, applyOverrides, reconcileView, serviceInstanceView, validationView)
import Data.Argonaut.Core (Json)
import Data.Maybe (Maybe, maybe)

-- | The server resolves the request's source locators to parsed `Json` (or
-- | `Nothing` if not supplied), then hands this to `analyze`.
type AnalyzeInput =
  { compose   :: Maybe Json
  , registry  :: Maybe Json
  , overrides :: Array AliasOverride
  }

analyze :: AnalyzeInput -> AnalyzeResult
analyze inp =
  { instances: map serviceInstanceView insts
  , reconcile: reconcileView aliases r
  , result: validationView (validate r.deployment)
  }
  where
  insts = maybe [] ingestCompose inp.compose <> maybe [] ingestRegistry inp.registry
  aliases = applyOverrides inp.overrides (buildAliases insts)
  r = reconcile aliases insts
