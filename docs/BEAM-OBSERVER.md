# Bosun on the BEAM — observe / visualise / control the live-coding rig

Status: **VISION / Phase 2** (Andrew's idea, 2026-06-16). Not started; recorded so
the control-surface work done now leaves the right seam for it.

## The thesis

Bosun-core is pure PureScript and already backend-portable (the Go conformance
column proves it; purerl compiles the same core to the BEAM). So the Chair can be
*the same surface* over two runtimes — swap the **observer**, keep everything
else (graph grammar, deps/host/pack layouts, SPOF + blast-radius lenses, the
control modal).

The runtime is reached through one seam:
- **observe**: produce "what exists + how it's wired + what's up" (→ the same
  view model the Chair already renders).
- **control**: accept commands (start/stop/restart).

On Node that seam is `bosun serve` over Docker. On the BEAM it is OTP. **Build the
Node control-surface now with this seam abstract**, Docker-on-Node as the first
implementation; a BEAM observer then drops in.

## Why OTP fits Bosun's primitives almost exactly

| BEAM / OTP | Bosun primitive |
|---|---|
| supervision tree | containment (the nested bands/circles already built) |
| strategy one_for_all / rest_for_one / one_for_one | requirement gradient: part-of / ordered / independent |
| links / monitors | binds-to (crash-coupled) / wants (watch) edges |
| child restart type + max_restarts/period | restart policy + backoff (already in the IR) |
| registered name + listening sockets (WS 3012, OSC 57120, Link 20808) | reachability / Address (ports) |
| node@host (distributed Erlang) | placement failure-domain path (literal) |
| supervisor:restart_child / terminate_child | the control-surface actions |

`one_for_all = part-of` hands us the reliability/failover axis the grammar
(§2.6) called its thinnest — first-class from the platform.

## Atlantis (the live-coding rig) is a mixed topology Bosun already models

- **BEAM processes**: purerl-tidal's per-voice supervisor tree → supervised nodes.
- **OS-process daemons**: es9-daemon (Rust), link-spike (Rust) → external nodes
  with socket reachability (OSC/UDP), currently supervised by DeepStar.

Bosun-on-BEAM would render the live rig in the Chair and let you click-to-restart
a voice — a typed, visual supervisor that subsumes DeepStar's role and bridges
the visualisation and music domains (the purerl-tidal crossover).

## FFI the observer will need (Erlang)

`supervisor:which_children/1`, `supervisor:count_children/1`, `sys:get_state/1`,
`process_info/2`, `application:which_applications/0`, `erlang:monitor`/links via
`process_info(Pid, links)`. Control via `supervisor:restart_child/terminate_child`
and the app's own control sockets (purerl-tidal already has a WS verb surface).

Also a third runtime column for the conformance/showcase story (Node + Go + BEAM).
