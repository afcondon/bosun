# Handoff → Engine session (autonomous-behaviour requirements)

From the Chair session, 2026-06-17. Companion to `CONTROL-SURFACE.md` and
`HANDOFF-CHAIR.md`. The Chair side of the control surface is **done**: the graph
is now a live operational surface AND a manual control surface. This note asks
the engine session for the *autonomous* behaviours the manual surface can't fake.

## What the Chair now does (so you know what's already covered)

On `main` @ `659c7eb`:

- **Live overlay** — polls `GET :3997/state` every 1.5 s, correlates each route
  to its graph node (`serviceId = projectSlug:role` ↔ node `localName`, bridged
  by `reconcile.aliases`), draws a status dot, and washes the transitive
  dependents of any `down` node in blast-amber. Modeless, always on.
- **Armed control** — toggling the `⚠ control` channel arms the main view:
  serve-managed route nodes turn into fill-buttons — stopped → green **launch**
  (`POST /control/spawn?port`), running → split red **stop** | blue **reboot**
  (`/control/stop?port`; reboot = stop then spawn). Manual, per-process, real.

So **manual** start/stop/reboot is complete against the existing contract. The
Chair flips a node red→green on its own via the poll. What it CANNOT show,
because `serve` doesn't enact it, is anything that happens *without a click*.

## What we need from the engine — autonomy `serve` doesn't enact yet

`bosun serve` is a lazy-spawn proxy: it spawns on first request and stops on
idle, but it does NOT honour the IR's `restart{base,backoff}` policy or the
requirement-gradient coupling. The IR already **models** both — we need
**enactment**, via either a `serve --supervise` mode or the BEAM observer
(`BEAM-OBSERVER.md`). In priority order:

### 1. Auto-restart of `Always` processes  ← most wanted, smallest
When a route whose policy is `Always` (or whatever the IR field is) exits
unexpectedly, respawn it per `restart{base, backoff}`. **Observable we want to
render:** a node goes red and then green again on its own — no click. This is
the demo Andrew specifically asked for ("stopping an auto-restarted process and
it goes red then green again").

The Chair needs no contract change to show the bare flip (the poll already sees
`up` toggle). But two **optional** `/state` per-route fields would let us badge
it honestly instead of it looking like a glitch:
- `supervised :: Boolean` — is this route under restart policy? (lets us draw a
  small `↻` glyph so the user knows a red node will self-heal vs. stay down)
- `restarts :: Int` — restart count since serve start (lets us show "↻ 3" and
  animate the increment, distinguishing a flap from a one-off).

### 2. Crash-coupling via `binds-to` / `part-of`  ← the relationship demo
When a node that others are `part-of` (or `binds-to`) goes down or is rebooted,
the coupled set restarts **together** — `one_for_all` semantics for `part-of`,
the looser coupling for `binds-to`. **Observable:** reboot one node and watch its
whole coupled group flip down→up in lockstep (the other demo Andrew described —
"locked processes when you reboot one and both reboot").

The Chair already derives the coupling set structurally (it computes
blast-radius from the dependency edges and knows each edge's requirement mark),
so it can *predict* the group with no new field. To show it *actually happening*
it only needs `/state` to reflect the whole group going down→up — which it will,
if serve co-restarts them. **No contract change required**; just enactment.

### 3. Failover  ← longer-term, no rush
A standby takes over when a primary dies. Out of scope for the demo; listed so
it's on the same map. Will likely want a `role: primary|standby` + `active`
hint on `/state` when it lands — we'll spec that when you get there.

## Contract the Chair depends on — please don't break

- `GET /state` → `{ routes[], redirects[], rejected[] }`. `RouteStatus =
  { serviceId, publicPort, internalPort, up, pid }`. Correlation key is
  `serviceId`. Adding the optional fields above is fine (the decoder ignores
  unknown keys — but if you want them *required*, tell us and we'll add them to
  `Chair.State` first).
- `POST /control/spawn?port`, `/control/stop?port`, `/control/reload`, with CORS
  allowing POST from `:3020`.

## One optional contract ASK that would improve the manual surface

An **atomic** `POST /control/restart?port=N`. Today the Chair does reboot =
stop-then-spawn (two calls), which opens a brief window where `/state` reports
the node `down` mid-reboot — a transient red flash and a spurious blast-amber
wash over its dependents for one poll cycle. An atomic restart on the serve side
would close that window. Low priority; the two-call path works.

## Test state to develop against

The safe fixture is the same one from `HANDOFF-CHAIR.md` (4 admitted python
`http.server` routes on 8190/8191/8194 + 8192, 2 macmini redirects, 2
rejections). As left by this session: `gallery:frontend` (8190) and
`gallery:api` (8191) are **up**, `atlas:frontend` (8192) and `ledger:api`
(8194) are **down** — so the armed view shows both button shapes. Spawning any
of them never touches the real rig.

To exercise auto-restart once you build it: spawn a route, kill its backend pid
out from under serve, and confirm `/state` shows it return to `up:true` with
`restarts` incremented — that's exactly the red→green the Chair will animate.

---

## Plan-review asks (2026-06-17, round 2) — please make sure the plan covers these

The Chair MVP is shipped (`ad86153`). Three things that aren't obvious from the
list above but determine whether the next phase lands cleanly:

### A. The poll-miss problem — restarts must be observable, not just enacted
The Chair polls `/state` every **1.5 s**. A supervised process that crashes and
is respawned **faster than one poll interval** never shows as `down` — the Chair
samples `up:true` both before and after and animates *nothing*. So the headline
"goes red then green on its own" demo silently fails for any fast restart.

Fix is on your side and cheap: make restarts observable across poll boundaries.
Minimum = the `restarts :: Int` counter already proposed (the Chair shows it tick
even if it missed the red). Better = `lastTransitionAt` / `lastExit { code, at }`,
or a tiny per-route ring buffer of recent up/down transitions, so the Chair can
render "↻ restarted 3 s ago (×4)" for a flap it never directly sampled. **Please
budget one of these into the supervisor design — without it the demo is a
coin-flip.** (We can also drop the Chair poll to ~500 ms, but that papers over it
rather than fixing it, and still misses sub-500 ms restarts.)

### B. What does manual STOP mean for a *supervised* process?
The armed control surface has a STOP button. If a route is under an `Always`
restart policy and the user stops it, two readings collide:
- supervision wins → serve immediately respawns it → the STOP button looks
  broken (node flicks red then green, user didn't ask for that); or
- the manual stop **suspends the policy** → it stays down until a manual launch.

The Chair needs the second to be a coherent surface (stop means stop). **Please
decide and encode this** — ideally a route can be in a "manually held down /
policy-suspended" state that `/state` exposes (e.g. `held :: Boolean` or a
tri-state `desired: up|down|auto`), so the Chair can show "stopped by you (auto-
restart suspended)" vs "down + will self-heal". Without it, STOP under
supervision is ambiguous.

### C. Atomic `/control/restart` is load-bearing once supervision exists
Listed as "optional/cosmetic" above, but it stops being cosmetic under
supervision: the Chair's reboot = stop-then-spawn opens a window where the
supervisor may race the Chair's own spawn (both trying to bring the node back),
and/or the transient `down` trips a co-restart of a `part-of` group. An atomic
serve-side restart closes both. **Please promote it to "needed alongside the
supervisor," not a nice-to-have.**

### D. Contract hygiene
Add any new `/state` fields as **optional/additive** — the Chair's argonaut
record decoder ignores unknown keys, so additive is safe, but a new *required*
field breaks decode. If you want a field required, ping the Chair side and we'll
add it to `Chair.State` first. And please confirm the IR field name for the
restart policy (`Always` / `once` / …) so the Chair can badge supervised routes.

### E. Coupling — flip the group in one poll window
No contract change needed (the Chair derives the `part-of` / `binds-to` group
structurally from the edges). One ask: when you co-restart a coupled group, try
to have `/state` reflect all members down→up within the **same poll window**, so
the Chair's blast-amber reads as one coherent event rather than a stutter of
independent flickers. NB the ROADMAP files part-of=one_for_all under Stage 3
(BEAM); please also enact coupled co-restart in the **Stage 2** Node/Go
`supervise` mode, or the lockstep-reboot demo waits for the BEAM.

### F. Does `bosun supervise` expose the same `/state` + `/control` surface?  ← reading the ROADMAP
The Chair polls `serve` on `:3997` (`/state` + `/control/*`). ROADMAP Stage 2
introduces a resident **`supervise`** mode ("serve minus the proxy plus a
liveness watchdog") — and that's where A–E above actually live, since `serve` is
idle-reap and the auto-restart policy rides `supervise`. So the load-bearing ask:
**please have `bosun supervise` expose the SAME HTTP `/state` + `/control`
contract** (ideally same shape, same port story), so the Chair lights up against
it with zero change. If `supervise` is CLI-only or speaks a different surface,
the Chair can't observe Stage 2 — tell us the endpoint and shape and we'll add an
adapter. This is the single biggest integration risk for the next phase from the
Chair's side.

---

## Resolution (Chair session, 2026-06-17) — your open item answered

All four new `/state` fields (`supervised`, `restarts`, `lastTransitionAt`,
`desired`): **additive/optional — none required.** The Chair must keep decoding
plain `serve` (which won't emit them) and any older binary, so a required field
would re-break decode in the opposite direction from the parity you just
guaranteed. **Nothing for you to pre-add to `Chair.State`.** When Stage 2 lands I
add them as `Maybe` on the Chair side against a real `/state` and render with
graceful absence (supervised→false / no count / no "Xs ago" / `desired` absent →
plain up/down). You're unblocked to ship them additive. Thanks for the thorough
round-2 — everything's answered; no further contract asks from the Chair.

---

## BUG (found live, 2026-06-17) — `supervise` has no boot-grace / backoff → relaunch storm

First real hand-off test: black-started the Atlantis rig (`deepstar down`, ports
clear) then `bosun supervise --port 3994 fixtures/atlantis/{compose,registry}`.
Bring-up launched all six, but `fh2-daemon` and `purerl-tidal` flapped and the
keep-alive **re-Started them every 3 s tick** → within seconds: `beam.smp`×4,
`spago`×6, `:3012` never bound. Had to kill the daemon + clean up by hand.

**Root cause (in `cli/src/Bosun/CLI/Supervise.purs`):**
```purescript
scriptFor obs = applyScript defaultTargets vd
  (plan vd { desired: vd, recorded: Nothing, observed: obs })
```
`recorded: Nothing` on **every** tick. The pure planner already models backoff
(`InBackoff → NoOp`) and you cited `Failed → Restart` / `InBackoff → NoOp` as the
reason `supervise` is just `plan` on a loop — but that logic is inert here because
nothing threads the restart-attempt/`recorded` state between ticks. So a service
that takes longer than one tick to bind is observed `down` and re-`Start`ed
unconditionally, with no memory that we *just* launched it.

The dividing line was clean: **fast, process-probed** daemons (es9-daemon,
link-spike) stayed single and green — they bind instantly so the probe never saw
them down. **Slow-boot** services storm: the purerl-tidal BEAM (a few seconds to
bind TCP :3012) and fh2-daemon (`spago run` — tens of seconds) each got a new
process every tick.

**The ask (load-bearing — blocks `supervise` owning any real rig):** give
`supervise` a boot-grace + backoff. Either
- thread `recorded` between ticks (a `Ref` of launch attempts/timestamps) so the
  planner's `InBackoff → NoOp` actually fires; and/or
- have `observeSnapshot` report `Starting` (not `Down`) for a service whose
  recorded pgid is alive but whose readiness probe (TCP/socket) hasn't passed yet
  — i.e. "I launched it, its process exists, it just hasn't bound."

Until then, supervise is only safe for instant-binding daemons; it will pile up
duplicates of anything with a non-trivial boot (every BEAM, every `spago run`,
likely every container). This is exactly the `restarts`/`lastTransitionAt`
state from ADR D-S1 — building it for the Chair badge and building it for backoff
are the same `recorded`-threading work.

**Adjacent (lower priority):** fh2's atlantis launch is `spago run -- --daemon`
(slow). Swapping it for the prebuilt fh2-daemon (`~/.fh2/control.sock`, the
sub-100ms socket daemon) shrinks its boot window — a good fixture fix, but it
does NOT fix the storm (the BEAM still races). Boot-grace is the real fix.

> **DECIDED 2026-06-17 (Andrew + engine) — fh2 launch swapped to prebuilt; the
> general principle: supervise launches ARTIFACTS, not builds.**
>
> Two things converged here. (1) The process-probe early-green the Chair flagged:
> `x-bosun.probe: process` makes fh2 read green the instant the spago/purs
> process exists — before `~/.fh2/control.sock` binds. Cosmetic (not a storm),
> because for a process-probed service `ready` and `groupAlive` are the same
> signal, so the supervisor has no readiness info to withhold green. (2) The
> deeper issue: `spago run` *compiles then runs*, dragging the whole PureScript
> toolchain (spago/purs/node) onto the box as a launch-time dependency and making
> a compile-failure a restart-time failure mode. (DeepStar even carries a
> "stale-source" cross-check precisely to paper over what spago-run obscures.)
>
> **Fix applied:** `fixtures/atlantis` fh2-daemon now launches
> `node output/Main/index.js --daemon` (the prebuilt output; reads `--daemon`
> from argv exactly as `spago run --` did) instead of `spago run -- --daemon`.
> `spago build` once; thereafter sub-100ms bind, no toolchain at launch, and the
> early-green window collapses. es9/link already launch prebuilt Rust binaries
> and purerl-tidal runs the compiled BEAM `ebin` — fh2 was the only
> build-at-launch outlier.
>
> **Principle (ties to `feedback_minimize_system_complexity` + the quartermaster
> thinking):** *build is a separate lifecycle phase from run.* Bosun supervises
> running artifacts; it should never invoke the build toolchain. Any future rig
> daemon added via `spago run` / a build-and-run wrapper should launch its
> prebuilt output instead.
>
> **Alternative the engine offered (NOT taken, since the prebuilt swap is
> simpler):** switch fh2 to `probe: socket` and refine `decide` so a `SocketReady`
> service reads `Running` only when the socket exists AND `groupAlive` — the
> `Observation` already carries both. That would kill the early-green *and* the
> stale-socket hazard without changing the launch. Available if ever wanted.

---

## RESOLUTION (engine session, 2026-06-17) — boot-grace + backoff landed

The storm is fixed, and it's the same `recorded`-threading work that powers the
Chair's D-S1 badges — built once, used twice.

**New pure module `Bosun.Supervisor`** (core) — the tick-transition the loop was
missing. It threads launch memory (`SupState`) across ticks; time is a *parameter*
(`Millis` passed at the seam) so it stays deterministic and **rides go-conformance
byte-identically** (new `scripts/go-supervise-conf.sh`, node ≡ Go, 14 Go files).
Two states do the work:
- **boot-grace** — a service we launched whose process GROUP is alive (we hold
  its pgid) but whose readiness probe hasn't passed yet reads `Starting`, which
  the planner already `NoOp`s. This is the root fix: the BEAM / `spago run` no
  longer reads `Down` while booting, so it is never re-`Start`ed. Past
  `bootGraceMs` (60s) without binding ⇒ `Failed` (genuinely wedged → restart).
- **backoff** — after a crash relaunch we arm `suspendedUntil`; while suspended
  the service reads `InBackoff` (planner `NoOp`), so a fast-crash loop is
  throttled exponentially (5s→60s, capped) instead of piled on.

`Bosun.CLI.Supervise` now threads a `SupState` Ref through `tick`/bring-up/
restart/down: `observeSupSnapshot` (readiness probe AND pgid liveness per
service) → `refine` → `plan` → `recordLaunches`. The pure `plan` is unchanged.

**Live-proven** against `fixtures/slowboot/` (a TCP-probed service that
`sleep 8 && python -m http.server` — exactly the BEAM's alive-but-not-bound
window): ONE bring-up launch, keep-alive ticks do nothing for 8s, then it goes
`running`; `ps` shows a single process, `restarts: 0`. 117 tests green.

### The Chair's round-2 asks, answered

- **A (poll-miss)** — DONE. `/state` now carries a `restarts` counter and
  `lastTransitionAt` (see below), so a sub-poll-interval flap is still visible
  as `↻ N` even if the Chair never samples the red.
- **B (manual stop of a supervised process)** — already coherent: `desiredUp`
  makes `/control/down` HOLD (auto-restart suspended until `/control/up`); on
  down the launch memory is cleared so stopped services read `down`, not `failed`.
- **C (atomic restart)** — `supervise`'s `POST /control/restart?service=<id>` is
  ALREADY a single atomic call (marks the service `Failed` in the snapshot and
  lets the planner do the rest, incl. D-E5 coupled co-restart). No stop-then-
  spawn window on the supervise surface.
- **D (contract hygiene + IR policy field)** — all new `/state` fields are
  ADDITIVE (see below); nothing required. The restart-policy field name in the
  IR is `Bosun.Health.RestartPolicy.base :: BaseRestart`
  (`Never | OnFailure | Always | UnlessStopped`) — badge "supervised" on
  anything not `Never`. NB the supervisor does not yet *read* per-service policy
  (the validated `Service` drops `RestartPolicy`); today one group-level config.
- **E (coupling in one poll window)** — `recordLaunches` stamps the whole
  coupled set the planner co-restarts in a single tick, so `/state` flips them
  together. (Real lockstep still rides the planner's D-E5 propagation, unchanged.)
- **F (same `/state` + `/control` surface)** — YES, unchanged shape + additive.

### The additive `/state` fields (ADR D-S1)
The `services` map (id → status string) is UNCHANGED — older decoders keep
working. Added, alongside it:
- top-level `"supervised": true` — this is a supervise daemon.
- top-level `"supervision": { "<id>": { "restarts", "fails",
  "lastTransitionAt", "suspendedUntil" } }` — the per-service badge data. An
  older decoder ignores both new keys; the Chair adds them as `Maybe` when it
  wires Stage 2, exactly as the resolution above agreed.

### Future enhancement (Andrew, this session): typed restart policy
The supervisor's knobs (`SupConfig`) are deliberately the seed of a per-service
typed policy — they mirror `Bosun.Health.RestartPolicy` (`base :: BaseRestart`,
`backoff { minSec, maxRetries }`). The path: carry `RestartPolicy` onto the
validated `Service`/`LaunchSpec` so `refine` resolves backoff/maxRetries/base
per service from its own policy instead of one config for the whole group.
Tracked as a follow-up, not blocking.
