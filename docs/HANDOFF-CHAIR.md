# Handoff → Chair session (live-overlay + control-modal work)

From the engine session, 2026-06-16. Companion to `CONTROL-SURFACE.md`
(the two-session split) — this is the "your dependency is ready, go" note.

## Branch state (read first)

Everything is consolidated onto `main`. The shared working tree is now on
**`main` @ `ca1ca4a`** (clean) — work there, not on `force-ghosts`.
`force-ghosts` is stale at the old `53e68a1`; if you want it, `git branch -f
force-ghosts main` or just delete it. `origin/main` is pushed and current.

## Your dependency is unblocked — `bosun serve` runs against a safe fixture

```
node cli/run.js serve fixtures/serve/registry.json
#   binds 4 proxy + 2 redirect public ports; /state + /control on :3997
```

Every admitted backend is a harmless lazy-spawned `python3 -m http.server` —
spawning any of them **never touches the real rig**. The fixture is 4 admitted
mbp Processes (`gallery:frontend`, `gallery:api`, `atlas:frontend`,
`ledger:api`), 2 macmini redirects (`minard:frontend`, `archive:api` — your
second host swimlane), and 2 rejections. Ports `8190-8197`.

## The contract is verified live (build green, exercised end-to-end)

- `GET :3997/state` → `{routes[], redirects[], rejected[]}`, shape **exactly**
  `Chair.State.decodeStateView` (`RouteStatus = {serviceId, publicPort,
  internalPort, up, pid}`). All routes start `up:false, pid:null` until
  spawned — good for blast-from-down dev.
- `OPTIONS /control/*` → `204` + `access-control-allow-origin: *`, methods
  `GET,POST,OPTIONS`. **POST from `:3020` is allowed.**
- `POST :3997/control/spawn?port=N` → `up:true` + real `pid`;
  `/control/stop?port=N` → down; `/control/reload` → typed `serveDiff`.
  (`404` if no proxy route on that port.)
- macmini routes answer `421` + `location:` → tailnet URL (not proxied).

## Correlation rule for the overlay

`/state` keys by canonical `serviceId` (`projectSlug:role`); your graph nodes
key by `localName`. Map through `reconcile.aliases` from the `AnalyzeResult`
you already get from `/analyze`. Note `/state` is the *status* source only —
graph structure (deps for blast-radius, host for swimlanes) still comes from
`/analyze`, so to see correlated colour, your `/analyze` fixture's services
should share `serviceId`s with the serve fixture above (or extend the serve
fixture to mirror your graph — it's not golden-pinned, edit freely).

## Ownership

Engine session owns core/serve/CLI/fixtures; `chair/` is yours. Full runbook +
the verification table are in `docs/CONTROL-SURFACE.md` under "Engine session —
status". Ping via Andrew if you need a contract change or a richer fixture.

---

## Reply (engine session, 2026-06-17, round 2) — answering HANDOFF-ENGINE.md

Read your asks 1–3 and A–F. Good news first: **the pure planner already makes
most of these decisions** — `supervise` is `plan` run on a loop, not new logic.
From `core/src/Bosun/Plan.purs` (`baseChange`):

| observed status | planned change |
|---|---|
| `Failed` | `Restart ref Crashed` — **auto-restart already decided** (your ask 1) |
| `InBackoff` | `NoOp` — **backoff already respected**, no thrash |
| `Down` | `Start` |
| `Running`/`Starting`/`CompletedOk` | `NoOp` |

…and it **already propagates** `Restart yref (DependencyRestarted xid)` to
dependents — **coupled co-restart is already computed** (your ask 2 / E). So
Stage 2's `supervise` = observe → `plan` → enact, on a loop. The decision tier
is pure, conformance-gated, and tested; only the watch-loop + the additive
`/state` fields are new.

### D — the restart-policy IR field name (you asked me to confirm)
`Service.restart :: RestartPolicy` (`core/src/Bosun/Health.purs`):
```
RestartPolicy = { base :: BaseRestart, conditions :: Array RestartCondition
                , backoff :: { minSec :: Int, maxRetries :: Maybe Int } }
BaseRestart   = Never | OnFailure | Always | UnlessStopped     -- compose semantics
```
Badge supervised routes off `base /= Never`. I'll also surface it on `/state` (below).

### 1 + A — auto-restart, made observable across poll misses
Enacted by the loop. To beat your 1.5 s poll-miss, `/state` `RouteStatus` gains
(all **additive/optional** — your decoder ignores unknown keys):
- `supervised :: Boolean` — `base /= Never` (draw the `↻` glyph)
- `restarts :: Int` — monotonic respawn count since supervise start (you render
  "↻ 3" and animate the tick even if you never sampled the `down`)
- `lastTransitionAt :: Number` — ms epoch of the last up/down flip ("↻ 3 s ago")

That's the minimum + the "better" you asked for, without a ring buffer.

> **RESOLVED (Chair, round 3):** all four stay **additive/optional, none
> required** — a required field would re-break decode against plain `serve` and
> older binaries that don't emit them (the opposite direction from the parity
> guarantee). Nothing to pre-add to `Chair.State`; the Chair adds them as `Maybe`
> with graceful-absence rendering when Stage 2 lands. Pinned as **D-S1** in
> `DECISIONS.md`. No further `/state` contract asks from the Chair.

### B — what manual STOP means under supervision (decided)
**Operator intent wins: STOP holds.** `/state` gains `desired :: "up" | "down"`.
Manual `/control/stop` sets `desired=down` and **suspends auto-restart** (the
`UnlessStopped` behaviour, applied to operator action uniformly across base
policies — so "stop means stop" even for an `Always` process). `/control/spawn`
sets `desired=up`. The base policy still governs **crash** response when
`desired=up`. So you can render honestly: `supervised && desired=down` → "stopped
by you (auto-restart suspended)"; `supervised && desired=up && !up` → "down, will
self-heal".

### C — atomic `/control/restart?port=N` (promoted to needed, agreed)
Adding it to **both** `serve` and `supervise`. Server-side it cycles the backend
without the `desired=down` detour, ticks `restarts`, and — under supervise — is
issued as one planner batch so the supervisor can't race your spawn and the
transient `down` won't trip the co-restart group. Your two-call reboot keeps
working; this just closes the window.

### E — coupled co-restart in Stage 2 (not waiting for the BEAM)
Confirmed, and I corrected the ROADMAP: `part-of`=one_for_all co-restart is
**enacted in the Stage 2 Node/Go `supervise` mode** via the planner's existing
`DependencyRestarted` propagation; Stage 3/BEAM only makes it *native* OTP. The
loop enacts a coupled group as one staged batch (stop-all-then-start-all within
a stage), so `/state` flips the whole group down→up inside one poll window —
your blast-amber reads as one event, not a stutter.

### F — does `bosun supervise` expose the SAME `/state` + `/control`? (YES)
**Unequivocally yes**, same shapes, same `:3997` story. `serve` and `supervise`
will **share the HTTP/control layer** (`controlRouter` + `stateBody` in the
resident shim) and differ only in lifecycle policy (lazy-spawn+idle-reap vs.
keep-alive+restart-on-crash). Contract parity by construction — **you light up
against `supervise` with zero change**. This was your biggest integration risk;
it's closed by design.

### 3 — failover: agreed out of scope; we'll spec `role`/`active` when it lands.

### Net: no breaking change to your contract.
Everything above is additive `/state` fields + one new control verb. The
existing `{routes,redirects,rejected}` / `RouteStatus{serviceId,publicPort,
internalPort,up,pid}` / `spawn|stop|reload` + CORS-for-`:3020` all stay exactly
as they are.
