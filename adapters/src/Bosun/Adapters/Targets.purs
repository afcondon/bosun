-- | Ingest a `targets.json` into a `TargetMap` — the GitOps source-of-truth
-- | layer over `Bosun.Target`'s built-in `defaultTargets`. A deployment's host
-- | profiles (ssh login, network address, remote workdir, env prefix) are infra
-- | config that wants to live in its own versioned artifact rather than baked
-- | into the binary or smeared across a compose file (FEDERATION §3.5: desired
-- | state is signed git).
-- |
-- | Shape — the host key is required, every field optional:
-- |
-- |   { "macmini": { "ssh": "andrew@andrews-mac-mini",
-- |                  "address": "andrews-mac-mini",
-- |                  "workdir": "/Users/andrew/psd3/polyglot-deploy",
-- |                  "env": { "PATH": "/usr/local/bin:/opt/homebrew/bin:$PATH" } },
-- |     "build-box": { "ssh": "ci@build-box", "workdir": "/srv/deploy",
-- |                    "os": "linux", "engine": "podman" } }
-- |
-- | A host with no `ssh` key is `LocalExec`; `address` defaults to the host key;
-- | `workdir`/`env` are optional. The supervision substrate (`Bosun.Substrate`)
-- | is declared by the optional `os` (`macos` | `linux`) and `engine` (`docker`
-- | | `podman` | `nerdctl`) keys; either missing falls back to that field of
-- | `defaultPlatform` (macOS + Docker), so an unannotated host keeps today's
-- | behaviour and a Linux box opts in by naming its OS. Pure (the file read is
-- | at the CLI edge), using
-- | only the argonaut combinators the Go column already shims — so a
-- | targets-driven deploy stays conformance-clean across the node and Go
-- | columns, exactly like the compose and registry adapters.
module Bosun.Adapters.Targets (ingestTargets) where

import Prelude

import Bosun.Atoms (Host, mkAbsPath, mkHost)
import Bosun.Substrate (ContainerEngine(..), OS(..), Platform, defaultPlatform)
import Bosun.Target (ExecLoc(..), Target, TargetMap, mkSshDest)
import Data.Argonaut.Core (Json, toObject, toString)
import Data.Array as A
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as FO

ingestTargets :: Json -> TargetMap
ingestTargets json = fromMaybe Map.empty do
  obj <- toObject json
  let entries = FO.toUnfoldable obj :: Array (Tuple String Json)
  pure (Map.fromFoldable (map decodeEntry entries))

decodeEntry :: Tuple String Json -> Tuple Host Target
decodeEntry (Tuple name j) =
  Tuple (mkHost name) (decodeTarget name (fromMaybe FO.empty (toObject j)))

decodeTarget :: String -> Object Json -> Target
decodeTarget name o =
  { exec: maybe LocalExec (RemoteSsh <<< mkSshDest) (str o "ssh")
  , address: fromMaybe name (str o "address")
  , workdir: str o "workdir" >>= mkAbsPath
  , envPrefix: envOf o
  , platform: platformOf o
  }

-- The substrate dimensions, each defaulting to `defaultPlatform`'s field when
-- the key is absent or unrecognised — an unannotated host stays macOS + Docker.
platformOf :: Object Json -> Platform
platformOf o =
  { os: maybe defaultPlatform.os identity (str o "os" >>= parseOS)
  , containerEngine: maybe defaultPlatform.containerEngine identity (str o "engine" >>= parseEngine)
  }

parseOS :: String -> Maybe OS
parseOS = case _ of
  "macos" -> Just MacOS
  "linux" -> Just Linux
  _ -> Nothing

parseEngine :: String -> Maybe ContainerEngine
parseEngine = case _ of
  "docker" -> Just Docker
  "podman" -> Just Podman
  "nerdctl" -> Just Nerdctl
  _ -> Nothing

-- the `env` object → ordered (K, V) pairs; non-string values are dropped
envOf :: Object Json -> Array (Tuple String String)
envOf o = fromMaybe [] do
  e <- FO.lookup "env" o >>= toObject
  pure (A.mapMaybe (\(Tuple k vj) -> map (Tuple k) (toString vj)) (FO.toUnfoldable e))

str :: Object Json -> String -> Maybe String
str o k = FO.lookup k o >>= toString
