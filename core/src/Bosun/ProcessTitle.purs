-- | What a launched process is called in `ps`: `<group>:<service>`.
-- |
-- | A machine that runs Bosun has a dozen processes whose command line is
-- | `node server.mjs` or `node server/run.js`, and nothing but `lsof` says
-- | which is which. node will take a title two ways, and a launch uses both:
-- |
-- |   * `NODE_OPTIONS=--title=<title>` in the launch's environment. It reaches
-- |     node however the command gets there (`npx`, a shell script, a child
-- |     the service starts itself), and a program that is not node ignores it.
-- |     But node writes the title over its own argument vector and CUTS IT TO
-- |     THAT LENGTH (measured on macOS, node 22, 2026-11-19): under
-- |     `node r.js` the title `macmini-router:marginalia-frontend` reads
-- |     `macmini-r`, followed by whatever environment string comes next.
-- |   * `--title=<title>` written into the command, when the command's program
-- |     is literally `node`. The option is then part of the argument vector,
-- |     so the vector is always long enough for the title.
-- |
-- | The title reaches `ps -o args`, which then reads exactly the title and no
-- | longer shows the script: anything that finds a service by matching its
-- | command line (`pgrep -f server/run.js`) must match the title instead.
-- | Activity Monitor reads the executable's name and still says `node`.
-- |
-- | The supervisors name themselves by a different route (`beam/bosun` runs a
-- | renamed copy of the BEAM); the group name is derived there by the same
-- | rule as `groupOfComposePath`, and the two must agree.
module Bosun.ProcessTitle
  ( GroupName
  , mkGroupName
  , unGroupName
  , groupOfComposePath
  , serveGroup
  , processTitle
  , titledEnv
  , titledCommand
  , titledShellLine
  ) where

import Prelude

import Bosun.Atoms (EnvVar, ServiceId, mkEnvVar, unServiceId)
import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.String (Pattern(..))
import Data.String as String
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))

-- | The name of one deployment: the group a supervisor keeps.
newtype GroupName = GroupName String
derive newtype instance Eq GroupName
derive newtype instance Show GroupName

-- | Characters a title cannot carry are replaced: node splits `NODE_OPTIONS`
-- | on spaces, and the title is written into a shell line unquoted.
mkGroupName :: String -> GroupName
mkGroupName = GroupName <<< titleSafe

unGroupName :: GroupName -> String
unGroupName (GroupName s) = s

-- | A group is named for the directory its compose file is in:
-- | `fixtures/atlantis/compose.yml` is `atlantis`. A compose file given with
-- | no directory is named for itself, less its extension. `beam/bosun` derives
-- | the supervisor's own process name by this rule, in shell.
groupOfComposePath :: String -> GroupName
groupOfComposePath path = mkGroupName case Array.unsnoc segments of
  Nothing -> "bosun"
  Just { init, last: file } -> case Array.last init of
    Just directory -> directory
    Nothing -> fromMaybe file (Array.head (String.split (Pattern ".") file))
  where
  segments = Array.filter (\s -> s /= "" && s /= ".") (String.split (Pattern "/") path)

-- | The group of everything `bosun serve` starts on demand.
serveGroup :: GroupName
serveGroup = GroupName "serve"

-- | `<group>:<service>`.
processTitle :: GroupName -> ServiceId -> String
processTitle (GroupName group) service = group <> ":" <> titleSafe (unServiceId service)

titleSafe :: String -> String
titleSafe = SCU.fromCharArray <<< map (\c -> if titleChar c then c else '-') <<< SCU.toCharArray

titleChar :: Char -> Boolean
titleChar c =
  (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || isJust (String.indexOf (Pattern (SCU.singleton c)) "_-.")

nodeOptions :: EnvVar
nodeOptions = mkEnvVar "NODE_OPTIONS"

titleOption :: String -> String
titleOption title = "--title=" <> title

-- | A launch's typed environment with the title in `NODE_OPTIONS`. A service
-- | that sets `NODE_OPTIONS` itself keeps what it set, with the title added
-- | after it; otherwise the variable is added at the end.
titledEnv :: String -> Array (Tuple EnvVar String) -> Array (Tuple EnvVar String)
titledEnv title env
  | Array.any (\(Tuple k _) -> k == nodeOptions) env =
      env <#> \(Tuple k v) ->
        if k == nodeOptions then Tuple k (if v == "" then titleOption title else v <> " " <> titleOption title)
        else Tuple k v
  | otherwise = Array.snoc env (Tuple nodeOptions (titleOption title))

-- | A command with `--title=<title>` written in after `node`, when `node` is
-- | the program it runs: the first word after any leading `NAME=value`
-- | assignments. Any other command comes back unchanged, and gets its title
-- | from the environment alone. A command that already carries a `--title` is
-- | left with its own.
titledCommand :: String -> String -> String
titledCommand title command =
  if program == Just "node" && not (String.contains (Pattern " --title=") command) then
    String.joinWith " " (assignments <> [ "node", titleOption title ] <> Array.drop 1 rest)
  else command
  where
  { init: assignments, rest } = Array.span isAssignment (String.split (Pattern " ") command)
  program = Array.head rest

-- `NAME=…`, as a shell reads a leading assignment.
isAssignment :: String -> Boolean
isAssignment word = case String.indexOf (Pattern "=") word of
  Just n | n > 0 -> Array.all nameChar (SCU.toCharArray (String.take n word))
  _ -> false
  where
  nameChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'

-- | The same for a command that a shell is handed whole, with no `env` in
-- | front of it (`bosun serve` runs a registry row this way): the title is
-- | exported first, after anything `NODE_OPTIONS` already holds.
titledShellLine :: String -> String -> String
titledShellLine title command =
  "export NODE_OPTIONS=\"${NODE_OPTIONS:+$NODE_OPTIONS }" <> titleOption title <> "\"; "
    <> titledCommand title command
