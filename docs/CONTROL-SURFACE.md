# Control surface + live dashboard — two-session work split

Status: **PLANNED** (2026-06-16). The Chair becomes Bosun's live operational
surface: the graph overlays real runtime state and (modally) drives control.
Work is split across two Claude sessions; they meet at the serve HTTP contract.

## The seam (already exists)

- `GET  :3997/state` → `StateView { routes[], redirects[], rejected[], drift[], stale, registry }`
  where `RouteStatus = { serviceId, publicPort, internalPort, up, pid }`
  (decoded in `chair/src/Chair/State.purs`).
- `POST :3997/control/spawn?port=N` · `/control/stop?port=N` · `/control/reload`
  (already called by the Cockpit; restart = stop then spawn).
- **Correlation:** `/state` keys by canonical `serviceId`; graph nodes key by
  `localName`. Map through `reconcile.aliases` (ingested→canonical), which
  `analyze` already returns in the `AnalyzeResult`.

## Engine session (core / serve / CLI — owns `main`)

1. **Stand up `bosun serve` against a SAFE fixture registry** — a dump whose
   backends are dummy/no-op so dashboard dev never spawns the real rig. (`serve`
   lazy-spawns real backends; option 1 = frozen corpus is the real rig and is
   for *operating*, not developing against.)
2. Confirm `/state` + `/control/*` contract stable; **CORS** allows POST from
   the `:3020` frontend.
3. Own the **observe/control seam** abstraction — `observe` (→ the view model)
   + `control` (commands), with Docker-on-Node as the first impl, kept clean so
   a BEAM observer drops in later (`docs/BEAM-OBSERVER.md`, Phase 2).

## Chair session (frontend — `chair/`)

1. **Live overlay (read-only, modeless first):** ✅ DONE (2026-06-17). The Cockpit
   poll already fills `s.cockpit`; `Chair.Main.liveMap` correlates it to graph
   nodes and `graphView` takes a `Map String NodeLive` channel. Each node gets a
   status dot — green up / red (pulsing) down / indigo redirect (421) / **nothing**
   for unknown, so the overlay is silent on non-serve fixtures (truly modeless, no
   toggle). Composes with every layout (deps/host/pack) and every other channel.
   - **Correlation:** node id = `localName`; /state keys by `projectSlug:role`.
     `reconcile.aliases` (ingested → canonical) bridges merged compose+registry;
     where there's no alias, the instance's own `project:role` is the canonical id.
2. **Blast-from-down:** ✅ DONE. Any node serve reports `down` auto-drives the
   blast-radius amber over its transitive dependents (always on, no click).
   - **Demo fixture:** `fixtures/topologies/live/{compose.yml,registry.json}` — the
     compose (containerised) + registry (native) facets of the six services the
     SAFE serve fixture admits; reconcile bridges them by directory basename so each
     pair is one node whose canonical id == the serve serviceId. Load it with the
     **◉ live demo** button in the Graph toolbar. Stop `ledger:api` (port 8194) in
     the Cockpit and watch almost the whole graph wash amber.
3. **Armed control + unified runtime overlay:** ✅ DONE (2026-06-17). The earlier
   "modal + timeout" was superseded by the armed-control decision (full identity at
   the point of action). When armed, serve-managed route nodes become fill-buttons
   — stopped → green **launch**, running → split red **stop** | blue **reboot** —
   wired to `/control/spawn|stop` (reboot = stop+spawn).
   - First cut (`659c7eb`) made control a rack channel beside "live status"; the
     two thumbnails read as near-duplicates (Andrew). **Reworked**: live status
     and control are now ONE fixed **runtime overlay** in the top-right corner (a
     status minimap — green up / red down / indigo redirect + an N/M-up count).
     The overlay IS the arm toggle (no separate affordance): click → arm; the
     overlay's dots GREY OUT (their job moves to the on-map buttons) and it wears a
     pulsing red frame; click → disarm. Live status on the main map is now
     always-on (modeless), suppressed only while armed.
   - Safety preserved: arming is a deliberate, single, loud act; while armed a
     node's select-click is removed (a click can only start/stop/reboot); the node
     keeps name/role/host on top; pulsing red frame + "⚠ ARMED" banner on the map
     AND the red corner overlay. The bottom dock keeps only the 7 structural
     channels. The nav's old top-right status chip is hidden in Graph view (the
     overlay owns the corner and the count).
4. Graph becomes the primary live surface; the Cockpit table stays as a
   secondary view.

**Autonomy is now the engine session's turn** — auto-restart of `Always`,
crash-coupling (`binds-to`/`part-of`), failover. Requirements + the optional
`/state` fields and atomic `/control/restart` ask are in `HANDOFF-ENGINE.md`.

## Control APIs — what exists vs autonomous behaviour (2026-06-17)

Updated decision (Andrew): control affordances live **on the main-map nodes**, not
the minimap — you want full identity (name/role/host) at the point of action so you
can't kill the wrong thing. Safety = an **armed control channel** (toggle it on in
the rack → nodes turn into split fill-buttons; off → inert), which subsumes the
earlier "modal mode + timeout".

- **EXISTS now (real, per-process):** start = `POST /control/spawn?port`, stop =
  `/control/stop?port`, reboot = stop+spawn, reload = `/control/reload`. Enough for
  the armed control-minimap: stopped node → whole-rect green = launch; running node
  → split red/blue = stop | reboot; all manual, all real (red↔green transitions come
  through the existing 1.5s /state poll).
- **NOT YET — autonomous behaviour:** a stopped-but-`Always` process auto-returning;
  crash-coupling so `binds-to`/`part-of` reboot together; failover. `bosun serve` is
  a lazy-spawn proxy — it does NOT enact the IR's `restart{base,backoff}` or the
  requirement-gradient coupling. The IR already MODELS both; enactment is missing.
  Get it via either (a) a "supervisor mode" in serve honouring restart policy +
  `binds-to`/`part-of` co-restart (engine session), or (b) the BEAM observer where
  restart + `one_for_all = part-of` are native (`BEAM-OBSERVER.md`, Phase 2).

## Integration

Light coupling — both sides can move in parallel against the contract above.
Chair needs serve running on a safe fixture to develop against; that's the
engine session's first task.

## Engine session — status (2026-06-16): DONE, contract verified live

The Chair's dependency is unblocked. Run serve against the safe fixture and
develop against `:3997`:

```
node cli/run.js serve fixtures/serve/registry.json
#   binds 4 proxy + 2 redirect public ports; /state + /control on :3997
```

`fixtures/serve/registry.json` is now a **dashboard-dev fixture** (was a thin
1-service admission demo): 4 admitted mbp Processes (gallery:frontend,
gallery:api, atlas:frontend, ledger:api — each a harmless lazy-spawned
`python3 -m http.server` over `fixtures/serve/site`, so spawning any of them
NEVER touches the real rig), 2 macmini redirects (minard:frontend,
archive:api — a second host swimlane), and 2 instructive rejections
(no-cd-row, port-not-in-cmd). Multi-host + multi-node so the live overlay,
swimlanes, and the control modal all have something to render. Not
golden-pinned — edit freely. Ports 8190-8197 reserved for it.

**Verified end-to-end against a running resident loop:**

| Endpoint | Result |
|---|---|
| `GET /state` | shape matches `Chair.State.decodeStateView` exactly (routes/redirects/rejected; `up`, `pid`) |
| `OPTIONS /control/*` | `204` + `access-control-allow-origin: *`, methods `GET,POST,OPTIONS` — POST from `:3020` is allowed |
| `POST /control/spawn?port=8190` | `{ok,serviceId,up:true}`; `/state` then shows `up:true` + real `pid`; proxy `GET :8190` → `200` |
| `POST /control/stop?port=8190` | `{ok,up:false}`; `/state` returns to `up:false`, `pid:null` |
| `GET :8193` (a macmini route) | `421` + `location` header → tailnet URL (the redirect path) |
| `POST /control/reload` | typed `serveDiff`; no-op `{unbound:[],boundRoutes:[],boundRedirects:[]}` on an unchanged fixture |

**Tasks 2 & 3 were already landed** before this session: the `/state` +
`/control/*` contract and CORS live in `cli/src/Bosun/CLI/Serve.js`; the
observe/control seam abstraction (Docker-on-Node now, BEAM observer later) is
specced in `BEAM-OBSERVER.md`. Correlation reminder for the overlay: `/state`
keys by canonical `serviceId` (`projectSlug:role`), graph nodes key by
`localName` — map through `reconcile.aliases` from `AnalyzeResult`.

## `supervise` control surface + hot-reload (2026-07-07, note #397)

`bosun supervise` exposes the SAME `/state` + `/control/*` seam as `serve`
(HANDOFF-CHAIR contract), so the Chair drives either. Its control verbs:

| Verb | Effect |
|---|---|
| `POST /control/up` | desired=up; bring the group up (the Chair's ▲) |
| `POST /control/down` | desired=down; tear down + suspend auto-restart, forget launch memory |
| `POST /control/restart?service=<id>` | force ONE service to restart (mark it `Failed`; the planner does the rest, incl. `binds-to`/`part-of` co-restart) |
| `POST /control/reload` | **NEW** — re-read compose+registry, diff, restart ONLY what changed |

**Hot-reload (`/control/reload`).** Before this, the compose was captured once at
supervisor start; changing any service spec (env, command, cwd, port) meant
killing and relaunching the supervisor *process*. Now `reload` re-reads both
spec files, reconciles+validates them, and applies a **`SuperviseDiff`** — the
supervise analogue of `serve`'s `ServeDiff` (`Bosun.Supervisor.superviseDiff`,
pure ⇒ rides node≡Go conformance). Keyed by `ServiceId`, it partitions by RESTART
SIGNATURE (`{ host, launch }` — what determines the actual running process):

- **unchanged** → left running, **launch memory preserved** (see the guard below);
- **changed** → old generation stopped + memory forgotten ⇒ next keep-alive tick
  relaunches with the new spec;
- **added** → next tick brings it up; **removed** → stopped, absent from new spec.

A reloaded spec that fails to parse/validate is **rejected** (`reload: rejected —
…`); the running group is left untouched. The response is a one-line summary,
e.g. `reload: 0 added, 1 changed, 0 removed, 1 unchanged`.

**The double-launch guard (note #397 part b).** A naive reload that FORGOT launch
memory would re-observe every service from scratch; a live UDP/socket daemon
(es9-daemon on OSC 57130, link-spike) is invisible to a TCP probe, so it would
read `Down` → "never launched" → `Start` a SECOND copy, colliding on the
CoreAudio device / OSC port. `superviseDiff` never touches unchanged services, so
their launch memory (the pgid the supervisor holds — the honest liveness signal)
survives the reload and they are never double-launched. **Corollary requirement:**
a UDP/socket/no-network daemon MUST declare `x-bosun.probe: process` so its
readiness is read by pgid, not by the TCP fallback (`effProbe` maps `process` →
`ProcessAlive`; the atlantis fixture already does this for es9-daemon/link-spike).

## `serve` drift + honest registration (2026-08-17)

**The failure this closes.** `registry/fleet.json` was written at 14 Aug 18:57
with a new row (itajara, server 186, `worker`, `:3028`). The `bosun serve`
running since 11:49 never learned about it. Three sources of truth disagreed for
three days — 53 rows on disk, 49 accounted for by the router, and a `chair-server`
reading the file so `:3022/api/ports` DID list it — and nothing said so. The
Chair renders the router's live view, so a correctly-registered, correctly-
persisted service was invisible. `REGISTER-A-SERVICE.md` promised "writes
fleet.json, reloads `bosun serve`"; the write happened, the reload didn't, and
nobody could tell.

Two things were wrong, and the second is the sharper one:

1. **The reload nudge was fire-and-forget AND silent.** `reloadBosunServeImpl`
   ran `curl` with `stdio: "ignore"` inside a `catch {}`. Router down ⇒ HTTP 200
   "created", no mention of the half that didn't happen.
2. **`/state.rejected` was captured once, at startup, and never refreshed by a
   reload.** So a row that arrived (or became unroutable) while the router was
   resident appeared in **no** bucket of `/state` — worse than refused,
   *invisible*. Itajara is in fact `PortNotInStartCommand` (its `startCommand`
   carries no literal `3028`), so even a perfect reload would not route it; but
   nothing anywhere said that, which is what made three days of confusion
   possible.

**What `/state` now carries.**

| field | meaning |
|-------|---------|
| `rejected[]` | seen and unusable — **refreshed on every reload**, and each entry now carries `publicPort` so a refusal joins to its fleet row |
| `drift[]` | `{ serviceId, publicPort, kind, note }` — the registry on disk vs the plan the router holds. `kind` is `unrouted` (registered, never seen — THE bug), `altered` (held verdict is stale), `departed` (row gone, router still holding the port) |
| `stale` | `drift` is non-empty |
| `registry` | `{ source, plannedAt, modifiedAt }` — which file, when the router planned from it, when it was last written |

`drift` is `Bosun.Serve.planDrift held fresh`, pure and port-keyed, and it is
**strictly wider than `serveDiff`**: `serveDiff` answers "what would I bind
differently", which is silent about a row the router *refuses*; `planDrift`
answers "do these two agree at all". A refused row is therefore **agreement, not
drift** — the reason in `rejected` is the answer, and a reload would change
nothing. Both properties are PBT'd (`planDrift covers every port serveDiff would
rebind`, `planDrift is cleared by re-planning`).

The check is cheap: a file source caches on the registry's mtime+size stamp, so
it is computed **once per file version** however often `/state` is polled. (It is
deliberately NOT short-circuited to `[]` when the file is byte-identical to what
the router planned from: that holds only for the staleness kinds, and
`unaccounted` is a property of the file itself, so it would be permanently
invisible — the same bug one level down.) The 5s TTL only governs the live-URL
source, where there is no stamp and a check costs a curl.

**A live finding on the first run (2026-08-17):** ports **3031, 3032, 3034** —
three `polyglot-pythia-showcases` rows — are `unaccounted`. Five rows share two
`projectSlug:role` pairs (`juliet-bravo-juliet-mike:api` ×2,
`:frontend` ×3), so reconcile keeps one of each and the other three are dropped
with no diagnostic anywhere. They hold ports in the registry and are served by
nothing. Fixing them means giving each row a distinct `role`.

**`POST /control/reload`** now also returns `routes[]`, `redirects[]`,
`rejected[]` and `drift[]` — the post-reload verdict on *every* port, not just
the deltas. Necessary because "not in `boundRoutes`" is not "not routed": an
unchanged row is already bound.

**`bosun reload [--port N]`** (new subcommand) POSTs that endpoint, prints what
was bound, then reads `/state` back and says whether the two now agree. For the
two cases the chair-server write path cannot cover: the router was down when the
row was written, or the file was edited by hand.

**Why no auto-reload on mtime change.** A reload unbinds and rebinds changed
ports, which kills live backends. Doing that from a file watcher, with no
operator in the loop, trades a visible-and-fixable problem for an invisible one
in the other direction. And the write path already reloads, so a watcher would
only ever cover hand edits — precisely the case where the operator is sitting
there and can type `bosun reload`. So: **detect and report staleness, make the
remedy one action away, never act unbidden.**
