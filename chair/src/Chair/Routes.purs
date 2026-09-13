-- | The Chair's URL map — typed, hash-based, the same `routing-duplex` +
-- | `Routing.Hash` pattern the other Halogen sites in this ecosystem use
-- | (HeresiarchHalogen, polyglot). One codec value parses the hash AND prints
-- | links, so the URL and the in-app view can never drift.
-- |
-- |   #/                       → the project picker (landing)
-- |   #/graph/<project-key>    → the live graph for one deployment/fixture
-- |   #/ingestion              → the MISU ingestion ladder (pillar 1)
-- |   #/cockpit                → the serve route table (pillar 0)
-- |
-- | `GraphR` carries a project KEY (a url token like `atlantis`), so a deep link
-- | lands straight on a chosen deployment — a test affordance and a real user
-- | feature both.
module Chair.Routes
  ( Route(..)
  , routeCodec
  ) where

import Prelude hiding ((/))

import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import Routing.Duplex (RouteDuplex', root, segment, string)
import Routing.Duplex.Generic (noArgs, sum)
import Routing.Duplex.Generic.Syntax ((/))

data Route
  = Projects
  | GraphR String
  | IngestionR
  | CockpitR

derive instance Generic Route _
derive instance Eq Route
derive instance Ord Route
instance Show Route where
  show = genericShow

routeCodec :: RouteDuplex' Route
routeCodec = root $ sum
  { "Projects"   : noArgs
  , "GraphR"     : "graph" / string segment
  , "IngestionR" : "ingestion" / noArgs
  , "CockpitR"   : "cockpit" / noArgs
  }
