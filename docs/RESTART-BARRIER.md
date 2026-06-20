# Restart ordering: release-before-bind (Atlantis finding, 2026-06-20)

A concrete supervision-substrate gap found bringing up the Atlantis
live-coding rig under Bosun's Chair (cf. `feedback_supervision_substrate_model`).

## Symptom

After restarting purerl-tidal via the Chair, its Link-anchor listener
(UDP **57121**) silently failed to bind. Downstream, Triggerfish's clock
stayed `FREE` instead of locking to Ableton/AUM Link tempo — even though
link-spike was peered with Ableton (Ableton "1 Link" = one peer) and
publishing anchors fine. es9-daemon (the *other* anchor consumer, sibling
port 57123) was unaffected because it never restarted.

## Root cause — a bind race on restart

Bosun's restart stops the old process and starts the replacement with **no
barrier** confirming the old process has exited and released its OS
resources. The new beam booted while the old one still held 57121; the
listener's single `gen_udp:open/2` failed with `eaddrinuse` and it gave up
permanently (alive but socketless — answering `no_anchor` forever). A
service that binds a *fixed* port is exactly the case this bites.

## Why DeepStar didn't hit it — release-before-bind

DeepStar's restart (`cmd/deepstar/restart.go` → `downOne`, `tryUp`) is a
strict barrier in both directions:

1. **Wait-for-exit on stop.** `downOne` SIGTERMs the whole process *group*
   (`kill(-pgid)`), then **polls until the group is confirmed dead**,
   escalating to SIGKILL, and only then returns. Old ports are guaranteed
   free before anything new starts.
2. **Wait-for-bind on start.** `tryUp` spawns the replacement and
   `spawn.waitForReady` **polls until the new process has bound its
   port/socket** (or exited) before declaring it up — so dependents only
   start once the thing they depend on is actually listening.

Bosun's process executor launches detached (`setsid`, reparented to
launchd / ppid 1) and its restart has *neither* half: no wait-for-exit, no
wait-for-bind.

## Fixes

1. **Service-side (applied).** `tidal_link_anchor:open_socket/1` now
   retries the bind every 200 ms for ~2 s, so the listener reclaims 57121
   once the old beam exits — robust against any supervisor's restart race.
2. **Bosun-side (recommended).** Add the two barriers to the process
   substrate:
   - *Release barrier* on restart — confirm the old process group is dead
     (the `daemonize` reap already does this for launch; restart needs the
     same before spawning the replacement).
   - *Readiness probe* on start — Bosun's `observe`/`effectiveProbe`
     already TCP/UDP-probes ports; `apply`/restart should wait on it before
     proceeding, mirroring DeepStar's `waitForReady`.

   This is the supervision-substrate "model the OS semantics" concern:
   release-before-bind and bind-before-dependents are part of *correct*
   native-process restart, not an end-product hack.

## Ruled out (positive findings)

- **Link multicast works under Bosun's detached launch.** Ableton/AUM
  discover link-spike and share tempo (~127 BPM observed). The
  `setsid`/ppid-1 launch does **not** strip macOS Local Network (multicast)
  permission — the initial hypothesis was wrong.
- **DeepStar is a Go program** (`cmd/deepstar/*.go`), not the "stdlib-only
  Python CLI" the ecosystem CLAUDE.md / memory still describe. Stale doc.
