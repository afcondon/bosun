-- | DESIGN §3.2 — `Executor`, the polymorphic launch mechanism as a sum.
-- |
-- | Mutual exclusion by construction: a service is launched *exactly one
-- | way*. This is the heart of "parse the `startCommand`" — once a string
-- | becomes an `Executor`, a service cannot be both compose-managed and
-- | launchd-managed, because that state has no representation.
module Bosun.Executor where

import Prelude

import Bosun.Atoms (AbsPath, Domain, EnvVar, Host, Port)
import Data.Either (Either)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple)

data Executor
  = Process     { cwd :: AbsPath, command :: String, env :: Array (Tuple EnvVar String) }
  | Container   ContainerSpec
  | SystemdUnit { unit :: String, scope :: SystemdScope }
  | LaunchdJob  { label :: String, keepAlive :: KeepAlive, throttleSec :: Maybe Int }
  | StaticCDN   { provider :: CDNProvider, domain :: Domain }
  | Remote      { via :: RemoteVia, inner :: Executor }   -- ssh wrapper; recursive
  | Unmanaged   String   -- prose-only registry rows: documentation, not instructions

derive instance Eq Executor

-- | `image` XOR `build` — both-at-once is unrepresentable (forbids
-- | docker-compose's `image:`+`build:` footgun at the type level).
newtype ContainerSpec = ContainerSpec
  { source       :: Either ImageRef BuildContext
  , internalPort :: Maybe Port
  , publish      :: Maybe Port   -- host:container; Nothing = internal only
  }

derive newtype instance Eq ContainerSpec
derive newtype instance Show ContainerSpec

newtype ImageRef = ImageRef String
derive newtype instance Eq ImageRef
derive newtype instance Ord ImageRef
derive newtype instance Show ImageRef

newtype BuildContext = BuildContext { context :: AbsPath, dockerfile :: Maybe String }
derive newtype instance Eq BuildContext
derive newtype instance Show BuildContext

data SystemdScope = SystemScope | UserScope   -- DESIGN: System | User
derive instance Eq SystemdScope
derive instance Ord SystemdScope
derive instance Generic SystemdScope _
instance Show SystemdScope where show = genericShow

-- | launchd: `True` = relaunch always. Richer KeepAlive *conditions* live in
-- | `RestartPolicy` (D-E11); unmodeled KeepAlive keys ride in `extra`.
newtype KeepAlive = KeepAlive Boolean
derive newtype instance Eq KeepAlive
derive newtype instance Show KeepAlive

data CDNProvider = CloudflarePages | NetlifyCDN | GitHubPages | OtherCDN String
derive instance Eq CDNProvider
derive instance Generic CDNProvider _
instance Show CDNProvider where show = genericShow

-- | The `ssh andrew@andrews-mac-mini …` wrapper, parsed rather than collapsed
-- | to an opaque string.
data RemoteVia = Ssh { user :: Maybe String, host :: Host }
derive instance Eq RemoteVia
