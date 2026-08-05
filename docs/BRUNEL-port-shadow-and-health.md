# Brunel: the port-shadow incident, and the three defects it exposed

*Written 2026-08-03, from a live incident. `bosun serve` silently shadowed
Amphora (`:3024`) for a whole day; a webapp that fetched `localhost:3024` hung
on every request while Bosun's Chair reported the service **running**. This note
is the spec for the durable fixes — the immediate mitigation is already applied
(see §5) but it patches the symptom, not the cause.*

---

## 1. What happened

- Amphora runs standalone, bound to **`0.0.0.0:3024`** (IPv4). Healthy: every
  endpoint answers 200 in ~2 ms.
- `bosun serve` (the lazy-spawn reverse proxy, `node cli/run.js serve
  registry/fleet.json`) read Amphora's fleet entry — local `host: mbp`, a
  `startCommand` with `3024` in it — classified it as a **Route**, and bound
  **`127.0.0.1:3024`** to lazy-spawn it on demand (`Serve.js`,
  `INTERNAL_HOST = "127.0.0.1"`).
- Both binds coexisted with **no `EADDRINUSE`**: Node sets `SO_REUSEADDR`, and a
  `127.0.0.1:P` bind does not collide with an existing `0.0.0.0:P` bind.
- The kernel routes `localhost` / `127.0.0.1` connections to the **more-specific**
  `127.0.0.1` socket — i.e. **serve**, not Amphora. Serve then tried to
  lazy-spawn a *second* Amphora (port already taken) and **hung**.
- The app is served at `localhost:3023`, so its `window.location.hostname`-derived
  client fetched `localhost:3024` → straight into the hung shadow → "store
  offline."

The service was fine the entire time. Everything that observed it lied.

## 2. The three defects

### 2a. `adopt` keys on `EADDRINUSE`, which a `0.0.0.0` incumbent never raises

`Serve.js` already has the *right idea*. In `bindRoute`, the `server.on("error")`
handler treats `EADDRINUSE` as **ADOPT**: the public port is already served by
something serve didn't start, so serve marks the route `external = true`, steps
aside, and reports it running-external rather than fighting for the port. The
comment is explicit: *"exactly right for 'I'm working on this one locally
myself'."*

**The defect:** adoption is triggered **only** by `EADDRINUSE` on serve's own
`listen(port, "127.0.0.1")`. When the incumbent is bound to `0.0.0.0` (the normal
case — most daemons bind all interfaces) and serve binds `127.0.0.1`,
`SO_REUSEADDR` means **no error fires**, so `adopt` never runs. Serve believes it
owns a port it is in fact shadowing. The safety mechanism is defeated by the most
common bind configuration it was meant to protect.

**Fix options:**

- **(A) Pre-bind liveness probe.** Before `listen`, attempt a TCP `connect()` to
  `127.0.0.1:port` (and/or the public interface). If it connects, an incumbent
  exists → adopt without ever binding. *Cost:* one connect per route at
  startup/reload; a short timeout. *Pro:* catches `0.0.0.0`, `127.0.0.1`, and
  `::1` incumbents uniformly; no reliance on error codes. *This is the
  recommended primary fix.*
- **(B) Bind `0.0.0.0` instead of `127.0.0.1`.** Then a `0.0.0.0` incumbent *does*
  raise `EADDRINUSE` and adopt fires. *Cost:* serve's proxy would then be exposed
  on all interfaces (a posture change, possibly unwanted); doesn't catch a
  `127.0.0.1`-only incumbent from a *different* interface. Weaker than (A).
- **(C) Probe on `EADDRINUSE` *and* periodically.** Combine (A) with a re-check so
  an incumbent that appears *after* serve bound (serve started first) is detected
  and adopted on the next tick, instead of serve permanently owning the port.

The decision lives at the pure/edge seam. The *policy* — "a reachable incumbent
on this port ⇒ adopt" — belongs in the pure planner as an input to the
`Admission` (a new `Adopted` outcome, or an `external: Boolean` on `Route`). The
*probe* (an actual socket connect) is inherently edge (`Serve.js`), like
`Date.now`/timers. Keep the verdict pure, the I/O at the edge.

### 2b. Health is inferred from port-binding, not from the endpoint

Bosun's Chair reported Amphora **running** throughout, because *a* process held
`:3024`. It was the wrong process, hung. **Port-binding is not liveness.**

**Fix:** health must be an **HTTP (or protocol-appropriate) probe of the actual
endpoint** — `GET /health` (or a configured readiness path) returning 2xx within
a timeout — not "is the TCP port bound." This also subsumes the readiness-vs-
liveness distinction already noted in `HANDOFF-ENGINE.md` (a port can bind before
the service is ready, and — as here — stay bound after it stops answering).

Scope note: a probe needs a per-service readiness path (or a default). Services
with no HTTP surface (sockets, daemons) need an equivalent check; absent one,
"port bound" is the honest floor, but it must be *reported as such* ("bound, not
probed"), never as "running."

### 2c. IPv4/IPv6 bind inconsistency across the fleet

During diagnosis the obvious escape hatch — reach each service via the LAN /
tailnet address instead of `localhost` — failed, because the fleet mixes
families: `static-httpd` binds **IPv6** `*:3023`, Amphora binds **IPv4** `*:3024`.
No single host address (IPv4 LAN, IPv6, tailnet name) reaches both, so
host-based routing and any "just use the tailnet URL" workaround are unreliable.

**Fix:** a fleet-wide bind-family convention (dual-stack, or a declared family per
service that tooling can honor), so the public address of a service is
predictable and a client/proxy can always reach it.

## 3. Reproduce

```
# 1. incumbent on 0.0.0.0
node -e 'require("http").createServer((_,r)=>r.end("real")).listen(9999,"0.0.0.0")' &
# 2. serve-style shadow on 127.0.0.1 — NOTE: no EADDRINUSE
node -e 'require("http").createServer((_,r)=>{/* hang */}).listen(9999,"127.0.0.1",()=>console.log("shadow bound, no error"))' &
# 3. observe: localhost hits the shadow (hangs); the LAN/0.0.0.0 path hits the real one
curl -m2 http://127.0.0.1:9999/     # hangs
curl -m2 http://$(ipconfig getifaddr en0):9999/   # -> real
lsof -nP -i :9999 -sTCP:LISTEN       # BOTH: 127.0.0.1 and *:9999
```

The `lsof` showing both a `127.0.0.1:P` and a `*:P` listener is the signature.

## 4. Constraints for the fix

- **Pure-core / edge seam.** Admission decisions (`core/src/Bosun/Serve.purs`
  `admit` / `arbitrate` / `servePlan`) stay pure and total; socket probes,
  timers, signals stay in `cli/src/Bosun/CLI/Serve.js`. Adoption becomes a typed
  outcome the planner emits, driven by a probe result passed in — not an
  `if (err.code === "EADDRINUSE")` buried in the error handler.
- **node ≡ Go conformance.** The planner rides a node/Go differential-conformance
  discipline; any new `Admission` variant or `Route` field must keep both sides
  byte-identical. Add fixtures covering: `0.0.0.0` incumbent, `127.0.0.1`
  incumbent, `::1` incumbent, no incumbent.
- **`arbitrate`'s single-binder guarantee** already rejects a *second in-fleet*
  claimant of a port (`PortClaimed`). It does **not** see an *out-of-fleet*
  incumbent — that's exactly the gap 2a fills. The two are complementary:
  `arbitrate` dedups within the plan; the probe dedups against the world.

## 5. Immediate mitigation already applied (a stopgap, not the fix)

In `registry/fleet.json`, Amphora's (`id: 159`) `startCommand` is set to **`null`**
— the documented "documentation / collision-avoidance only, not actionable by
serve" state: a null-startCommand row classifies as a `Reject` (`admit` →
non-`Process` executor), so serve binds nothing and `localhost:3024` falls
through to the real Amphora. Reload with `kill -HUP <serve-pid>` (SIGHUP
hot-reload). Verified: `:3024` then held only by Amphora, `localhost:3024` 200 in
~2 ms.

**Why it's only a stopgap:**

- It relies on a human remembering that any Atlantis-supervised / externally-run
  stateful service must have `startCommand: null` in the *serve* fleet. The
  general rule "stateful, externally-supervised ⇒ not a serve lazy-spawn target"
  is not enforced anywhere.
- `fleet.json` may be regenerated by chair-server (`:3022`) registration (the
  Marginalia seam). A rewrite can clobber the `null` and reintroduce the shadow.
  The durable form of this mitigation belongs in the registry **source**, or is
  made unnecessary by fix 2a (with 2a, an already-running Amphora is *adopted*
  regardless of its `startCommand`).

The `null` bought a working rig today. 2a makes it unnecessary; 2b stops the next
one hiding this long; 2c removes the false escape hatch. That's the Brunel work.
