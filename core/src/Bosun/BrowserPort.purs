-- | Ports a browser may refuse to open.
-- |
-- | The Fetch standard keeps a list of "bad ports" — ports belonging to other
-- | protocols (mail, SIP, IRC, X11, NFS …) that a browser may refuse to fetch
-- | from, so a web page cannot be used to talk to those services:
-- | <https://fetch.spec.whatwg.org/#port-blocking>. A page served on one of
-- | them can fail in the browser with no error at all: on 2026-11-23 a dev page
-- | on 4190 (Sieve) showed a literal `about:blank` in Safari 26.5 while Chrome
-- | loaded it, and half an hour went on the page before the port was suspected.
-- |
-- | Browsers differ in what they enforce. The list is the safe superset, not a
-- | record of what each browser does. Only Safari refusing 4190 has been seen.
-- |
-- | The rule applies to every registry row, not just the ones a browser opens.
-- | `role` is free text in fleet.json (`reader`, `landing`, `link-anchor`, …),
-- | so it cannot tell browser-facing rows from the rest. A raw socket loses
-- | nothing by avoiding these ports, and `bosun serve` puts an HTTP router in
-- | front of any row it lazy-spawns.
module Bosun.BrowserPort
  ( browserBlockedPorts
  , isBrowserBlocked
  , nextFreePort
  , portRefusal
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set

-- | The Fetch standard's bad-port list, copied from the spec on 2026-11-23.
-- | Everything below 1024 is listed for completeness; we never allocate there.
browserBlockedPorts :: Set Int
browserBlockedPorts = Set.fromFoldable
  [ 0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77
  , 79, 87, 95, 101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135
  , 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530, 531
  , 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993, 995
  , 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566
  , 6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080
  ]

isBrowserBlocked :: Int -> Boolean
isBrowserBlocked port = Set.member port browserBlockedPorts

-- | The first port at or above `from` that is neither in `used` nor on the
-- | browser bad-port list.
nextFreePort :: Int -> Set Int -> Int
nextFreePort from used = go from
  where
  go p
    | Set.member p used || isBrowserBlocked p = go (p + 1)
    | otherwise = p

-- | Why a registration on this port is refused, if it is.
portRefusal :: Int -> Maybe String
portRefusal port
  | isBrowserBlocked port = Just
      ( "port " <> show port <> " is on the Fetch standard's bad-port list "
          <> "(https://fetch.spec.whatwg.org/#port-blocking); a browser may refuse it "
          <> "without an error (Safari shows about:blank on 4190). "
          <> "Pick another, e.g. from GET /api/ports/suggest."
      )
  | otherwise = Nothing
