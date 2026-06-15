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
- **P2 — parity.** WebSocket upgrade, remote-host `421` redirect, registry
  hot-reload (SIGHUP), an `--audit` mode (spawn-test every row — reuses
  `observe`), `--plan`.
- **P3 — the Go column.** Transpile `serve` via backend-go with the `sync.Once`
  thunk runtime; concurrency-harden; run under `-race`; **replace the SDI
  launchd agent on the mbp.** This is the flagship concurrent purescript-go app.
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
- **Upstream the `sync.Once` thunk fix** into backend-go runtime.go? It gates
  the Go column and helps every concurrent purescript-go program.
- **Make our demos routable?** The python demos hardcode their port; a `$PORT`
  convention would let `serve` rewrite + route them instead of leaving them
  standalone.
