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
