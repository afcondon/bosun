# Phase 7 (P3, Go column) — the Go binary IS the router

**The flagship concurrent purescript-go app.** A PureScript program compiled by
**backend-go** to a native Go binary runs the pure admission pipeline
(`reconcile → servePlan`) *as Go* and then **is** the resident lazy-spawn reverse
proxy — `bosun serve`, the SDI replacement, as a single static Go binary. This
is the tier that needs real concurrency (goroutine-per-request), so it is the
tier that needed the thunk thread-safety fix.

## Run it

```bash
cd /path/to/bosun
./scripts/go-serve.sh
```

No manual setup. The script builds Bosun, transpiles the I/O-free harness
`Bosun.Conformance.ServeMain` via backend-go, copies in `runtime.go` **and
Bosun's own resident-proxy foreign**, `go build -race`s, runs the binary as a
resident router, fires **8 concurrent requests** at the public port, and asserts
HTTP 200 — clean under the race detector. Each request lazy-spawns (once) the
python backend on the internal port and proxies to it.

## What it proves

1. **The pure core transpiles and drives a resident server.** `servePlan` (the
   typed admission control) runs as Go; its `Route` records cross the foreign
   boundary into the proxy shim unchanged. Same pure plan as the node column —
   only the resident shim differs (JS ⇄ Go).
2. **Concurrency is safe.** Goroutine-per-request, the spawned-child + idle-timer
   state guarded by a mutex with single-flight on first request, run clean under
   `go build -race`. The companion `scripts/go-race.sh` proves the underlying
   runtime guarantee directly: 16 goroutines forcing one shared CAF, race-free.
3. **The lazy-spawn lifecycle works end-to-end as a native binary:** bind →
   first request spawns the backend (port rewritten public→internal) → wait for
   it to listen → reverse-proxy → idle-reap (SIGTERM the process group).

## The two kinds of Go this needed — and where each lives

P3 touched backend-go in **one** place and Bosun in **one** place, on opposite
sides of a deliberate line:

| Change | Where | Why there |
|---|---|---|
| `sync.Once` thunk fix in `_force` | **backend-go** `runtime.go` | **app-agnostic** runtime correctness — every concurrent purescript-go program benefits |
| the resident reverse-proxy shim | **Bosun** `conformance/go/bosun_serve_foreign.go` | **app-specific** foreign — `package main`, copied into the build by `go-serve.sh`; backend-go stays app-agnostic |

This is the same layering rule as Phase 6C (the os-exec foreign lives in Bosun),
with the new wrinkle that a *runtime* fix legitimately belongs **in** backend-go.
The test: does it depend on what the app does? The proxy does (it's Bosun's). The
thread-safe thunk doesn't (it's everyone's). See `docs/PHASE-6C-GO.md` for the
app-specific-foreign rationale and the ABI reference.

## The sync.Once runtime fix (the gating crux, now resolved)

Stock `_force` mutated `done`/`forcing`/`val` with no synchronization and
panicked on a re-entrant force — a data race plus a spurious "cyclic strict
initialization" panic the moment a shared CAF is forced from multiple goroutines.
A per-thunk `sync.Once` fixes it (forced once, read race-free). Committed in
backend-go; `scripts/go-race.sh` is the regression guard (default asserts clean;
`--stock` reverts the fix on a build-dir copy to re-show the breakage).

**Tradeoff, and who owns it:** `sync.Once` turns a genuine *eager self-cycle*
from a panic into a deadlock. That input has no valid value either way, and
backend-go doesn't emit it (cyclic typeclass-dict clusters break their cycles
with deferred lazy `\_ -> dict` edges). The one case where a deadlock is worse
than a panic — a single hung goroutine in a resident server, invisible to Go's
deadlock detector — is owned at the **serve layer**, not the runtime: the proxy
foreign puts a per-request context deadline on the spawn/readiness wait (→ 504)
and a `ReadHeaderTimeout` on the server, so a stuck request can't silently wedge
a goroutine forever.

## Foreign ABI note (nested values)

Unlike the apply foreign (a scalar `String` arg), the serve foreign receives an
`Array Route` — `[]any` of `map[string]any`. The `GetProp`/`GetIndex` accessors
in the codegen don't wrap results in `_force`, so a nested field *could* still be
a lazy thunk. The shim therefore passes every extracted value through `_force`
(a no-op on a non-thunk) before asserting its Go type.
