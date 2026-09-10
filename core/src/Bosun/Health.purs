-- | DESIGN §3.5 — Health (readiness/liveness/startup split), restart policy,
-- | and config references vs suppliers.
-- |
-- | The readiness/liveness/startup split is universal and where the MISU
-- | bites: an ordering edge that *waits* on an upstream is only meaningful if
-- | the upstream publishes a readiness signal (≠ `NoProbe`) — gating a
-- | probe-less service is the `UncheckableGate` error.
module Bosun.Health where

import Prelude

import Bosun.Atoms (AbsPath, EnvVar, Port)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple)

data Probe
  = HttpGet     { port :: Port, path :: String, expectStatus :: Int }
  | TcpConnect  Port
  | ExecCmd     (Array String)   -- compose test:[CMD,…]; k8s exec
  | ProcessAlive                 -- launchd KeepAlive; supervisord autorestart
  | SocketReady AbsPath
  | NotifyReady                  -- systemd Type=notify sd_notify READY=1
  | NoProbe
derive instance Eq Probe

type Health =
  { liveness  :: Probe                                       -- restart trigger
  , readiness :: Probe                                       -- gates dependents; ≠ NoProbe to satisfy On{Ready,Healthy}
  , startup   :: Maybe { probe :: Probe, graceSec :: Int }   -- compose start_period; k8s startupProbe
  }

-- | Enriched per D-E11: a base mode + portable extra conditions (launchd's
-- | KeepAlive dict is richer than a flat enum), with backoff knobs alongside.
-- | The `backoff` encodes the "launchd ThrottleInterval looks dead for ~40s"
-- | gotcha — `Status` can report `InBackoff` rather than `Down`.
type RestartPolicy =
  { base       :: BaseRestart
  , conditions :: Array RestartCondition          -- empty = unconditional
  , backoff    :: { minSec :: Int, maxRetries :: Maybe Int }
  }

data BaseRestart = Never | OnFailure | Always | UnlessStopped
derive instance Eq BaseRestart
derive instance Generic BaseRestart _
instance Show BaseRestart where show = genericShow

data RestartCondition
  = WhilePathExists AbsPath   -- launchd PathState (runtime); ≠ systemd ConditionPathExists (start-time)
  | WhileNetworkUp            -- launchd NetworkState
  | OnlyIfCrashed             -- launchd Crashed; ≈ systemd Restart=on-abnormal
derive instance Eq RestartCondition
derive instance Generic RestartCondition _
instance Show RestartCondition where show = genericShow

-- | What an adapter records when its source says nothing about restarting:
-- | keep the service alive, first backoff window five seconds, uncapped.
-- |
-- | The five is not arbitrary and must not drift: it is the same number as
-- | `Bosun.Supervisor.defaultConfig.backoffBaseMs`, so a spec that declares no
-- | policy resolves to exactly the supervisor's own defaults and an
-- | unannotated file behaves as it did before any of this was readable.
defaultRestart :: RestartPolicy
defaultRestart =
  { base: UnlessStopped
  , conditions: []
  , backoff: { minSec: 5, maxRetries: Nothing }
  }

-- | D-E8: resolve `${VAR:-default}` at validate. A `ConfigRef` unsatisfied by
-- | any in-scope supplier and lacking a default is an `UnboundReference`.
data ConfigRef = ConfigRef EnvVar (Maybe String)   -- referenced var + optional default
derive instance Eq ConfigRef
derive instance Generic ConfigRef _
instance Show ConfigRef where show = genericShow

data ConfigSupplier
  = InlineEnv    (Array (Tuple EnvVar String))   -- compose environment: / systemd Environment=
  | EnvFile      AbsPath                          -- compose env_file / systemd EnvironmentFile=
  | ConfigMapRef String                           -- k8s
  | SecretRef    String                           -- presence tracked; value never read
derive instance Eq ConfigSupplier
derive instance Generic ConfigSupplier _
instance Show ConfigSupplier where show = genericShow
