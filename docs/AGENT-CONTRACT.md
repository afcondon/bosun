# Bosun Agent — health / lifecycle reporter

**Status:** DESIGN (2026-06-18). Drafted from the Chair-session design discussion
with Andrew, the day the Atlantis hand-off landed (6/6 daemons under
`bosun supervise`). Spans three owners — the **engine** (a new `probe: health`
+ additive `/state`), the **daemon repos** (link a tiny lib, supply two
callbacks), and the **Chair** (render a degraded state). Companion to
`SDI-COMPATIBILITY.md` (same "rich native path + works-anyway floor" shape).

## Why — the gap this closes

`probe: process` is a **liveness** signal (the process exists), not a
**readiness** one (it's actually serving). The Atlantis hand-off surfaced two
false-greens:

- **es9-daemon** name-matches a macOS **aggregate** device (`ES9 then A4C`) that
  persists in CoreAudio even when the physical ES-9 is unplugged — so it reports
  `running` with no hardware. (`src/main.rs:1585` already documents the trap.)
- **fh2-daemon** exits if the FH-2 is absent *at launch*, but doesn't notice a
  *runtime* unplug — it'd stay green with a dead port.

Only the daemon can know it's truly ready (es9 must poll the ES-9 firmware over
MIDI; fh2 must check its port; calypso must hit its own `/health`). So the
**definition of ready lives in the daemon**; Bosun only transports and aggregates
it.

## Design decisions (settled)

1. **Thin reporter; Bosun stays in charge of all control.** The agent reports
   health and runs a cleanup hook on shutdown. It does NOT let a daemon restart,
   refuse, or defer its own lifecycle. We'd only revisit this for a
   mission-critical dismount that must *refuse* an interrupt — not the case here.
   A hardware unmount is served by the `drain()` hook = cleanup-**on-signal**,
   not autonomy: Bosun decides *when* to stop; the daemon just exits cleanly.
2. **A linked library per language, not a documented-only contract.** A spec each
   daemon hand-implements drifts into six slightly-different socket handlers. A
   shared `bosun-agent` lib makes the transport, wire format, and lifecycle state
   machine *identical* because it's the same code; the daemon supplies only what
   is genuinely its own.
3. **Pull, not push (for v1).** Bosun already ticks; the agent *listens* and
   answers a `health` request. Pull-with-timeout is a better liveness+readiness
   combiner than push (a wedged daemon stops *answering*; push-silence is
   ambiguous). Lifecycle-event *push* (timelines, crash reasons) is a v2
   enrichment, not v1.
4. **The probe floor stays.** Un-linkable / third-party daemons keep
   `probe: process | tcp | http` and binary honesty. Linked = rich; un-linked =
   works-anyway. Mandating the lib never makes anything un-supervisable.
5. **One protocol, conformance-pinned.** The wire format is defined ONCE here +
   a fixture; each language lib is tested to emit byte-identical frames (the same
   single-source-of-truth discipline as the supervisor's node≡Go conformance).

---

# Part I — The contract (v1, normative)

## Transport

The agent **listens** on a Unix domain socket at a path Bosun derives
deterministically from the service id (the way it already derives `pidPath`):

```
${BOSUN_RUNTIME_DIR:-$TMPDIR/bosun}/agent-<serviceId>.sock
```

Bosun's `probe: health` connects to that path each observe tick. The daemon's own
control socket (`~/.es9/control.sock`, `~/.fh2/control.sock`) is left untouched —
the agent owns a *separate* health channel so health never collides with the
daemon's own protocol.

## Wire format — line-delimited JSON

One request line in, one reply line out, connection closed:

```
→  health\n
←  {"state":"ready","detail":"ES-9 fw 1.8.2","since":1718700000000}\n
```

- **state** ∈ `starting | ready | degraded | failed` (the agent never reports
  `down`/`stopped` — those are *absence*, which Bosun reads from pgid/connect).
- **detail** — a short human string for the Chair hover (`"ES-9 firmware
  unreachable"`, `"booting: loading config"`). May be empty.
- **since** — epoch-ms the daemon entered the current `state` (lets the Chair show
  "degraded 12s").

A request that times out or refuses connection is **not** an error in the wire
sense — it's *absence of a readiness signal*, which Bosun folds with pgid (below).

## The daemon's surface — exactly two callbacks

```
readiness() -> Health      // called per Bosun probe; cheap, non-blocking-ish
drain()     -> ()          // called once on SIGTERM, before exit
```

The library owns **everything else**: opening/serving the socket, parsing
`health`, serializing the reply, stamping `since`, and installing the SIGTERM
handler that runs `drain()` then exits 0. The daemon writes its two device-
specific closures and calls `serve(config)` once at startup.

## Status mapping (engine side)

For a `probe: health` service the supervisor combines **pgid liveness** (it
already has this) with the **health reply**:

| pgid alive | health reply        | → status      |
|------------|---------------------|---------------|
| no         | —                   | `down`        |
| yes        | `ready`             | `running`     |
| yes        | `degraded`          | `degraded` *  |
| yes        | `failed`            | `failed`      |
| yes        | `starting` / timeout | `starting` (within boot-grace) → `failed` (after) |

\* `degraded` is the one genuinely new status token. Everything else reuses the
states the supervisor already has.

## `/state` + Chair (additive — never breaks older decoders)

- `/state` `services` map gains the `degraded` token; the `supervision` map entry
  may carry the health `detail`. Both additive (the D-S1 discipline) — a plain
  serve or an un-linked supervise omits them.
- **Chair**: a new `LiveDegraded` → **amber**, distinct from up-green and
  down-red; `detail` on hover. Pure addition to `Chair.Graph.NodeLive`.

---

# Part II — Build plan

## A. Rust agent — the proof (`agents/rust/bosun-agent`)

Rust first because es9-daemon (the worst false-green) *and* link-spike are both
Rust — one crate proves the whole pattern. Bones:

```
agents/rust/bosun-agent/
  src/lib.rs        # public API: serve(Config), Health, State
  src/listener.rs   # UnixListener accept loop (std thread; no async dep)
  src/wire.rs       # serde_json request/reply; the `since` stamp
  src/lifecycle.rs  # SIGTERM handler → drain() → exit(0)  (signal-hook or libc)
  tests/conformance.rs  # emitted frames == docs/fixtures/agent-protocol.json
```

Public API sketch:

```rust
pub enum State { Starting, Ready, Degraded, Failed }
pub struct Health { pub state: State, pub detail: String }

pub struct Config<R, D> {
    pub service_id: String,
    pub readiness: R,   // Fn() -> Health     (called per probe)
    pub drain: D,       // FnOnce() or Fn()   (called on SIGTERM)
}

pub fn serve<R, D>(cfg: Config<R, D>)   // spawns listener thread, installs signal handler
where R: Fn() -> Health + Send + 'static, D: Fn() + Send + 'static;
```

Then wire the two Rust daemons:

- **es9-daemon `readiness()`** — send a SysEx **device-identity request** to the
  ES-9 over MIDI and wait briefly for the firmware reply (Andrew's idea: poll the
  firmware number as the connectedness test). Reply → `ready` + `"fw X.Y.Z"`; no
  reply → `failed` + `"ES-9 not responding"`. This sees *through* the persistent
  aggregate that fools the audio-device name match.
  **`drain()`** — stop the cpal output stream + close the MIDI ports so a restart
  can re-acquire the device cleanly.
- **link-spike `readiness()`** — Link session alive / peer-count or multicast
  socket healthy. `drain()` — leave the Link session, close the UDP socket.

## B. Go / Node / Erlang agents — skeletal (mirror the Rust API)

Each is the same `serve(config)` shape with the two callbacks; only the host
idioms differ. One paragraph each — flesh out when that language's first daemon
adopts it.

- **Node (`agents/node/bosun-agent.mjs`)** — toolchain-free ESM (the analog of
  `fh2-config/run-daemon.mjs`): `net.createServer` on the Unix socket,
  `JSON.stringify` the reply, `process.on('SIGTERM', …drain…)`. Export
  `serve({ serviceId, readiness, drain })`. **Adopters:** fh2-daemon (readiness =
  MIDI port open + a control-socket ping), calypso-server/-frontend (readiness =
  internal `/health`).
- **Erlang (`agents/erl/bosun_agent.erl`)** — a `gen_server` owning a
  `gen_tcp`/`gen_udp`-style `gen_unix` listener; `readiness`/`drain` as funs in
  the start map; trap `exit`/SIGTERM via the BEAM's `init:stop` path. Could be a
  hand-written `.erl` OR a PureScript module compiled by purs-backend-erl (decide
  when wiring it). **Adopter:** purerl-tidal (readiness = scheduler/WS server up
  on :3012; drain = stop the per-voice supervisor tree, release MIDI).
- **Go (`agents/go/bosunagent`)** — `net.Listen("unix", …)`, `encoding/json`,
  `signal.Notify(SIGTERM)`. `bosunagent.Serve(Config{ID, Readiness, Drain})`.
  **Adopters:** future Go services + the Gnomon-built `static-httpd`
  (readiness = "listening").

## C. Engine tasks (Bosun core/cli)

- `probe: health` kind in the compose adapter + IR (`Readiness::Health` with the
  derived socket path).
- `observeSupSnapshot` / `refine`: connect to the agent socket, send `health`,
  apply the **status-mapping table** above (combine with pgid).
- `/state`: emit the `degraded` token + the `detail` in the `supervision` map
  (additive).

## D. Chair tasks

- `Chair.Graph.NodeLive` gains `LiveDegraded` (amber); `Chair.State`
  `decodeSuperviseState` reads the `detail` from `supervision`.
- Render: amber dot/halo distinct from down-red; `detail` on node hover and in the
  runtime overlay.

## E. Conformance

`docs/fixtures/agent-protocol.json` — the canonical `(request, reply)` exchange +
the state enum. Each language lib has a test asserting byte-identical frames. This
is what keeps four hand-written libs from drifting.

## Rollout order

1. Rust `bosun-agent` + es9 `readiness()`/`drain()` (+ link-spike) — the proof.
2. Engine `probe: health` + `/state` `degraded` (additive).
3. Chair `LiveDegraded` amber + detail.
4. Node agent → fh2 + calypso.
5. Erlang agent → purerl-tidal.
6. Go agent → static-httpd + future Go services.

Steps 1–3 make the rig *honest* (es9 goes red right now, with the ES-9 unplugged);
4–6 generalise it across the fleet.
