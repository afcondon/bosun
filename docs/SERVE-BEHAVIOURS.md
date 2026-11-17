# What `bosun serve` does

The router has two implementations: `cli/src/Bosun/CLI/Serve.js` (node) and
`cli/src/Bosun/CLI/Serve.erl` (the BEAM). The second is not a translation of
the first. This list is what both are held to, and
`scripts/serve-behaviours/run.mjs` is the list as a test: it starts a scratch
router on its own control port over a throwaway registry and uses only its
ports, its control surface and the processes it starts.

```
node scripts/serve-behaviours/run.mjs                           # the node router
BOSUN_SERVE_CMD="beam/bosun" node scripts/serve-behaviours/run.mjs   # the BEAM router
```

Add `--quick` to skip the cases that wait on a long timeout, or `--only P`
for the cases whose name starts with `P`. A full run takes about three
minutes. The scratch router runs with 256 open files, which is what launchd
gives a service.

**Never start a scratch router on the real registry.** At startup a router
stops whatever is listening on its routes' internal ports (T2), so a second
router on `registry/fleet.json` would stop the live router's backends.

As of 2026-11-17 the BEAM router holds all 45 and the node router holds 39.

## The behaviours

Each name is the name of its case in the test.

### The control surface

| | |
|---|---|
| C1 | `GET /state` (and `GET /`) answers the router's document, which reads through `Bosun.Protocol.ServeState`. |
| C2 | Every answer allows any origin; `OPTIONS` is 204. |
| C3 | An unknown path is 404 with `ok: false`. |
| C4 | `POST /control/stop` answers when the backend is gone and its port is free, not when the signal was sent. A second stop says `wasRunning: false`. `POST /control/spawn` answers when the backend listens. A route can be named by `?port=` or `?service=`. |
| C5 | `GET /where/<service>` and `GET /where?port=` say where a relayed service is and start it if needed. `started` is true only when this call started it. Unknown is 404. |
| C6 | A backend that ignores SIGTERM is killed after 3 s, and stop still answers truthfully. |
| C7 | Stop takes the backend's child processes with it. |
| C8 | Spawn or stop on a port with nothing to act on says which kind of nothing: a 421 redirect, or nothing at all. |
| S1 | Every port, the control port included, is bound on loopback only. |
| J1 | A row the router cannot use is listed in `rejected` with its port and a reason, and its port is not bound. |
| R1 | A service on another host is answered 421 with the address to use, path included, and listed in `redirects`. |

### Relaying

| | |
|---|---|
| P1 | The first request starts the backend on the internal port and is answered by it. `/state` then shows `up` with a `pid`, which names the backend's process group. |
| P2 | Method, path, query, headers and body arrive at the backend; status, headers and body come back. A 1 MB body, a chunked body, a chunked answer and `HEAD` all pass. |
| P3 | Two requests on one connection are both answered (or the first answer says `connection: close`). |
| P4 | Many requests for a backend that is down start one process. |
| P5 | A backend that dies is shown down within 3 s, and the next request starts another. |
| P6 | A backend that closes without answering is a 502, and the route still works. |
| P7 | A backend that accepts and never answers is a 504 after 8 s. |
| P8 | A backend that never listens is a 502, at once when its process has already exited. |
| P9 | Bytes that are not HTTP are answered 400. |
| P10 | A client that finishes sending and then waits still gets its whole answer. |
| P11 | `Expect: 100-continue` works. |
| P12 | A start command that puts the service in the background is still served, by one process. |
| L1 | 160 slow requests at once, each needing two of the router's 256 files, are all answered. |
| U1 | An upgraded connection (a WebSocket) is carried both ways with the request replayed as it came. When either end closes, the other is closed. |

### Idleness

| | |
|---|---|
| I1 | A backend with nothing using it is stopped after the idle time (ten minutes; `BOSUN_SERVE_IDLE_MS` shortens it for a test), and the next request starts it again. |
| I2 | A backend with an open upgraded connection is not idle. |
| I3 | A backend still sending an answer is not idle. |

### Ports that something else holds

| | |
|---|---|
| A1 | A public port already held is adopted: `external: true`, nothing bound, and the holder keeps answering. |
| A2 | The same when the holder is bound to every interface. |
| A3 | Spawn and stop are refused (409) for an adopted route. |
| A4 | When the holder goes, the router takes the port within 10 s and serves it. |
| B1 | A backend already listening on the internal port is relayed to, not duplicated: `adoptedBackend: true`, no `pid`, stop refused (409). When it goes, the claim is dropped within 8 s and the next request starts the router's own. |

### Brokered services

| | |
|---|---|
| K1 | `/where` starts a brokered service and gives the address it really listens on. It answers to its registered port and to its real one. |
| K2 | Its registered port answers 307 to the real address, with `x-bosun-mediation: broker`, and carries nothing. An upgrade is refused with 307. |
| K3 | A brokered service the router started can be stopped. One started by hand cannot (409, `adopted: true`). |
| K4 | A service on a unix socket is started and located with no port anywhere; its door is `none`. |
| K5 | A service with nothing to check is started once and never called ready. A stop the router cannot stand behind is 409 with `adopted: null`. |

### The registry

| | |
|---|---|
| D1 | A registry edited on disk shows in `/state` as `drift` and `stale`, and nothing changes until a reload. |
| D2 | `POST /control/reload` unbinds what went or changed (stopping those backends), binds what is new, and leaves the rest alone: an unchanged route keeps its backend, an unchanged brokered service keeps its process, an adopted route stays adopted. The answer lists everything held afterwards. |
| D3 | SIGHUP is the same reload. |
| D4 | A registry that cannot be read is `registry.error` in `/state`, not agreement, and clears when the file is back. |

### Stopping the router

| | |
|---|---|
| T1 | On SIGTERM the router takes its relayed backends with it and leaves brokered services running. The next router finds a brokered one, and will not stop it. |
| T2 | A router that is killed leaves a backend behind. The next router stops it before binding. |
| T3 | Ctrl-C ends the router within 3 s, and no backend of its outlives the next router's start. |

## Where the node router falls short

Six behaviours, found by writing this list. None is fixed in `Serve.js`; the
BEAM router is the fix.

| | What the node router does |
|---|---|
| A2 | It binds `127.0.0.1` beside a holder on `0.0.0.0`, takes the holder's traffic, and starts a second copy. |
| C5 | `/where` on an adopted route says `started: true` for a service it did not start. |
| P8 | A backend that exits at once still costs the caller the full 30 s. |
| P10 | A client that finishes sending before the answer gets no answer. |
| L1 | Under 256 files, 48 of 160 requests at once were 502. |
| I3 | An answer longer than the idle time is cut off when the backend is stopped under it, and the client is left hanging. |

Two more that the test does not reach: a backend that takes over 30 s to
listen is left running and a second copy is started on the next request; and
an answer that pauses for 8 s is abandoned without the client being told.

## What the BEAM router does differently on purpose

- **One connection carries one exchange.** A plain request is replayed with
  `Connection: close` and then bytes are carried both ways until the backend
  closes. Nothing after the request head is parsed, so every body encoding,
  a streamed answer and a WebSocket are one path. The cost is that a client
  opens a connection per request, which on loopback is nothing.
- **Idle means no open connection**, counted by monitoring the connection
  processes. The node router timed from the last request and so cut long
  answers (I3).
- **`pid` is the backend's process group**, which is the launching shell.
  The node router's was often the service itself, because bash sometimes
  replaces itself with the last command. Stop signals the group and waits for
  the group to be empty.
- **`/state` is printed by PureScript** through `Bosun.Protocol.ServeState`.
  A field with nothing to say is left out where the node router wrote
  `null`, and the text is not indented.
- **A backend that does not listen in 30 s is stopped.**
- **The request head may be 64 KB**, against node's 16 KB.

## What the BEAM needed that node did not

Each of these was a failing case before it was a line of code.

- **A socket closes for writing when its peer finishes sending**, unless
  `exit_on_close` is off. P10.
- **Closing a socket with unread bytes resets it**, and the reset can
  overtake the answer. A 307 to a `POST` whose body was never read is the
  case. The router finishes writing, reads what is still coming for up to
  2 s, then closes.
- **SIGINT opens the BREAK menu and stops the VM running** until someone
  answers it. A resident command was left frozen and deaf to SIGTERM. The
  launcher now passes `+Bd`, so Ctrl-C ends it. The BEAM cannot run code on
  SIGINT, so the backends are left for the next router (T3).
- **The VM's own SIGTERM handler stops the VM and signals no child.** The
  router replaces it with one that stops the relayed backends first (T1).
- **A node HTTP server drops an exchange when the client finishes sending.**
  So the router does not pass a client's half-close on to the backend.
- **Out of files is a reason to wait.** `accept` retries, and the connect to
  the backend waits for a file for up to 30 s (L1). The launcher also raises
  the limit to 4096 for `serve` where it can.
- **PureScript's callbacks assume one thread.** `reload` and `drift` share a
  `Ref`; only the router process calls them.
- **A launching shell can exit while the service runs on** (P12). The keeper
  keeps the group and checks every 5 s whether it has emptied, since no exit
  will be reported for it.

## Not yet tested

- A keeper process that crashes. The router starts another, which finds the
  backend still on the internal port and relays to it; it then has no `pid`
  and is never idle-stopped. Written, not exercised.
- A bind that fails for a reason other than "in use".
- Reading the registry from the live URL rather than a file.
- `IPv6`: a holder on `::1` only is invisible to a router on `127.0.0.1`, in
  both routers.
