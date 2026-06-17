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
