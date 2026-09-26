-- | Who may reach a resident daemon's `/state` + `/control` surface — the pure
-- | admission decision the resident shims (`Bosun.CLI.Resident`, JS and Go)
-- | call per request, so the policy exists once and is tested here rather than
-- | hand-kept in two languages.
-- |
-- | Not to be confused with `Bosun.Exposure`, which is how a *service* is
-- | reached. This is about the *supervisor's own* HTTP surface.
module Bosun.ResidentAccess
  ( Audience(..)
  , PeerClass(..)
  , bindHost
  , peerClass
  , admits
  ) where

import Prelude

import Data.Array as A
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String as S

-- | · `LocalOnly` — this machine only (the default, and the only behaviour
-- |   before 2026-09-26).
-- | · `TailnetReaders` — this machine keeps full control; peers on the
-- |   tailnet may READ `/state`, and nobody else gets anything. This is the
-- |   "remote machines are observe-only at first" rule of the Chair's machine
-- |   picker (minard-for-nix/docs/chair-machine-selection.md): another
-- |   machine's Brunel can watch this group but not restart it.
data Audience = LocalOnly | TailnetReaders

derive instance Eq Audience

instance Show Audience where
  show = case _ of
    LocalOnly -> "LocalOnly"
    TailnetReaders -> "TailnetReaders"

-- | `TailnetReaders` binds every interface and admits by peer address, rather
-- | than binding the tailnet address itself: at boot Tailscale comes up well
-- | after launchd starts the supervisor (on the MacMini it is `Stopped` until
-- | tailnet-watch heals it, ~30 s in), and a bind to a not-yet-existing
-- | address fails once and is never retried.
bindHost :: Audience -> String
bindHost = case _ of
  LocalOnly -> "127.0.0.1"
  TailnetReaders -> "::"

-- | Where a request came from, as far as admission cares.
data PeerClass = LocalPeer | TailnetPeer | OtherPeer

derive instance Eq PeerClass

instance Show PeerClass where
  show = case _ of
    LocalPeer -> "LocalPeer"
    TailnetPeer -> "TailnetPeer"
    OtherPeer -> "OtherPeer"

-- | Classify a peer address as the socket reports it (no port): loopback,
-- | Tailscale's ranges (100.64.0.0/10 and fd7a:115c:a1e0::/48), or anything
-- | else. An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`, what a dual-stack
-- | listener reports for an IPv4 peer) is judged by its IPv4 part.
peerClass :: String -> PeerClass
peerClass = classify <<< S.toLower <<< stripMapped
  where
  stripMapped a = case S.stripPrefix (S.Pattern "::ffff:") a of
    Just v4 -> v4
    Nothing -> a
  classify addr
    | addr == "127.0.0.1" || addr == "::1" = LocalPeer
    | S.take 15 addr == "fd7a:115c:a1e0:" = TailnetPeer
    | inCgnat addr = TailnetPeer
    | otherwise = OtherPeer
  inCgnat a = case map Int.fromString (S.split (S.Pattern ".") a) of
    [ Just 100, Just b, Just _, Just _ ] -> b >= 64 && b <= 127
    _ -> false

-- | The admission decision, per request: `admits audience peer method path`.
-- | This machine is always admitted, as it always was. A tailnet peer under
-- | `TailnetReaders` may `GET /state` (and `/`), plus the CORS preflight a
-- | browser sends first; never `/control`.
admits :: Audience -> String -> String -> String -> Boolean
admits audience peer method path = case peerClass peer of
  LocalPeer -> true
  TailnetPeer -> audience == TailnetReaders && readOnly
  OtherPeer -> false
  where
  readOnly = method == "OPTIONS" || (method == "GET" && A.elem path [ "/state", "/" ])
