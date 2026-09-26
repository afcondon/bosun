-- | `Bosun.ResidentAccess` — who may reach a resident's `/state` + `/control`.
-- |
-- | The rule being pinned (two-machine plan, Phase 2; the Chair's "remote
-- | machines are observe-only at first"): under `TailnetReaders` another
-- | machine on the tailnet can watch a group and cannot drive it; under
-- | `LocalOnly`, nothing changes from before the audience existed. The peer
-- | strings are shaped the way the shims report them: node's
-- | `socket.remoteAddress` on a dual-stack `::` listener, which maps IPv4
-- | peers to `::ffff:a.b.c.d`, and the host part of Go's `RemoteAddr`.
module Test.Bosun.ResidentAccessSpec where

import Prelude

import Bosun.ResidentAccess (Audience(..), PeerClass(..), admits, bindHost, peerClass)
import Data.Tuple.Nested ((/\))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = describe "ResidentAccess" do
  describe "peerClass" do
    it "loopback, both families and IPv4-mapped" do
      map peerClass [ "127.0.0.1", "::1", "::ffff:127.0.0.1" ]
        `shouldEqual` [ LocalPeer, LocalPeer, LocalPeer ]
    it "Tailscale's CGNAT range 100.64.0.0/10, edges included" do
      map peerClass [ "100.64.0.0", "100.100.2.70", "100.127.255.255", "::ffff:100.101.1.2" ]
        `shouldEqual` [ TailnetPeer, TailnetPeer, TailnetPeer, TailnetPeer ]
    it "just outside 100.64.0.0/10 is not the tailnet" do
      map peerClass [ "100.63.255.255", "100.128.0.0", "10.100.64.1" ]
        `shouldEqual` [ OtherPeer, OtherPeer, OtherPeer ]
    it "Tailscale's IPv6 ULA, any case" do
      map peerClass [ "fd7a:115c:a1e0::1", "FD7A:115C:A1E0:ab12::3" ]
        `shouldEqual` [ TailnetPeer, TailnetPeer ]
    it "the LAN and anything malformed are other" do
      map peerClass [ "192.168.178.20", "::ffff:192.168.178.20", "fe80::1", "", "100.x.1.1" ]
        `shouldEqual` [ OtherPeer, OtherPeer, OtherPeer, OtherPeer, OtherPeer ]

  describe "admits" do
    it "LocalOnly admits this machine to everything, as before" do
      map (\(m /\ p) -> admits LocalOnly "127.0.0.1" m p)
        [ "GET" /\ "/state", "POST" /\ "/control/restart", "OPTIONS" /\ "/state" ]
        `shouldEqual` [ true, true, true ]
    it "LocalOnly refuses a tailnet peer even a read" do
      admits LocalOnly "100.100.2.70" "GET" "/state" `shouldEqual` false
    it "TailnetReaders lets a tailnet peer read /state, / and preflight" do
      map (\(m /\ p) -> admits TailnetReaders "100.100.2.70" m p)
        [ "GET" /\ "/state", "GET" /\ "/", "OPTIONS" /\ "/control/restart" ]
        `shouldEqual` [ true, true, true ]
    it "TailnetReaders never lets a tailnet peer drive the group" do
      map (\(m /\ p) -> admits TailnetReaders "::ffff:100.100.2.70" m p)
        [ "POST" /\ "/control/restart", "POST" /\ "/control/reload", "GET" /\ "/control/up", "POST" /\ "/state" ]
        `shouldEqual` [ false, false, false, false ]
    it "TailnetReaders still refuses the LAN outright" do
      map (\(m /\ p) -> admits TailnetReaders "::ffff:192.168.178.20" m p)
        [ "GET" /\ "/state", "OPTIONS" /\ "/state" ]
        `shouldEqual` [ false, false ]
    it "TailnetReaders keeps full control for this machine" do
      admits TailnetReaders "::1" "POST" "/control/restart" `shouldEqual` true

  describe "bindHost" do
    it "loopback for LocalOnly, every interface for TailnetReaders" do
      map bindHost [ LocalOnly, TailnetReaders ] `shouldEqual` [ "127.0.0.1", "::" ]
