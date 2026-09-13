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
  , Url, mkUrl, unUrl
  , GitWorkdir, mkGitWorkdir, unGitWorkdir
  , RoutePath, mkRoutePath, unRoutePath
  , EnvVar, mkEnvVar, unEnvVar
  , ProjectId, mkProjectId, unProjectId
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

-- | A live URL — scheme + host + path. Distinct from `Domain` (just the
-- | hostname) because Bosun's HTTP probe needs the whole thing. The smart
-- | constructor requires a `http://` or `https://` scheme — every other shape
-- | (bare hostname, scheme-less `://foo`, file://) is `Nothing`.
newtype Url = Url String
derive newtype instance Eq Url
derive newtype instance Ord Url
derive newtype instance Show Url

mkUrl :: String -> Maybe Url
mkUrl s
  | String.take 8 s == "https://" || String.take 7 s == "http://" = Just (Url s)
  | otherwise = Nothing

unUrl :: Url -> String
unUrl (Url s) = s

-- | A checked-out git workdir on the local filesystem. The "push side" of a
-- | git-driven publish channel needs this — we shell out to `git -C <dir>` to
-- | commit + push, so it has to be a real local working tree (not a remote
-- | "owner/repo" reference). Wraps `AbsPath`; smart constructor delegates to
-- | `mkAbsPath` (presence of `.git` is an I/O-edge check, not a type rule).
newtype GitWorkdir = GitWorkdir AbsPath
derive newtype instance Eq GitWorkdir
derive newtype instance Ord GitWorkdir
derive newtype instance Show GitWorkdir

mkGitWorkdir :: String -> Maybe GitWorkdir
mkGitWorkdir = map GitWorkdir <<< mkAbsPath

unGitWorkdir :: GitWorkdir -> AbsPath
unGitWorkdir (GitWorkdir p) = p

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

-- | A stable inventory id that survives renames — the first half of a
-- | `ServiceId` (§5 reconcile). It was `ProjectSlug` until 2026-09-13, holding
-- | Marginalia's four-word NATO callsign; Marginalia retired those, and a
-- | registry row now carries its numeric `projectId` instead.
-- |
-- | Still opaque and still a `String`, deliberately. What this atom needs from
-- | an inventory is that the token be STABLE, not that it be a number: a
-- | registry with no Marginalia behind it (`fixtures/portable-example`) names
-- | its own projects, and the recompile test (§3.1) says a general tool does
-- | not bake one inventory's id scheme into a core type. `Bosun.Adapters.
-- | Registry` is where the numbers come from — it reads `projectId` and never
-- | invents one, so a Marginalia-fed fleet keys on decimal ids throughout.
newtype ProjectId = ProjectId String
derive newtype instance Eq ProjectId
derive newtype instance Ord ProjectId
derive newtype instance Show ProjectId

mkProjectId :: String -> ProjectId
mkProjectId = ProjectId

unProjectId :: ProjectId -> String
unProjectId (ProjectId s) = s

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
