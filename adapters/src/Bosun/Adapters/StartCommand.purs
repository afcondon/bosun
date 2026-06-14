-- | "Parse the `startCommand`" (DESIGN §1, the heart of ingestion-time
-- | parse-don't-validate). A registry/Procfile start command string becomes an
-- | `Executor` — after which a service *cannot* be launched two ways at once.
-- |
-- | The common registry shape is `cd /abs/path && <command>`; we extract the
-- | absolute cwd (via `mkAbsPath`, so a missing `/` is caught) and the command.
-- | A command with no `cd /abs` anchor is the SDI footgun (§7.2): it has no
-- | absolute cwd, so it cannot become a `Process` — it falls to `Unmanaged`,
-- | the honest home for "documentation, not instructions." An empty command is
-- | likewise `Unmanaged` (a NULL/prose registry row).
-- |
-- | PHASE 3B SCOPE: handles `cd <abs> && …`, empty, and the no-anchor case.
-- | The `ssh … <inner>` (→ `Remote`) and `docker …` decompositions are later
-- | refinements; for now those parse as `Process`/`Unmanaged` by the same rules.
module Bosun.Adapters.StartCommand (parseStartCommand) where

import Prelude

import Bosun.Atoms (mkAbsPath)
import Bosun.Executor (Executor(..))
import Data.Array as A
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..))
import Data.String as String

parseStartCommand :: String -> Executor
parseStartCommand raw =
  let t = String.trim raw in
  case String.stripPrefix (Pattern "cd ") t of
    _ | t == "" -> Unmanaged ""
    Nothing -> Unmanaged t   -- no `cd /abs` anchor — the SDI footgun shape
    Just rest ->
      let
        parts = String.split (Pattern " && ") rest
        pathPart = String.trim (fromMaybe "" (A.head parts))
        command = String.joinWith " && " (A.drop 1 parts)
      in case mkAbsPath pathPart of
        Just cwd -> Process { cwd, command, env: [] }
        Nothing -> Unmanaged t
