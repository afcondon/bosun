-- | A deployment **host's enactment profile** — everything Bosun must know
-- | about a host to run commands *on* it, in one typed place.
-- |
-- | Two facets of "what is this host?" used to be scattered string-matches:
-- | `Apply` ssh-wrapped `host == "macmini"` to a hardcoded `andrew@…` login,
-- | and `Serve` separately mapped `"macmini"` to a hardcoded tailnet address for
-- | proxy redirects. Both are now resolutions of one `Target` record, so a host
-- | is described once and the description is shared.
-- |
-- | This is precisely the **ssh-bootstrap rung's host registry** (FEDERATION
-- | §7): the data the bootstrap interpreter of the no-Aff enactment seam reads.
-- | `defaultTargets` is the built-in default layer (so the tool works out of the
-- | box and the I/O-free conformance harnesses have something to resolve
-- | against); a loaded `targets.json` (`Bosun.Adapters.Targets`) is the GitOps
-- | source of truth layered over it. It is config-as-typed-data, NOT a
-- | behavioural shim — the whole dimension (login, address, workdir, env) lives
-- | in the type even while the homelab only populates one remote host.
module Bosun.Target
  ( SshDest
  , mkSshDest
  , unSshDest
  , ExecLoc(..)
  , Target
  , TargetMap
  , resolveTarget
  , localTarget
  , defaultTargets
  , networkAddr
  , isRemote
  ) where

import Prelude

import Bosun.Atoms (AbsPath, Host, mkAbsPath, mkHost, unHost)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))

-- | An ssh login destination, e.g. `andrew@andrews-mac-mini`.
newtype SshDest = SshDest String

derive newtype instance Eq SshDest
derive newtype instance Ord SshDest
derive newtype instance Show SshDest

mkSshDest :: String -> SshDest
mkSshDest = SshDest

unSshDest :: SshDest -> String
unSshDest (SshDest s) = s

-- | WHERE a host's commands run: directly on the executing machine, or wrapped
-- | through ssh to a remote login. (The enactment seam admits more interpreters
-- | still — DryRun, BeamNative — per FEDERATION §3.4; this is the datum the
-- | ssh-bootstrap interpreter reads to decide local-vs-remote.)
data ExecLoc = LocalExec | RemoteSsh SshDest

derive instance Eq ExecLoc

-- | A host's enactment profile:
-- |
-- | * `exec`      — run commands locally, or ssh-wrapped to a login.
-- | * `address`   — the network/tailnet address the host is reached at, for
-- |                 `serve`'s reverse-proxy redirects.
-- | * `workdir`   — the directory remote commands run in (where a container
-- |                 deployment's compose file lives); `Nothing` ⇒ the ssh
-- |                 landing dir / local cwd.
-- | * `envPrefix` — environment assignments a non-interactive remote shell
-- |                 needs (e.g. macOS Docker Desktop wants `/usr/local/bin` on
-- |                 `PATH`; a fresh ssh shell does not source the login profile).
type Target =
  { exec :: ExecLoc
  , address :: String
  , workdir :: Maybe AbsPath
  , envPrefix :: Array (Tuple String String)
  }

type TargetMap = Map Host Target

-- | Resolve a service's host to its enactment profile. A host-less service, or
-- | one whose host is not in the map, is treated as **local** — the safe
-- | default, so an unconfigured host never causes an accidental ssh somewhere.
resolveTarget :: TargetMap -> Maybe Host -> Target
resolveTarget tmap = case _ of
  Nothing -> localTarget
  Just h -> fromMaybe localTarget (Map.lookup h tmap)

-- | The local host's profile: run here, address `localhost`, no remote workdir
-- | or env prefix.
localTarget :: Target
localTarget =
  { exec: LocalExec, address: "localhost", workdir: Nothing, envPrefix: [] }

-- | True iff commands for this target are ssh-wrapped.
isRemote :: Target -> Boolean
isRemote t = case t.exec of
  RemoteSsh _ -> true
  LocalExec -> false

-- | The built-in default target table — sane defaults so the tool works out of
-- | the box, OVERRIDABLE by a loaded `targets.json`. The MacMini's profile
-- | encodes the real polyglot deploy: ssh to `andrew@andrews-mac-mini`, run
-- | container ops in the rsync'd compose dir, with Docker Desktop's bin dirs on
-- | `PATH` (exactly what `polyglot-deploy/deploy-remote.sh` does by hand).
defaultTargets :: TargetMap
defaultTargets = Map.fromFoldable
  [ Tuple (mkHost "mbp") localTarget
  , Tuple (mkHost "localhost") localTarget
  , Tuple (mkHost "macmini")
      { exec: RemoteSsh (mkSshDest "andrew@andrews-mac-mini")
      , address: "andrews-mac-mini"
      , workdir: mkAbsPath "/Users/andrew/psd3/polyglot-deploy"
      , envPrefix: [ Tuple "PATH" "/usr/local/bin:/opt/homebrew/bin:$PATH" ]
      }
  ]

-- | The network address a host is reached at for proxy redirects (`serve`).
-- | A known host maps to its configured `address`; an unknown host passes
-- | through verbatim (its own name) — preserving `serve`'s original
-- | tailnet-passthrough behaviour for hosts not (yet) in the table.
networkAddr :: TargetMap -> Host -> String
networkAddr tmap h = maybe (unHost h) _.address (Map.lookup h tmap)
