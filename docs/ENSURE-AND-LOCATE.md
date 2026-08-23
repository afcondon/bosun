# ENSURE-AND-LOCATE — "start it if you must, and tell me where it is"

**Status:** landed 2026-08-22. The operation, the wire contract, and how to opt
a service into it. The router that hosts it is `BOSUN-SERVE.md` (§3c is the
design rationale); this is the reference, and it wins where the others disagree.

The *reason* it exists — a proxied 30 Hz WebSocket that went deaf in one
direction, and the investigation that did not manage to diagnose it — is
`RELAY-STALL-AND-BROKER-MODE.md`. That note also carries the design rationale in
full (why `serveMode` is named for the router's role, which two proxy rules
broker relaxes and why each existed, and why `probe: "none"` answers 200), plus
four known gaps that are not fixed.

## 1. The operation

> Make sure this service is running, and tell me the address I should dial.

One operation, three consumers, and it is deliberately not "an HTTP endpoint on
the router" with the rest bolted on:

| where it lives | what it is |
|---|---|
| `ensureAndLocate(state)` in `cli/src/Bosun/CLI/Serve.js` | the operation. Probe → spawn → wait for the plan's readiness probe → answer. Exported, so anything embedding the shim can call it without HTTP. |
| `GET /where` on the control port (`:3997`) | a thin adapter over it |
| `bosun where <service\|port>` | a thin client over the adapter |
| `Bosun.Protocol.WhereResult` / `Locator` + codecs | the wire contract, one definition, shared by everything that decodes it |

The spawn and the readiness wait both happen **before** the answer is sent.
That is the contract: a caller that follows this answer finds a service that is
actually up.

The three questions are answered in an order that matters:

1. **Is it already up?** Probe first, always. These services are started
   deliberately, and often by hand. A pre-flight that reports "I started it"
   when it was already running is the wrong answer to the question asked.
2. **If not, start it** — once, single-flight, as the proxy path does.
3. **Did it become ready?** Wait for the probe the *plan* chose, and say which
   probe was made.

## 2. The wire contract

```
GET http://127.0.0.1:3997/where/<serviceId>
GET http://127.0.0.1:3997/where?port=<publicPort>
```

`<serviceId>` is the canonical `projectSlug:role` — the same key `/state` uses.
Ports are identity everywhere else in the router, so `?port=` works too.

```json
{
  "service":   "alpha-victor-echo-kilo:worker",
  "mediation": "broker",
  "ready":     true,
  "started":   false,
  "probe":     "tcp",
  "detail":    "already running; a TCP connect to :23028 passed",
  "at": {
    "transport": "tcp",
    "host":      "127.0.0.1",
    "port":      23028,
    "path":      null,
    "url":       "ws://127.0.0.1:23028"
  }
}
```

Flat and primitive on purpose: a Go caller consumes this with `encoding/json`
into a struct, with no client library.

### Fields

| field | meaning |
|---|---|
| `mediation` | **`broker`** — Bosun is NOT in the data path; `at` is the service's own address. **`proxy`** — Bosun relays; `at` is the router's public port and every byte goes through it. A client that must not be relayed (a 30 Hz socket, a UDP endpoint) should refuse to proceed on `proxy` rather than silently accept a hop. |
| `ready` | did the readiness probe pass **before** this answer was sent |
| `started` | did *this call* have to launch it. `false` = it was already running. |
| `probe` | which check was made: `tcp` · `socket` · `none`. **`none` means nothing was checked, not that a check failed.** |
| `detail` | one operator sentence: what happened, and why `ready` says what it says |
| `at.transport` | `tcp` · `unix` · `udp` · `none`. The discriminator; a string because the set is open at the edges. |
| `at.host`, `at.port` | populated for `tcp` / `udp` |
| `at.path` | the socket path, for `unix` |
| `at.url` | a dialable URL when the registry row's `url` gives a scheme — `ws://127.0.0.1:23028`, not something the client reassembles |

`at.transport: "none"` is not an error. A daemon can be worth starting and have
nothing to dial (a UDP fan-out with no listener of its own). Saying so beats
inventing a port for it.

### Status codes

| code | meaning |
|---|---|
| `200` | answered. Either the probe passed, or `probe: "none"` — nothing could be checked, and the body says so. |
| `503` | a check **was** made and it failed. The address is still in the body, so the caller can retry. |
| `404` | no such service is served here. `/state` lists what is. |

`probe: "none"` answering `200` with `ready: false` is deliberate. Bosun's rule
everywhere else (`PRINCIPLES.md`, `Bosun.CLI.Observe`) is that a probe kind it
cannot observe reports **unknown with a reason**, never a silent coercion to
down. A `503` for a UDP daemon nobody probed would be exactly that coercion.

## 3. Opting a service in

Add `serveMode` to its registry row (via chair-server `:3022`, per
`REGISTER-A-SERVICE.md` — not by hand-editing `fleet.json`):

```json
{ "role": "worker",
  "port": 3028,
  "serveMode": "broker",
  "url": "ws://127.0.0.1:3028",
  "startCommand": "cd /abs/path && ./itajara --ws-port 3028" }
```

**Default is `proxy`.** Absent, or an unrecognised value, means `proxy` — every
row written before this existed behaves identically.

Two other fields do more work than usual in broker mode:

- **`url`'s scheme** is how the answer can be dialable as written (`ws://`), and
  is the only place the registry can say a listener is **UDP** — `Reachability`
  has no transport axis, and inventing one for a single bit would be a far
  larger change than reading a scheme that is already written down.
- **`url` as `unix:///path/to.sock`** on a port-less row is how a socket daemon
  states its address at all. Before this, such a row ingested as `noNetwork`:
  startable, but with no address anybody could be told.

### What the plan does with each shape

| the row | Bosun binds | service runs at | readiness |
|---|---|---|---|
| port, literal port in the command | the public port, answering **307** | `public + 20000` | `TcpConnect` |
| port, **not** in the command | nothing | its own port | `TcpConnect` |
| `unix://…`, no port | nothing | the socket path | `SocketReady` |
| `udp://…` | nothing (there is no 307 over UDP) | its own port | **none** |
| no address at all | nothing | — | none |

`bosun serve --plan <registry>` prints all of it before anything binds.

## 4. Using it

### From a browser client

```js
const r = await fetch("http://127.0.0.1:3997/where/alpha-victor-echo-kilo:worker");
const w = await r.json();
if (w.mediation !== "broker") throw new Error("refusing to be proxied at 30 Hz");
const ws = new WebSocket(w.at.url);       // direct. Bosun is not in this socket.
```

Ask again on every reconnect — that is exactly the moment you want the
lazy-spawn and the readiness check to happen, and it costs one round trip.

### From Go (DeepStar's pre-flight)

```go
type Locator struct {
    Transport string  `json:"transport"`
    Host      *string `json:"host"`
    Port      *int    `json:"port"`
    Path      *string `json:"path"`
    URL       *string `json:"url"`
}
type WhereResult struct {
    Service   string  `json:"service"`
    Mediation string  `json:"mediation"`
    Ready     bool    `json:"ready"`
    Started   bool    `json:"started"`
    Probe     string  `json:"probe"`
    Detail    string  `json:"detail"`
    At        Locator `json:"at"`
}

resp, err := http.Get("http://127.0.0.1:3997/where/" + url.PathEscape(id))
```

"Is Link running?" becomes `where link-spike` and reading `ready` / `probe` /
`started` — rather than DeepStar doing its own process management.

### From the command line

```
$ bosun where alpha-victor-echo-kilo:worker
  alpha-victor-echo-kilo:worker — broker (bosun is NOT in the data path)
  at tcp 127.0.0.1:23028   ws://127.0.0.1:23028
  ✓ ready by probe `tcp`; already running
  already running; a TCP connect to :23028 passed
```

`bosun where 3028` does the same thing keyed by public port. `--port <n>`
addresses a router on a non-default control port.

## 5. Trying it without touching the rig

`fixtures/broker/registry.json` has one row of every shape, all harmless
(`python3 -m http.server`, `nc -lU` on `/tmp`). Stand a scratch router beside
the live one:

```bash
cd /Users/afc/work/afc-work/ShapedSteer/bosun
node cli/run.js serve --plan fixtures/broker/registry.json      # what it would do
BOSUN_SERVE_STATUS_PORT=3996 node cli/run.js serve fixtures/broker/registry.json

curl -s  localhost:3996/where/loopdemo:worker | jq        # broker, rewritable
curl -s  localhost:3996/where/sockdemo:worker | jq        # unix socket
curl -s  localhost:3996/where/udpdemo:worker  | jq        # udp: located, not probed
curl -si localhost:8180/index.html | head -3              # the 307
curl -s  localhost:3996/where/plaindemo:frontend | jq     # the proxied control row
curl -so /dev/null -w '%{http_code}\n' localhost:8183/    # …still relays, unchanged
```

`BOSUN_SERVE_STATUS_PORT` exists for exactly this: a router whose whole job is
holding ports is otherwise untestable without taking the real one down.
