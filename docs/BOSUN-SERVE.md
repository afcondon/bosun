# `bosun serve` — the typed lazy-spawn router (replacing SDI)

Plan for making Bosun (or a sibling PureScript→Go binary) take over SDI's
duties: lazy-launch demos/servers on demand so the machine isn't saturated by
everything running at once.

## First: how SDI actually works (clearing up the fuzziness)

Your intuition was *"Bosun launches the process and the connection gets handed
to it."* That's one valid design (**socket hand-off**, §3b) — but it is **not**
what SDI does. SDI is a **reverse proxy** that stays in the middle forever.

The reason you can't just "launch the process and step aside" is a hard
constraint: **something has to be holding the port to catch the very first
request**, and a backend can't bind a port that the router is already holding.
So one of two things must happen:

- **(a) Proxy** — the router keeps the public port and *relays* bytes to the
  backend, which listens on a *different* port. (SDI.)
- **(b) Hand-off** — the router holds the port, *accepts* the connection, then
  passes that open socket (the file descriptor) to the spawned process, which
  then talks to the client directly. (systemd socket activation, inetd,
  launchd.) Requires the backend to *support* inheriting a socket — most don't.

### SDI today (read from `agent-teams/sdi/{router,spawner}.mjs`)

A long-lived Node process on `:3998`. At boot:
1. Fetch the Marginalia registry; keep the **local** servers (this host) whose
   `startCommand` contains the **literal port** (so it can be rewritten).
2. For each, bind an HTTP listener on the **public** port (`127.0.0.1:<port>`)
   and sit idle. (Ports it can't rewrite, or already-bound, are **skipped**.)

On the first request to a port (`ensureBackend`):
3. Rewrite the command, replacing the public port with an **internal port =
   public + 20000** (e.g. `3007 → 23007`), and `spawn('bash -c <rewritten>')`,
   logging to `/tmp/sdi-<port>.log`.
4. `waitForPort(internalPort)` — poll TCP-connect every 100 ms (up to 60 s)
   until the backend binds.
5. **Reverse-proxy**: `http.request` to `127.0.0.1:<internalPort>`, pipe the
   request body up and the response back. WebSocket `upgrade` is bridged too.
6. `recordActivity` resets a **10-min idle timer**; on expiry, `SIGTERM` the
   backend. The next request respawns it.

Plus: remote-host ports get a `421` "this runs on <host>, try <tailscale-url>"
redirect listener; `:3998/state` reports what's spawned; SIGHUP reloads the
registry (diffs listeners: add/remove/recreate).

So the backend never sees the client directly — **SDI is in the path for every
byte**, and the "literal port in the command" rule exists purely so SDI can
move the backend onto the internal port and own the public one.

## 2. Why Bosun is the right thing to replace it with

SDI is ~500 lines of **untyped Node** that re-derives, ad hoc, things Bosun
already has as a typed core:

| SDI does, by hand | Bosun already has |
|---|---|
| read the registry | `ingestRegistry` → typed `ServiceInstance`s |
| `rewriteCommand` needs a literal port; skip if absent | `validate` → `SdiContractViolation (PortNotInStartCommand \| NoAbsoluteCwd)` |
| spawn `bash -c <cmd>` | the os-exec edge (`execLine`) + `applyScript` for one service |
| `waitForPort` poll | the **observation edge** (`observe` / a `TcpConnect` probe) |
| idle `SIGTERM` | `apply`'s `Stop` path |
| `/state` | a typed snapshot |

**The reconciler and the router are the same typed model — seen as *batch*
(`apply` once) vs *resident* (`serve` forever).** A lazy-spawn = "`apply` one
service, on demand." So `bosun serve` is mostly *wiring Bosun's existing core to
a resident HTTP front*, plus the proxy. And the headline payoff: **it validates
the registry before binding** — the broken `flask run` row (no `FLASK_APP`) and
the no-`cd` footgun become *admission errors at startup with a clear message*,
not 3am failures on first request. **SDI that typechecks its registry.**

## 3. How `bosun serve` works

### (a) The proxy model — recommended for v1

Mirror SDI, because it works with **unmodified** backends (flask, `npx serve`,
julia) that bind their own port — exactly our demos.

```
bosun serve
  │  ingest registry → validate          (admission control)
  │  for each VALID local service: bind 127.0.0.1:<publicPort>, idle
  ▼
request on :<publicPort>  ─ goroutine ─►  ensure(service):
      already up?  → reuse internal port
      down?        → exec rewritten launch cmd (public→internal port),
                     observe TcpConnect(internalPort) until ready
                  └► httputil.ReverseProxy → 127.0.0.1:<internalPort>
      reset idle timer; on expiry → Stop(service)
```

- **Per-service single-flight**: only the first goroutine for a down service
  spawns it; concurrent requests await the same readiness (SDI's `readyPromise`
  dedup → a Go `sync.Once`/`singleflight` per service).
- **Proxy** = Go `net/http/httputil.ReverseProxy` (handles streaming + WS with
  far less code than the hand-rolled Node piping).
- **Reuses bosun-core**: command-rewrite + launch = the `applyScript` path for
  one service; readiness = the `observe` `TcpConnect` probe; teardown =
  `apply`'s `Stop`.

### (b) The hand-off model — your original intuition, as a later option

For services that *support* socket activation (or that we make support it),
`bosun serve` could hold the listener, `accept()` the connection, and pass the
fd to the spawned process (Go: `os.StartProcess` with `ExtraFiles`, or
`SO_REUSEPORT`). Then Bosun is **out of the path** — no proxy hop. Tradeoffs:
the backend must accept an inherited socket (flask/julia/`serve` don't, without
changes), and idle-reap + re-handoff is fiddlier. **Defer to a later phase**, as
a per-service opt-in for hot paths; the proxy model covers the demos now.

### (c) The BROKER model — ensure-and-locate, added 2026-08-22

The third option, and the one §3b was reaching for without the socket-passing.
**Bosun does not relay and does not hold the file descriptor. It makes sure the
service is running, tells the client where it actually is, and gets out of the
way.** The client then connects *directly*.

```
GET /where/<serviceId>  on the control port  ─►  probe: already up?
                                                   no → spawn, wait for the
                                                        plan's readiness probe
                                                ─►  { mediation, ready, started,
                                                      probe, at: {transport,…} }
client dials `at` itself.  Bosun is now irrelevant to the traffic.
```

**The distinguishing question is not "HTTP or WebSocket". It is: does Bosun
belong in the data path at all?** For anything that (a) owns a hardware
resource, (b) is long-lived and started deliberately rather than per-request,
or (c) carries timing-critical traffic, the answer is no.

For a good part of this rig, broker mode is not an optimisation — it is the
only thing that can work:

| service | reached by | proxyable? |
|---|---|---|
| es9-daemon | unix socket `~/.es9/control.sock` (+ OSC on UDP :57130) | **no** |
| fh2 daemon | unix socket `~/.fh2/control.sock` | **no** |
| link-spike | Ableton Link, UDP **multicast** :20808 | **no** |
| itajara | 30 Hz WebSocket, holds the Audio4c | technically yes; shouldn't |

You cannot relay a unix domain socket or a multicast group through a TCP
reverse proxy in any meaningful sense. Before broker mode existed, the first
three were `NoHostPort` rejections — invisible to the router entirely.

**Opt in per service, in the registry row:**

```json
{ "role": "worker", "port": 3028, "serveMode": "broker",
  "url": "ws://127.0.0.1:3028",
  "startCommand": "cd /abs/path && ./itajara --ws-port 3028" }
```

`serveMode` defaults to `proxy`. Absent, or unrecognised, means `proxy` — so
every row written before this existed keeps exactly the behaviour it had.
The field is named for the ROUTER's role, not the service's protocol,
because that is the decision being made.

**What broker mode does with the registered port.** It still holds it, when it
can, and answers **`307 Temporary Redirect`** there — 307 rather than 302 so
the method and body survive. That preserves the good property of the proxy
("type the registered port and it works") without the relay. It can only do
this if the start command contains the literal port, so the service can be
moved to `public + 20000` and stop fighting for it; when it can't, the service
keeps its own address, Bosun binds nothing, and `/where` is the only door.
A WebSocket client will not follow a 307 — it gets one anyway, with the real
address in the `location` header, because failing loudly with the right answer
beats being quietly relayed.

**What broker mode never does:** reap. There is no idle timer on a brokered
service. Reaping a daemon that holds an audio interface because no request
arrived for ten minutes is the failure that made WebSocket services unsafe to
router-manage in the first place (found 2026-08-17). Brokered children also do
**not** die with the router — a proxied backend is useless without the proxy in
front of it, but a brokered daemon has clients talking to it directly, and
restarting Bosun must not stop the music. The next ensure probes before it
spawns, so it finds the survivor and reports `started: false`.

**Readiness** is `Bosun.Health.Probe`, chosen by the plan and made by the shim:
a listening address ⇒ `TcpConnect` (the same connect the proxy path waits on),
a unix socket ⇒ `SocketReady` (the socket file exists, which is what
`Bosun.CLI.Observe` already means by it), a UDP endpoint ⇒ `NoProbe`, because
connecting to a datagram socket proves nothing. `probe: "none"` on the wire
means **nothing was checked** — never that a check failed.

Full operator + client documentation: **`docs/ENSURE-AND-LOCATE.md`**. Why this
exists at all, and the investigation that prompted it — a proxied WebSocket that
went deaf in one direction and was **never diagnosed** —
**`docs/RELAY-STALL-AND-BROKER-MODE.md`**. Read its §2 before re-opening that
stall: it is the list of what has already been excluded, and with what evidence.

### Why Go specifically
- **Fast, cheap resident** — the router itself should be negligible overhead;
  a Go binary is a small static process with efficient goroutine-per-request
  concurrency (vs. a Node event loop). It's not that Bosun makes the *backends*
  faster — they're still python/julia/node — it's that the always-on router is
  light and the proxy hop is cheap.
- **Real concurrency** — goroutine-per-request. This is the tier that hits the
  lazy-CAF thunk thread-safety roadblock, **proven surmountable** by the
  `sync.Once` fix (`scripts/go-race.sh`, `scripts/race-fix.py`). That fix is the
  prerequisite for the Go column of `serve`.
- **One typed artifact** for deploy + serve, sharing `bosun-core`, replacing an
  untyped Node tool.

## 4. The admission-control win (the typed difference)

`bosun serve` binds a port **only if** the service validates. The same
`validate` that powers `bosun check` becomes the router's **admission control**:

- `PortNotInStartCommand` → can't rewrite → **don't bind**, log why (today SDI
  silently skips; Bosun says it typed-ly). NB our python demos hardcode their
  port → this fires → they'd be served *standalone* (registered, not routed) or
  need a `--port`/`$PORT` convention to become routable.
- `NoAbsoluteCwd` → the SDI `node router.mjs` footgun → refuse + explain.
- A dangling dep / cycle / collision across the registry → surfaced at boot.

So you can't register a service that *can't* be served and have it fail later —
it fails loudly at `serve` start.

## 5. Phasing

- **P1 — MVP, node column. ✅ DONE (commit aa5bc39).** `Bosun.Serve.servePlan`
  (pure admission control: admitted `Route` with public→internal port rewrite,
  or typed `Rejection` reusing `SdiViolation`); `renderServePlan` (the startup
  report); `Bosun.CLI.Serve` + `.js` (the resident reverse-proxy shim — bind /
  lazy-spawn / `waitForPort` / proxy / per-service single-flight / idle-reap,
  mirroring `router.mjs`). `bosun serve <registry.json>`. `ServeSpec` (6
  admit/reject cases); 56 tests green. **Verified live**: admits 1 / rejects 3
  on a fixture, first request lazy-spawned a python backend on the internal
  port and reverse-proxied → HTTP 200; killing the backend respawned it.
  Deferred to P2: a JSON `/state` endpoint (P1 logs lifecycle to stdout).
- **P2 — parity. ✅ DONE (commits 004a7e9, 41fd6ed, 0092b7d, fbd953f).**
  - **421 redirects** — a remote service is now a first-class `Redirect` (bind +
    answer `421 Misdirected Request` → tailnet URL), not a rejection.
  - **WebSocket** upgrade bridging on proxy routes (raw socket replay).
  - **JSON `/state`** on :3997 (live routes with up/pid + redirects).
  - **live-registry fetch** — `bosun serve` (no arg) reads `/api/ports` from the
    Marginalia API; the drop-in SDI form.
  - **SIGHUP hot-reload** via a pure, tested `serveDiff :: ServePlan -> ServePlan
    -> ServeDiff` (unbind/rebind keyed by per-port signature); the shim applies it.
  - **`--audit`** — one-shot spawn-test of every routable row (spawn → probe →
    tear down), the chaos-harness spine.
  **Verified live** on a fixture and against the real 41-service registry (24
  admitted / 5 redirect / 12 typed-rejected); 61 tests green. (`--plan` for serve
  folded into the existing `renderServePlan` report.)
- **P3 — the Go column. ✅ DONE (commit 4bb0b0f; runtime fix aba781a).** The pure
  admission pipeline (`reconcile → servePlan`) transpiles via backend-go and a
  native binary IS the resident reverse proxy: `Bosun.Conformance.ServeMain` +
  the Go shim `conformance/go/bosun_serve_foreign.go` (`httputil.ReverseProxy` +
  lazy-spawn + single-flight + idle-reap + **serve-layer timeouts**). The
  `sync.Once` thunk fix is upstream in backend-go's `runtime.go`; `go-race.sh` is
  the regression guard. **Verified**: `scripts/go-serve.sh` — native binary
  routed 8 concurrent requests → HTTP 200, clean under `-race`. Still TODO in
  P3: replace the actual SDI launchd agent on the mbp (the cutover, with
  `--audit` parity — needs the live-registry fetch + P2's hot-reload first).
- **P4 — optional hand-off.** Socket-activation for opt-in hot-path services.

## 6. Migration / compatibility

- Same registry, same contract (`SDI-COMPATIBILITY.md`: literal port + absolute
  `cd`). `bosun serve` reads `/api/ports` exactly as SDI does.
- **Cutover**: run `bosun serve` on a spare status port, `--audit` for parity
  against SDI, then swap the launchd plist (`agent-teams/sdi/launchd/`) to the
  Bosun binary.
- The internal-port convention (public + 20000) carries over unchanged.

## Open questions
- **Single binary or sibling?** Recommend a `serve` subcommand of `bosun`
  (shares `bosun-core`), not a separate app — same model, different lifetime.
- ~~**Upstream the `sync.Once` thunk fix** into backend-go runtime.go?~~ DONE
  (aba781a) — it's app-agnostic runtime correctness, so it belongs in backend-go
  (vs the app-specific proxy foreign, which stays in Bosun). The degenerate
  eager-cycle deadlock it introduces is owned at the serve layer via timeouts.
- **Make our demos routable?** The python demos hardcode their port; a `$PORT`
  convention would let `serve` rewrite + route them instead of leaving them
  standalone.
