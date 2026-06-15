# Bosun's Chair — design

A bosun's chair is the seat a sailor is hoisted up the mast in, to work and
watch from. **Bosun's Chair** is the cockpit for `bosun serve`: a dashboard to
*watch* the lazy-spawn router's live state and *control* it — and, because
watching + controlling processes under load is exactly what stress-testing
needs, it doubles as the test harness for the chaos suite (STRESS-TEST-PLAN.md).

## What it shows / does

Bosun `serve` already exposes a read-only JSON `/state` (P2) — the live route
table (per route: serviceId, public/internal port, up?, pid) plus the redirect
table. Bosun's Chair is the first real client of that surface.

**Watch (v0):**
- The admission picture: ADMITTED / REDIRECT / REJECTED, the same three-way
  `servePlan` produces — so a glance answers "what will the router serve, and
  what did it refuse and why."
- The live route table, polled: which backends are up, their pids, idle countdown.
- A log/event tail (spawns, exits, reaps, reloads).

**Control (v1):**
- Trigger a registry **reload** (SIGHUP equivalent) and show the resulting diff.
- **Spawn / stop** an individual backend on demand (warm it before a demo;
  reap it to reclaim RAM).
- Run **`--audit`** and render the up/down/ms result per route.

**Test cockpit (v1+):**
- Drive the chaos monkeys (request flood, backend-kill, SIGHUP storm,
  slow-backend) and visualise the router's response live — the §2 harness with
  a face. A passing chaos run is one where the table stays green.

## Architecture

```
  Bosun's Chair (Halogen, Swiss/light)         bosun serve (resident)
  ┌───────────────────────────────┐  poll      ┌────────────────────┐
  │ route table · admission · log  │ ─ GET ───► │  GET  /state       │ (have)
  │ [reload] [audit] [spawn][stop] │ ─ POST ──► │  POST /control/*   │ (to add)
  └───────────────────────────────┘            └────────────────────┘
```

- **Frontend:** Halogen, in the bosun spago workspace as the `chair` package, so
  it reuses `bosun-core`'s `Route` / `Redirect` / `ServePlan` types verbatim —
  the dashboard decodes the exact shapes serve emits, no drift. Swiss /
  International Typographic: light theme, grid, type-scale hierarchy, restrained
  palette (green=up, grey=down, amber=redirect, red=rejected). Dev server on
  :3020.
- **serve control API:** grow serve's status server (currently GET `/state`
  only) into a small control surface — `POST /control/reload`,
  `POST /control/audit`, `POST /control/spawn?port=`, `POST /control/stop?port=`.
  Each maps to machinery serve already has (reload→serveDiff apply; spawn/stop→
  ensureBackend/killBackend; audit→the audit foreign). The Chair never talks to
  processes directly — it asks serve, which owns them.
- **No new privilege:** the Chair is a *view + button panel* over serve's typed
  surface; all process authority stays in serve.

## Phasing

- **v0 — watch.** Halogen scaffold in the workspace; poll `/state`; render the
  admission three-way + live route table, Swiss styling; event log tail. Ships
  as a static bundle; dev on :3020.
- **v1 — control.** serve `/control/*` endpoints + Chair buttons (reload / audit
  / spawn / stop), each showing the typed result.
- **v1+ — chaos cockpit.** Drive the STRESS-TEST-PLAN §2 monkeys from the Chair
  and watch the router hold.

## Relationship to the family

Child of **Bosun** (#227). It is to `serve` what a process supervisor's UI is to
the supervisor — but typed end-to-end, sharing the reconciler's own vocabulary.
Distinct from DeepStar (the live-coding rig's CLI supervisor): that supervises
tier-1 audio daemons; this watches Bosun's lazy-spawn router.
