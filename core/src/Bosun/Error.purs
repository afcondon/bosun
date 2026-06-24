-- | DESIGN §6 (Tier 2) — `DeployError`, the enumerated list of ways your
-- | deploy breaks at 3am. Each variant is grounded in a real tool that ships
-- | the footgun; `validate` refuses to mint a `ValidatedDeployment`
-- | containing any of them, so they can never reach `plan`/`apply`.
module Bosun.Error where

import Prelude

import Bosun.Atoms (EnvVar, Host, Port, RoutePath, ServiceId, Url)
import Bosun.Edge (Gate)
import Bosun.Health (Probe)
import Bosun.Publish (ChannelKey)
import Bosun.Selector (Selector)
import Bosun.Service (Source)
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple)

data DeployError
  = PortCollision              Host Port (NonEmptyArray ServiceId)
  | DanglingDependency         ServiceId String                       -- depends_on a ghost
  | DependencyCycle            (NonEmptyArray ServiceId)
  | EmptySelector              Selector
  | SelectorNotClosed          { selector :: Selector, svc :: ServiceId, missingDep :: ServiceId }
  | UncheckableGate            { gated :: ServiceId, upstream :: ServiceId, gate :: Gate }
  | RouteWithoutBacking        RoutePath                              -- comment says /sankey, nothing serves it
  | ServiceExpectsRouteButNone ServiceId
  | CrossSourceDrift           { svc :: ServiceId, field :: String, claims :: Array (Tuple Source String) }
  | UnboundReference           { svc :: ServiceId, var :: EnvVar }    -- ${VAR} no default, no supplier
  | SdiContractViolation       { svc :: ServiceId, why :: SdiViolation }
  | UnparseableExecutor        { source :: Source, raw :: String }
  -- | Generalisation of PortCollision into URL space — two StaticCDN services
  -- | claim the same live URL. The HTTP probe can only attribute reachability
  -- | to one of them; CDN dashboards would show contradictory custom-domain
  -- | configs. Different URLs on the same channel project are NOT a collision
  -- | (that's `ChannelCollision`'s concern); this rule is about the live face.
  | UrlCollision               Url (NonEmptyArray ServiceId)
  -- | Two static services target the same publish-channel destination — they
  -- | would trample each other on deploy. The `ChannelKey` makes "the same
  -- | destination" precise per channel: same `(cfProject, branch, subdir)` for
  -- | CF-git, same `cfProject` for CF-wrangler, same `(workdir, branch,
  -- | servingDir)` for GH Pages. Different channels are never collisions even
  -- | if surface fields look similar — they go to different CDNs entirely.
  | ChannelCollision           ChannelKey (NonEmptyArray ServiceId)
  -- | A StaticCDN service's readiness probe doesn't match its executor: the
  -- | only meaningful readiness signal for a CDN-served URL is an HTTP GET on
  -- | that URL. `ProcessAlive`, `TcpConnect`, `SocketReady`, `NotifyReady`,
  -- | and `NoProbe` are all nonsense here, and Bosun catches them at the type
  -- | level rather than producing silent always-down or always-up signals.
  | StaticReadinessMismatch    { svc :: ServiceId, probe :: Probe }
derive instance Eq DeployError

-- | The SDI lazy-spawn router's contract (§7.2): a spawnable row needs an
-- | absolute cwd anchor and must embed its literal public port so SDI's
-- | rewrite has somewhere to land.
data SdiViolation
  = NoAbsoluteCwd           -- startCommand lacks a `cd /abs` anchor (mkAbsPath fails)
  | PortNotInStartCommand   -- the literal public port must appear in the command
derive instance Eq SdiViolation
derive instance Generic SdiViolation _
instance Show SdiViolation where show = genericShow
