-- | DESIGN §3.1 — Atoms (refined newtypes).
-- |
-- | Two refined atoms (`Port`, `AbsPath`) go through a Maybe-returning smart
-- | constructor — the front line of MISU. The rest are opaque identifiers
-- | that arrive as *user data* (the recompile test, §3.1): total
-- | constructors, no enumeration baked into a general tool. Every atom is
-- | opaque (constructor unexported) so all construction flows through `mk*`.
module Bosun.Atoms
  ( Port, mkPort, unPort
  , AbsPath, mkAbsPath, unAbsPath
  , Domain, mkDomain, unDomain
  , RoutePath, mkRoutePath, unRoutePath
  , EnvVar, mkEnvVar, unEnvVar
  , ProjectSlug, mkProjectSlug, unProjectSlug
  , ServiceId, mkServiceId, unServiceId
  , Host, mkHost, unHost
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String as String

newtype Port = Port Int
derive newtype instance Eq Port
derive newtype instance Ord Port
derive newtype instance Show Port

-- | In 1..65535, else `Nothing`.
mkPort :: Int -> Maybe Port
mkPort n
  | n >= 1 && n <= 65535 = Just (Port n)
  | otherwise = Nothing

unPort :: Port -> Int
unPort (Port n) = n

newtype AbsPath = AbsPath String
derive newtype instance Eq AbsPath
derive newtype instance Ord AbsPath
derive newtype instance Show AbsPath

-- | Must be absolute (leading `/`). `mkAbsPath "node router.mjs"` is
-- | `Nothing` — exactly how the real SDI footgun (§7.2) gets flagged: the
-- | row has no `cd /abs` anchor, so no absolute cwd can be parsed from it.
mkAbsPath :: String -> Maybe AbsPath
mkAbsPath s
  | String.take 1 s == "/" = Just (AbsPath s)
  | otherwise = Nothing

unAbsPath :: AbsPath -> String
unAbsPath (AbsPath s) = s

newtype Domain = Domain String
derive newtype instance Eq Domain
derive newtype instance Ord Domain
derive newtype instance Show Domain

mkDomain :: String -> Domain
mkDomain = Domain

unDomain :: Domain -> String
unDomain (Domain s) = s

newtype RoutePath = RoutePath String
derive newtype instance Eq RoutePath
derive newtype instance Ord RoutePath
derive newtype instance Show RoutePath

mkRoutePath :: String -> RoutePath
mkRoutePath = RoutePath

unRoutePath :: RoutePath -> String
unRoutePath (RoutePath s) = s

newtype EnvVar = EnvVar String
derive newtype instance Eq EnvVar
derive newtype instance Ord EnvVar
derive newtype instance Show EnvVar

mkEnvVar :: String -> EnvVar
mkEnvVar = EnvVar

unEnvVar :: EnvVar -> String
unEnvVar (EnvVar s) = s

-- | A stable inventory id that survives renames (e.g. a Marginalia slug).
newtype ProjectSlug = ProjectSlug String
derive newtype instance Eq ProjectSlug
derive newtype instance Ord ProjectSlug
derive newtype instance Show ProjectSlug

mkProjectSlug :: String -> ProjectSlug
mkProjectSlug = ProjectSlug

unProjectSlug :: ProjectSlug -> String
unProjectSlug (ProjectSlug s) = s

-- | Bosun's stable logical identity for a service (see §5 reconcile).
newtype ServiceId = ServiceId String
derive newtype instance Eq ServiceId
derive newtype instance Ord ServiceId
derive newtype instance Show ServiceId

mkServiceId :: String -> ServiceId
mkServiceId = ServiceId

unServiceId :: ServiceId -> String
unServiceId (ServiceId s) = s

-- | OPAQUE runtime identity, verbatim from the user's inventory — *not* an
-- | enumeration (the recompile test, §3.1). "Which host am I" is read at
-- | startup; "local vs remote" is `host == thisHost`, derived not stored.
newtype Host = Host String
derive newtype instance Eq Host
derive newtype instance Ord Host
derive newtype instance Show Host

mkHost :: String -> Host
mkHost = Host

unHost :: Host -> String
unHost (Host s) = s
