# A proxied WebSocket went deaf in one direction — and the broker mode that answers it

*Written 2026-08-22, from a live incident on the music rig. The
producing-with-your-feet app talks to **itajara** (the looper daemon, holding
the Audio4c) over a WebSocket that pushes a state snapshot at **30 Hz**. The app
dials `ws://127.0.0.1:3028`, which `bosun serve` proxies to the daemon on
`:23028`. The established connection went deaf **backend→client only**, for
many minutes, without ever closing.*

*Two halves, and they are not equally settled. **§1–§4 are an investigation that
did not reach a verdict** — the value is in what is now excluded, so the next
person does not spend a day re-excluding it. **§5–§9 are broker mode**, which
does not fix the stall: it removes the router from that data path entirely, so
the class of fault cannot arise there again.*

---

## 1. What was reported, and the verdict

Measured on the day:

- The connection went **deaf in ONE direction**. Commands sent by the browser
  still arrived and took effect — a clear command landed and the daemon's
  `ackSeq` advanced. Snapshots stopped coming back.
- The socket stayed genuinely **open**. `onclose` never fired. The page showed a
  frozen snapshot under a "Connected" banner for many minutes, and
  `WebSocket.send()` kept reporting success.
- A **fresh** connection through the same proxy port worked perfectly, 30 Hz
  immediately. So the path is fine; the long-lived connection died.
- Both TCP legs showed **ESTABLISHED** in `lsof` throughout.

**Verdict: not determined.** It was not reproduced, and no cause is claimed
here. What follows is the exclusion list and one structural finding that fits
the symptom but could not be reached.

This matters beyond itajara, because the same relay (`bridgeUpgrade`,
`cli/src/Bosun/CLI/Serve.js`) carries every upgraded connection the router
serves.

## 2. What was excluded, and how

The harness drove the **real** `serveImpl` — imported from
`cli/src/Bosun/CLI/Serve.js`, not a copy — with a one-route plan, so the relay
under test was the shipping code including reap, adoption and the control
surface. Three ~40-line scratch processes: a backend that accepts an upgrade and
then writes a 200-byte "snapshot" every 33 ms while counting whether its own
`write()` ever returned false; a raw-TCP client that counts received bytes,
sends a command every second, and can be told to **stop reading** for a window;
and a runner supplying the `ServeConfig`. Node **v22.23.1**.

The harness was scratch and is gone. It is worth rebuilding as
`scripts/ws-soak.sh` beside `go-serve.sh` and `go-race.sh` — see §4.

### 2.1 Client-side backpressure — recovers, reliably

Client stopped reading for **25 s** at 30 Hz (~150 KB withheld). While paused,
received bytes/s went to 0 and the sequence number froze at 230 — the symptom's
shape. On resume it drained in a **single ~153 KB 2-second sample**, sequence
jumping 230 → 993, and returned to a steady 11.6–11.9 KB/s.

So `up.pipe(socket)` pausing on `socket.write()` returning false, and resuming
on `'drain'`, works. **A stalled reader does not produce a permanent one-way
stall.** This was the leading hypothesis; it is dead.

### 2.2 The idle reap — correctly suppressed by the upgrade counter

The 13-minute soak (§2.6) ran with `idleTimeoutMs` set to **8 seconds** — 75×
shorter than the 600 s default — precisely so that any hole in the reap
suppression would fire dozens of times. The backend was never SIGTERMed and the
sequence number never reset.

`reap` (`Serve.js:1149`) declines while `state.upgrades > 0`, and does not
re-arm; the clock restarts only when the last upgrade closes. That is correct,
and it is measured, not assumed.

### 2.3 Node's `requestTimeout` — does not apply to upgraded sockets

Node ≥18 defaults `server.requestTimeout` to 300 s and enforces it from a
30-second `connectionsCheckingInterval`. The obvious worry — a 5-minute
guillotine on a long-lived WebSocket — does not apply: on upgrade,
`_http_server.js` removes the socket's HTTP listeners and calls `freeParser`,
which takes the connection out of the list the timeout checker walks. The
`headersTimeout` (60 s) is gone by the same route.

Corroborated by the soak, which ran past both without incident. (Historically
this *was* a real Node bug — but it **destroyed** the socket, which would have
fired `onclose` in the browser. The reported symptom is the opposite.)

### 2.4 The upgrade accounting — balanced

`released` (`Serve.js:917`) is `counted`-guarded **per bridge**, and is wired to
both `socket`'s and `up`'s `close`, so whichever fires first decrements once and
the second is a no-op. The `.catch` path calls it too, covering a client that
goes away before the backend leg is even connected. Traced by hand across
single-connection, concurrent, churning and spawn-failure cases, and exercised
26 times in the soak. No path double-counts or leaks a count.

### 2.5 Ping/pong — not a factor

The bridge is a raw TCP splice: WebSocket control frames are opaque bytes and
pass through untouched. Ping/pong is negotiated and answered **end to end**
between browser and daemon; the router neither consumes nor must generate them.
There is no idle-detector in the relay to half-close anything.

### 2.6 The soak — 13 minutes, 26 connection cycles, no stall

One long-lived upgraded connection at 30 Hz for **780 s**, reaching sequence
30526 and sending 779 commands, while alongside it: **26 cycles** of a second
upgraded connection living ~10 s and going away, and **26 ordinary HTTP GETs**
on the same public port (to exercise `handle` → `bumpIdle` → `proxy` against a
live bridge on the same route state). Idle timeout 8 s throughout.

Result: no stall, no close, no respawn. `blockedWrites=27` out of 30553 backend
writes — transient backpressure, always recovered.

### 2.7 The live bridge was healthy when it was examined

Before touching anything: `nettop` showed itajara emitting ~80 KiB per sample
interval and the router relaying ~80 KiB in / ~80 KiB out; `netstat` showed
Recv-Q and Send-Q at **0** on all four socket ends. The fault was not present to
be observed, which is why this is an exclusion list and not a diagnosis.

### 2.8 The exclusion table

| Hypothesis | Status | Evidence |
|---|---|---|
| Backpressure wedges the backend→client pump permanently | **excluded** | §2.1 — 25 s pause, ~153 KB drain, full recovery |
| Idle reap SIGTERMs the backend mid-session | **excluded** | §2.2 — 13 min at an 8 s timeout, never fired |
| Node `requestTimeout` / `headersTimeout` kills upgraded sockets | **excluded** | §2.3 — `freeParser` on upgrade; and it would *close*, not stall |
| The upgrade counter leaks, arming the reap under a live socket | **excluded** | §2.4 — per-bridge guard, traced + 26 cycles |
| Ping/pong not forwarded or answered; something half-closes | **excluded** | §2.5 — raw splice, end-to-end frames |
| Long elapsed time alone | **excluded** | §2.6 — 780 s continuous |
| Two independent pumps, one dying without tearing down the other | **fits, not reached** | §3 |
| The daemon's per-client writer stalled; the relay only hid it | **residual** | §4 |

## 3. The two-pump finding — a shape that fits, that could not be reached

`bridgeUpgrade` (`Serve.js:907`) splices two sockets and, before this change,
**only `error` tore the pair down**:

```js
const kill = () => { try { up.destroy(); } catch (_) {} try { socket.destroy(); } catch (_) {} };
up.on("close", released);      // decremented a counter, and nothing more
up.on("error", kill);
socket.on("error", kill);
```

A leg that **closed without erroring** left its partner open with nothing behind
it. `pipe`'s own cleanup then unpipes the dead destination, so no further byte
is ever written to the survivor — and nothing destroys it, so no `close` event
reaches the client. **That is the reported symptom exactly: a socket the client
still believes in, on which nothing will ever arrive again, and which will never
fire `onclose`.**

It is written down as a *shape*, not a cause, because every close path that
could be constructed also raises an error or an EOF that `pipe`'s end
propagation already handles (`up` ends ⇒ `socket.end()`), and in each of those
the browser does see the connection go. The state is reachable in principle and
was not reachable in practice.

**It was hardened anyway**, because a half-dead bridge is wrong on its own
terms whether or not it caused this:

```js
const halfDead = (other) => () => { try { other.end(); } catch (_) {} };
up.on("close", halfDead(socket));
socket.on("close", halfDead(up));
```

### Why `end()` and not `destroy()`

This is the detail most likely to be "simplified" by someone who does not know
why it is there. **A close can follow the last write by microseconds, and
`destroy()` discards whatever is still buffered.** Tearing the survivor down
abruptly would trade a hung socket for a **truncated** one — a strictly worse
failure, because a truncated snapshot stream looks like corrupt data rather than
like a disconnect. `end()` flushes what is pending, sends FIN, and lets the peer
see a real close. On a leg that ended gracefully it is a harmless no-op (`pipe`
already called it); on a leg that was destroyed there is nothing pending to
save.

The existing `kill` keeps using `destroy()` and should: an *error* means the
buffered bytes are not going to arrive anyway.

Re-verified after the change: backpressure still recovers, the reap is still
suppressed, no truncation.

## 4. The residual hypothesis, and the next step

**Hypothesis.** The daemon's per-client writer stalled on that one socket while
its reader kept working — a wedged or silently-dropped writer task. That fits
every observation: commands land (reader fine), snapshots stop (writer fine for
*other* clients, dead for this one), both legs ESTABLISHED, nothing closes.

The relay would then be innocent — but it is also **what made the fault
undiagnosable**. With two extra socket buffers between daemon and browser and no
participation in the WebSocket keepalive, neither end can see the other's
silence, and the router's `/state` reports the route as `up: true` because the
backend process is alive. Everything anyone could look at said "fine".

**Concrete next step — bytes per bridge in `/state`.** Give each entry in
`bridgeUpgrade` two counters and two timestamps, incremented in the pipe path:

```
toBackend:   { bytes, lastAt }      // socket → up
toClient:    { bytes, lastAt }      // up → socket
openedAt
```

and expose them per route in `/state` as an `upgrades: [...]` array. Then the
next occurrence answers, without a reproduction, the one question this
investigation could not: **which leg went quiet, and when.** A bridge with
`toBackend.lastAt` advancing and `toClient.lastAt` frozen for 60 s is the
reported fault, visible from the outside, in the surface an operator is already
watching. Cheap (two counters, no allocation per frame) and it makes the Chair
able to show a stalled socket as stalled rather than as connected.

Rebuild the harness as **`scripts/ws-soak.sh`** at the same time, so this is a
regression guard rather than a one-off: it is the only thing that will prove a
future relay change has not reintroduced the class.

## 5. Broker mode — the answer, rather than the fix

Broker mode does not fix §1. It removes the router from that data path, so the
whole class of relay fault cannot arise there.

> Instead of relaying bytes, Bosun tells the client **where** the service
> actually is — starting it first if necessary — and then gets out of the data
> path. The client connects **directly**.

Bosun performs the lazy-spawn and the readiness check **at the moment of
connection or reconnection**, which is exactly when they are wanted, and has
nothing to do with the traffic thereafter. No single point of failure in the
data path, no extra hop, no relay bugs.

This is `BOSUN-SERVE.md` §3b's long-deferred "hand-off" instinct, arrived at
without needing the backend to inherit a socket — which is why §3b was deferred
and why this is not.

### 5.1 Why the field is `serveMode`, and why the default is `proxy`

**The distinguishing question is not "HTTP or WebSocket". It is: does Bosun
belong in the data path at all?** The field is named for the *router's* role
because that is the decision being made; a bare `mode` on a registry row would
be ambiguous (mode of what?), and anything protocol-flavoured would mis-frame
it. Values are `proxy` (default) and `broker`.

**Absent or unrecognised reads as `proxy`** (`readMediation`, lenient like the
rest of the registry decode), so a typo degrades to today's behaviour rather
than un-routing a service, and every row written before this existed keeps
exactly the behaviour it had. Verified against the live registry: 30 admitted /
5 redirect / 15 rejected, **zero brokered**, unchanged.

The plain arity `servePlan = servePlanWith []` is kept for the same reason — the
default is not a value buried in a decoder, it is the *absence of a hint*.

### 5.2 For a good part of this rig it is not an optimisation

| service | reached by | proxyable? |
|---|---|---|
| es9-daemon | unix socket `~/.es9/control.sock` (+ OSC on UDP :57130) | **no** |
| fh2 daemon | unix socket `~/.fh2/control.sock` | **no** |
| link-spike | Ableton Link, UDP **multicast** :20808 | **no** |
| itajara | 30 Hz WebSocket, holds the Audio4c | technically yes; shouldn't |

A unix domain socket and a multicast group cannot be relayed through a TCP
reverse proxy in any meaningful sense. Before broker mode the first three were
`NoHostPort` **rejections** — invisible to the router entirely, so half the rig's
daemons could not be registered at all.

### 5.3 The two proxy rules broker relaxes, and why each existed

Both rules are real, and neither is about brokers:

- **The literal-port rule** (`Sdi PortNotInStartCommand`) exists *only* so the
  router can rewrite the command onto `public + 20000` and own the public port
  for relaying. A broker that cannot rewrite simply leaves the service on its
  own port and binds nothing. Under proxy rules that row is a refusal; as a
  broker it is fine — which matters, because the daemons that most need broker
  mode are the least likely to have a rewritable command.
- **The host-port rule** (`NoHostPort`) exists *only* because a proxy has
  nothing to relay without one. A broker reaching a unix socket — or reaching
  nothing at all — is still worth ensuring, and still has an address (or
  honestly hasn't).

What broker does **not** relax is the absolute-`cd` rule: it still has to spawn
the thing, and the SDI footgun (`NoAbsoluteCwd`) bites just as hard.

### 5.4 What it does with the registered port: 307

Broker mode **still holds the registered port when it can**, and answers **`307
Temporary Redirect`** there — 307 rather than 302/301 so the **method and body
survive**; a POST silently becoming a GET on the way to the real service would
be nastier than not redirecting at all. That preserves the genuinely good
property of the proxy ("type the registered port and it just works") without any
relaying.

Holding the port needs the same public→internal rewrite, so the service is not
fighting the router for it. When the command has no literal port, the service
keeps its own address, Bosun binds nothing, and `/where` is the only door.

Two deliberate refusals:

- **A WebSocket client will not follow a 307.** It gets one anyway, with the
  real address in `location` and a body naming `/where`. Failing loudly with the
  right answer beats being quietly relayed.
- **A UDP listener is never moved and never bound.** There is no such thing as a
  307 over UDP; rewriting it would only mean nobody could find it.

### 5.5 No reap, and no teardown

There is **no idle timer on a brokered service**. Reaping a daemon that holds an
audio interface because no request arrived for ten minutes is precisely the
failure that made WebSocket services unsafe to router-manage (found 2026-08-17,
and the reason the upgrade counter in §2.2 exists at all).

Brokered children also **do not die with the router**. A proxied backend is
useless without the proxy in front of it, so it dies with us; a brokered daemon
has clients talking to it directly, and restarting Bosun must not stop the
music. The next ensure probes before it spawns, finds the survivor, and reports
`started: false` — it re-adopts rather than duplicating. (Observed in testing: a
broker child outlived a router restart and was correctly reported as already
running.)

Likewise, unbinding a broker's listener on reload does not stop the service. The
listener only ever said "go over there".

**None of that is an argument against an explicit stop, and it was mistaken for
one.** Broker mode shipped able to START a brokered service and not to stop it:
`/control/spawn|stop` consulted only the proxy table, so every brokered port
answered `no proxy route on :N`. The comments above — "a broker has no relay",
"a broker's listener going away does NOT stop the service" — are about tearing
down the ROUTE, which is a different act from tearing down the PROCESS and
stays true. But bosun spawns these daemons itself, so it holds the child, and a
surface that can start what it cannot stop teaches an operator to reach past it
for the pid — which is the one habit the control surface exists to prevent.
"Restart it, I rebuilt the binary" is the most common operation there is, and it
had no sanctioned path. Fixed 2026-08-24; the rules are in `CONTROL-SURFACE.md`
and the decision is `Bosun.Serve.brokerStopVerdict`, typed and tested in
`ServeSpec` rather than left as an if-chain in the shim.

### 5.6 Readiness is not a new concept

It reuses what the registry already has: **`Bosun.Health.Probe`**, chosen by the
rule `Bosun.CLI.Observe.effectiveProbe` already uses — *a service with no
declared probe but a listening address is observable by that address*.

| address | probe | how the shim makes it |
|---|---|---|
| listening port | `TcpConnect` | the same connect `waitForPort` already polls |
| unix socket | `SocketReady` | the socket file exists — what `observe` already means by it |
| UDP endpoint | `NoProbe` | a connect against a datagram socket proves nothing |
| no address | `NoProbe` | there is nothing to check |

The **decision** is pure (`Bosun.Serve` picks the probe from the reachability);
the **poll** is mechanical (the shim). The shim is handed the check to make, not
the information to choose one from.

### 5.7 Why `probe: "none"` answers 200, not 503

`probe: "none"` means **nothing was checked** — never that a check failed. So
`/where` answers **200 with `ready: false`**, which looks odd until read as the
rule the rest of Bosun follows: a probe kind we cannot observe reports *unknown
with a reason*, never a silent coercion to down (`PRINCIPLES.md`,
`Bosun.CLI.Observe`). A 503 for a UDP fan-out that was deliberately not probed
would be exactly that coercion, and would fail every naive
`if status != 200` caller against a service that is fine.

`503` is reserved for: a check **was** made and it failed. The address is still
returned so the caller can retry.

The CLI prints three states for the same reason — ready, not ready, and **not
checked**.

## 6. The client contract (short form)

> **`ENSURE-AND-LOCATE.md` is the reference and wins if these disagree.** This
> section is here so the finding and the interface it produced can be read in
> one sitting.

```
GET http://127.0.0.1:3997/where/<projectSlug>:<role>
GET http://127.0.0.1:3997/where?port=<port>
```

```json
{
  "service":   "alpha-victor-echo-kilo:worker",
  "mediation": "broker",
  "ready":     true,
  "started":   false,
  "probe":     "tcp",
  "detail":    "already running; a TCP connect to :23028 passed",
  "at": { "transport": "tcp", "host": "127.0.0.1", "port": 23028,
          "path": null, "url": "ws://127.0.0.1:23028" }
}
```

Defined once as `Bosun.Protocol.WhereResult` / `Locator` with codec values, in
the package a client can depend on **without** the reconcile engine — and the
shim encodes *through* that codec (passed in as `whereJson`) rather than
hand-rolling a second object literal that would drift. Flat and primitive on
purpose: a Go caller needs `encoding/json` and no client library.

```go
type Locator struct {
    Transport string  `json:"transport"`   // tcp | unix | udp | none
    Host      *string `json:"host"`
    Port      *int    `json:"port"`
    Path      *string `json:"path"`
    URL       *string `json:"url"`
}
type WhereResult struct {
    Service   string  `json:"service"`
    Mediation string  `json:"mediation"`   // broker | proxy
    Ready     bool    `json:"ready"`
    Started   bool    `json:"started"`
    Probe     string  `json:"probe"`       // tcp | socket | none
    Detail    string  `json:"detail"`
    At        Locator `json:"at"`
}
```

**Two rules a client must follow, and they are not optional:**

1. **Refuse to proceed if `mediation !== "broker"`.** A `proxy` answer means
   Bosun is in the path and `at` is the router's public port. For a 30 Hz socket
   or a UDP endpoint that is the situation this whole document is about —
   silently accepting the hop is how you end up back at §1.
2. **Ask again on every reconnect.** That is exactly the moment the lazy-spawn
   and the readiness check are wanted, and it costs one round trip. A cached
   address survives a daemon restart and a port change; a fresh `/where` does
   not.

`started` distinguishes "was already up" from "is up because you asked" — the
difference between a pre-flight that *found* the rig ready and one that
assembled it. That is what makes this usable as DeepStar's pre-flight ("is Link
running?") instead of DeepStar doing its own process management.

## 7. Found and not fixed

Four, each actionable. §7.4 was fixed on 2026-08-24 and is kept
here with its remedy, because the remedy is the interesting part.

1. **Bosun's Chair does not render the brokered bucket.** `/state` gained a
   `brokered` array; the Chair's `StateView` (`chair/src/Chair/State.purs:86`)
   does not read it. Safe — argonaut's record decoder ignores unknown keys, and
   that file documents relying on it — but brokered services appear **nowhere**
   in the Chair, which is the same "registered and invisible" class the drift
   work exists to close. Wants a `BROKERED` section beside `ADMITTED`, showing
   `at`, `probe`, whether the router started it, and a `/where` button.
2. **`Bosun.CLI.Observe.effectiveProbe` leaves `UnixSocket` as `NoProbe`**
   (`cli/src/Bosun/CLI/Observe.purs:103`), even though `observe` implements
   `SocketReady` and `probeSocketImpl` exists. So `bosun observe` and
   `supervise` report socket daemons as Unknown while broker mode probes them
   happily — two parts of Bosun disagreeing about the same service. Two lines to
   align. Left alone because it changes supervision behaviour for es9/fh2 (from
   Unknown to Running/Down), which deserves its own decision rather than riding
   in on a serve change.
3. **`brokerHost` is hard-coded `127.0.0.1`** (`core/src/Bosun/Serve.purs`).
   Correct today — only local services are brokered, remote ones are still 421
   redirects — but it is a *second* place that encodes "local", alongside
   `classifyHost`'s `mbp`-or-nothing rule. The two will disagree the first time
   a third local host name appears.
4. ~~**A brokered public port can be adopted but never reclaimed.**~~
   **FIXED 2026-08-24.** `recheckAdopted` walked `states` (proxy routes) only,
   so a broker that stepped aside from an `EADDRINUSE` at bind time never
   re-probed and never took the port back when the external holder exited — the
   `:3028` bug of 2026-08-17 reintroduced in the new bucket. It was the same
   remedy: brokered doors are in the `ADOPTION_WATCH_MS` sweep, alongside the
   two proxy arms and reached from the same three callers (the watch timer,
   `/state`, `applyReload`).

   Two things it was NOT. **One arm, not two** — a broker gets the listener
   re-check and no equivalent of the `adoptedBackend` re-check, because a broker
   records no adoption claim that could go stale (`brokerStopVerdict` probes at
   the moment it is asked, which is why it needs no clock). And **reclaiming a
   door touches nothing about the process**: `bound` and the adoption claim,
   never `child` or `ready`. The 307 listener only ever said "go over there";
   `unbindPort` already refuses to conflate the two in the other direction.

   What the fix added beyond the sweep is `brokered[].door`
   (`Bosun.Serve.brokerDoor`, five constructors). `bound: false` was carrying
   four situations — portless by design, stepped aside, blocked by a bind error,
   and mid-reclaim — and the comment beside it named two. Splitting them is what
   §7.1 needs to render a brokered row at all: "no door, by design" and "a door
   somebody else is holding" want opposite responses and were the same `false`.

Two further judgement calls recorded so they are not mistaken for oversights:

- **`registry/fleet.json` was not changed.** Flipping itajara to `broker` would
  break producing-with-your-feet, which connects to `ws://127.0.0.1:3028` and
  would receive a 307 it cannot follow. The app must adopt `/where` first. The
  procedure is in `ENSURE-AND-LOCATE.md` §3.
- **`serveMode` is read from the raw registry rows** (`registryHints`), beside
  `registryClaims` and for the same reason: it is an instruction to the
  *router*, not a property of the *service*. Threading it through
  `ServiceInstance` → reconcile → `LooseService` would put an operational
  preference into the deployment IR, and would have to answer "what does it mean
  when the compose facet and the registry facet disagree" — a question nobody is
  asking.

## 8. Testing it by hand

`fixtures/broker/registry.json` carries one row of every shape, all harmless
(`python3 -m http.server`, `nc -lU` under `/tmp`; ports 8180–8189 reserved).

```bash
cd /Users/afc/work/afc-work/ShapedSteer/bosun

# what it WOULD do, binding nothing
node cli/run.js serve --plan fixtures/broker/registry.json

# a scratch router beside the live one — BOSUN_SERVE_STATUS_PORT exists for
# exactly this, since a router whose whole job is holding ports is otherwise
# untestable without taking the real one down
BOSUN_SERVE_STATUS_PORT=3996 node cli/run.js serve fixtures/broker/registry.json

node cli/run.js where --port 3996 loopdemo:worker   # rewritable  → ws://127.0.0.1:28180
node cli/run.js where --port 3996 sockdemo:worker   # unix socket → /tmp/bosun-broker-demo.sock
node cli/run.js where --port 3996 8182              # udp: located, probe `none`, 200
node cli/run.js where --port 3996 9999              # unknown → the router's own sentence

curl -si localhost:8180/index.html | head -3        # the 307, path preserved
curl -s   localhost:3996/where/plaindemo:frontend   # the proxied control row
curl -so /dev/null -w '%{http_code}\n' localhost:8183/   # …still relays. 200.
```

The last two lines are the regression check that matters: `plaindemo` has no
`serveMode`, and must behave exactly as it always did.

**Against the real registry**, which must show no change at all:

```bash
node cli/run.js serve --plan registry/fleet.json | grep -E '^(ADMITTED|BROKERED|REDIRECT|REJECTED)'
# ADMITTED — 30 routable service(s):
# REDIRECT (421) — 5 remote service(s):
# REJECTED — 15 not routable:
#   ...and no BROKERED section
```

Lifecycle control over the same fixture (added 2026-08-24):

```bash
curl -s -X POST 'localhost:3996/control/spawn?port=8180'   # brokered, starts it
curl -s -X POST 'localhost:3996/control/stop?port=8180'    # stops it; pid null in /state
curl -s -X POST 'localhost:3996/control/spawn?service=sockdemo:worker'  # portless
curl -s -X POST 'localhost:3996/control/stop?port=8182'    # probe `none`, no child → 409 unknown
curl -s -X POST 'localhost:3996/control/stop?port=9999'    # nothing here → 404, and says so

# the regression check that matters: plaindemo has no serveMode
curl -s -X POST 'localhost:3996/control/spawn?port=8183'   # {ok,serviceId,up,bound} — unchanged
```

Reclaiming an adopted 307 door (added 2026-08-24) — the §7.4 fix, which needs a
real `EADDRINUSE` and so cannot be reached from the spec suite:

```bash
python3 -m http.server 8180 --bind 127.0.0.1 &   # hold loopdemo's registered port
BOSUN_SERVE_STATUS_PORT=3899 node cli/run.js serve fixtures/broker/registry.json &
#   ≈ :8180 already held — loopdemo:worker is brokered, so serve steps aside
curl -s localhost:3899/state | jq '.brokered[] | {serviceId, bound, door}'
#   loopdemo:worker  bound:false  door:"aside"   (the other three: door:"none")
kill %1                                          # the holder goes
#   ↺ :8180 holder is gone — reclaiming the 307 door for loopdemo:worker
#   bound :8180 → 307 → ws://127.0.0.1:28180 (loopdemo:worker, brokered — no relay)
curl -si localhost:8180/index.html | head -1     # HTTP/1.1 307 Temporary Redirect
```

Note the `--bind 127.0.0.1`: without it python takes `*:8180` on IPv6 and the
router's `127.0.0.1` bind succeeds beside it, so there is no `EADDRINUSE` and
nothing to test.

`spago test` — 194 passing, of which 10 are the broker admission cases, 7 the
`brokerStopVerdict` cases and 8 the `brokerDoor` cases in
`test/test/Test/Bosun/ServeSpec.purs`. The first two of those exist specifically
to pin the default: an unhinted service, and a service hinted `proxy` or
misspelled, must both plan identically to before.

## 9. Where the code is

| file | what landed |
|---|---|
| `core/src/Bosun/Serve.purs` | `Mediation`, `ServeHint`, `Broker`, `ServePlan.brokered`, `servePlanWith`; the admission rules of §5.3 |
| `protocol/src/Bosun/Protocol.purs` | `Locator`, `WhereResult` + codecs — the contract, once |
| `adapters/src/Bosun/Adapters/Registry.purs` | `registryHints`; and `unix://` urls now ingest as a `Socket` address instead of `noNetwork` |
| `cli/src/Bosun/CLI/Serve.js` | `ensureAndLocate` (exported — §6 is an adapter over it, not the thing itself), `bindBroker`/307, `GET /where`, and the §3 hardening |
| `cli/src/Bosun/CLI/Serve.purs` | the JS boundary records, `encodeWhere`, `bosun where` |
| `core/src/Bosun/Report.purs` | the `BROKERED` section of the admission report |
| `docs/ENSURE-AND-LOCATE.md` | the operator + client reference |
| `fixtures/broker/registry.json` | one row of every broker shape, all harmless |
