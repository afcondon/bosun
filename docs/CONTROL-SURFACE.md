# Control surface + live dashboard — two-session work split

Status: **PLANNED** (2026-06-16). The Chair becomes Bosun's live operational
surface: the graph overlays real runtime state and (modally) drives control.
Work is split across two Claude sessions; they meet at the serve HTTP contract.

## The seam (already exists)

- `GET  :3997/state` → `StateView { routes[], redirects[], rejected[], drift[], stale, registry }`
  where `RouteStatus = { serviceId, publicPort, internalPort, up, pid, external,
  externalCheckedAt, bound, bindError }`
  (decoded in `chair/src/Chair/State.purs`).
- `POST :3997/control/spawn?port=N` · `/control/stop?port=N` · `/control/reload`
  (already called by the Cockpit; restart = stop then spawn). Both verbs also
  take `?service=<projectId:role>` — the only way to address a **brokered**
  daemon that holds no port at all (es9-daemon on a unix socket), and the key
  `/state` and `/where` already print. See "Brokered services" below.
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
   - **Correlation:** node id = `localName`; /state keys by `projectId:role`.
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

## Brokered services (added 2026-08-24)

Broker mode shipped able to **start** a service and not to stop it. `/where`
lazy-spawns a brokered daemon, so the router holds its child — but
`/control/spawn|stop` looked only at the proxy table and answered `no proxy
route on :N` for every brokered port, which was a refusal and a misdiagnosis in
one sentence. Both verbs now reach brokers, keyed the way `/where` keys them:
the registered port, the port the service actually listens on, or `?service=`.

The rule for whether a stop is allowed is the **proxy path's rule**, not a
second one — bosun does not kill what bosun did not start. A broker keeps no
adoption flag (ensure-and-locate probes before it spawns and reports `started:
false` on a survivor without recording it), so the fact is re-derived by a probe
at the moment it is asked. `Bosun.Serve.brokerStopVerdict` decides; the shim
gathers evidence and acts.

| situation | answer |
|---|---|
| bosun holds the child | `200 {ok, wasRunning: true}` — SIGTERM, then SIGKILL at the grace deadline; resolves when it has actually exited |
| running, no child of ours | `409 {adopted: true}` — stop that process yourself; the next `/where` finds it gone and starts a fresh one |
| no child, `probe: "none"` | `409 {adopted: null}` — nothing here can say whether something is running, and an `ok` would read as "it's down" |
| no child, probe says nothing is there | `200 {ok, wasRunning: false}` |

`/control/stop` on a broker does **not** suspend the lazy-spawn: `/where` is
ensure-and-locate, so asking it again starts the service again, by design.
`/state` is the read-only view — it shows `pid: null` without starting
anything. And stopping the *process* is still a different act from unbinding the
*route*: `unbindPort` continues to leave a brokered daemon running, because
taking a 307 listener down is no reason to take an audio interface away.

The two "no route" diagnostics are now distinct, because they want opposite
responses from an operator:

```
POST /control/stop?port=8193     # a 421 redirect to another host
  -> :8193 is a 421 redirect to minard:frontend on another host, so this router
     has no process here to stop. Ask the bosun on that host.

POST /control/stop?port=9999     # nothing at all
  -> no proxy route, no broker and no redirect on this router answers to :9999.
     GET /state lists everything it holds; if you expected one, the registry row
     may never have been admitted — see /state's "rejected" and "drift".
```

### The 307 door is not the daemon (added 2026-08-24)

A brokered row's *listener* on its registered public port and the *process*
behind it are separate things, and the `/state` fields say so separately.
`bound :: Boolean` was carrying four situations at once — and the comment beside
it claimed two:

| `brokered[].door` | what it means | what to do |
|---|---|---|
| `none` | the row names no public port (es9-daemon is a unix socket) | nothing; `/where` is the door |
| `open` | the router holds the port and answers `307` there | nothing |
| `aside` | something else holds the port and still answers | if that is the daemon itself, fine; else stop the holder |
| `reclaim` | the holder has gone; the router is binding it again | nothing — it is a moment, not a state |
| `blocked` | the bind failed for a reason no probe can clear (`EACCES`) | read `bindError` |

`doorCheckedAt` is when the adoption claim was last put to the test. Only
`aside` is swept: it goes to `reclaim` and then `open` the moment the holder
exits, on the same `ADOPTION_WATCH_MS` clock, from the same `recheckAdopted`,
that reclaims an adopted *proxy* port. Before this it was never swept at all,
so a brokered public port adopted at bind time stayed adopted forever — the
`:3028` bug of 2026-08-17 living on in the new bucket.

Reclaiming a door touches `bound` and the adoption claim and **nothing else**.
Not the child, not `ready`. A brokered service has one arm in that sweep where a
proxy route has two, and the missing one is the point: there is no broker
equivalent of the `adoptedBackend` re-check, because a broker records no
adoption claim that could go stale — `brokerStopVerdict` re-derives ownership by
probing at the moment it is asked. Only the listener needs a clock, because a
port we stepped aside from has no other event that could tell us the holder left.

**Tasks 2 & 3 were already landed** before this session: the `/state` +
`/control/*` contract and CORS live in `cli/src/Bosun/CLI/Serve.js`; the
observe/control seam abstraction (Docker-on-Node now, BEAM observer later) is
specced in `BEAM-OBSERVER.md`. Correlation reminder for the overlay: `/state`
keys by canonical `serviceId` (`projectId:role`), graph nodes key by
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

**Two addressing schemes, and each refusal now names the other (2026-08-24).**
`serve` keys by **port**; a group keys by **service id**. Ask the wrong one and
the honest answer used to be `no service `X` in this group` — which reads as
"that daemon is not down" about a daemon that is up and lazy-spawned by the
router, and sends an operator looking for a registry problem
(FINDINGS-supervision-blind-spots.md §4). `Bosun.Supervisor.addressService`
splits that one sentence five ways, and `supervise` and `docker` share it:

```
POST :8789/control/restart?service=8790
  -> restart: `8790` is a port, and a supervise group has no port to match it
     against — it addresses services by id, and GET /state lists the ids it
     holds. Ports are the ROUTER's key: if :8790 is a lazy-spawned service it is
     in no group at all, and POST :3997/control/stop?port=8790 is the command
     you want.

POST :8789/control/restart?service=itajara
  -> restart: no service `itajara` in this group, under that spelling or any
     other. GET /state lists the ids it holds. A service can also be absent
     because it is LAZY-SPAWNED rather than supervised — those belong to the
     router on :3997 and are in no group: try GET :3997/state, then
     POST :3997/control/stop?service=itajara.
```

Note it points at the router's `stop`, not `restart`: the router has no restart
verb, and sending an operator to one that would 404 would undo the sentence. The
other three refusals — no `?service=` at all, one candidate id under a different
spelling, several candidates under one project — are in the findings doc's table. A
near miss is named, never acted on.

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
`projectId:role` pairs (`78:api` ×2, `78:frontend` ×3), so reconcile keeps one
of each and the other three are dropped with no diagnostic anywhere. They hold
ports in the registry and are served by nothing. Fixing them means giving each
row a distinct `role`.

*(Re-measured 2026-09-13, when the slugs became ids: **the duplicate situation
is unchanged**. Keying on `projectId` collapses 53 rows to the same 50 services
that `projectSlug` collapsed them to, and the three lost rows are the same
three. It could have gone either way — a many-to-one slug→id mapping would have
created new collisions, a many-to-one id→slug mapping would have resolved some —
but the mapping was one-to-one across all 39 projects the fleet names, so the
migration neither exposed nor resolved a single collision. These three rows were
always about two rows sharing a role, and that is still what they are.)*

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

## `serve` liveness: `up` must not outlive its evidence (2026-08-17, later)

The drift work above closed *registry vs router*. The same day turned up the
same shape one layer in — **router vs the world** — and the fix is the same
principle: re-derive the claim, don't remember it.

### Adoption was sticky, and a reload could not clear it

When a route's public port is already held, the router **adopts**: `/state`
showed `external: true, up: true, pid: null` and it bound nothing. That is right
for "I'm running this one myself". It was wrong the moment the external process
exited: the router went on reporting `up: true` for a port with **nothing
listening on it at all**, and because it still believed the port externally
owned, it never bound it, so lazy-spawn could never fire again. Unreachable, and
the router saying it was fine. Seen on `:3028` (itajara).

`POST /control/reload` did not help, and could not: **`applyReload` diffs
configuration.** The row on disk had not changed, so `serveDiff` never revisited
the route and the reload honestly reported `{boundRoutes:[], unbound:[]}`. Only
a full router restart re-planned it.

The fix — `recheckAdopted` in `cli/src/Bosun/CLI/Serve.js` — probes every
adopted route's public port and, when the holder has gone, drops the claim and
`listen`s again. It is called from **three** places, and all three earn it:

| caller | why |
|---|---|
| a 5s watch timer | the guarantee. A router nobody is polling must still reclaim a dead route, or recovery depends on someone looking. |
| `/state` | so `up` for an adopted route is a value just checked, not one remembered. `externalCheckedAt` says when. |
| `applyReload` | a reload is the operator's explicit "make it match reality" act. Leaving it a pure config diff means the one command reached for when something looks wrong is the one command that cannot fix this. |

Neither the timer nor the reload alone was enough: the timer alone leaves
`reload` still reporting a no-op against exactly this failure; the reload alone
needs an operator, and `up: true` stays a lie until one arrives.

`RouteStatus` also gained **`bound`** and **`bindError`**. A non-`EADDRINUSE`
bind failure used to leave the route in the ADMITTED table looking merely idle,
when in fact no request could ever arrive on it. `bound: false` + `external:
false` ⇒ nothing is listening. The Chair renders `external` and `unbound` as
distinct row states and hides the spawn/stop buttons for them (serve answers
`409` — there is no backend of ours to start or stop).

### A backend must not outlive its router

Backends are spawned `detached`, which they must be — their own process group is
what lets the whole subtree be signalled. That also means they do **not** die
with the router. One that was started via `/control/spawn` survived a router
restart and then raced the router's new child for the internal port; the loser
did not exit, so two daemons ended up holding one audio interface.

Two halves, because neither covers the other:

- **`process.on("exit"|"SIGTERM"|"SIGINT")` → SIGTERM every live backend.**
  Covers every ordinary end, including how `supervise` stops the router.
- **`reapOrphanBackends` at startup.** Covers the end no hook can: SIGKILL, or
  the machine going down. One `lsof`, and anything listening on one of *our
  routes'* internal ports is signalled by process group before a single port is
  bound. The claim that makes it safe is that the internal port is Bosun's by
  construction — `public + internalOffset`, chosen by the planner, never by a
  service — and the router was about to fight that process for the port anyway.

Related, and the cause of the race: `/control/stop` used to null the child handle
and answer immediately, so a Chair "reboot" (stop then spawn) could put the new
backend on the internal port before the old one had let go. `stopBackend` now
resolves only when the process has actually exited (SIGTERM, SIGKILL at 3s), and
`ensureBackend` waits on any stop in flight. The response carries `wasRunning`
and answers `ok: false` if the backend would not die.

### The gate

`scripts/serve-liveness.sh` — a scratch router over a throwaway registry on its
own control port (`BOSUN_SERVE_STATUS_PORT`, which exists only so a test router
can stand beside the live one). It adopts a real external holder, kills it, and
asserts the route recovers **without a restart**; then spawns a backend, kills
the router politely (no orphan), SIGKILLs it (orphan, as it must be), and
asserts the next router sweeps it before binding. Both defects are below the
pure plan, so the spec suite cannot reach them.

This is **option (C)** of `BRUNEL-DURABLE-FIXES.md` §3a ("a periodic re-probe"),
in the direction that was live. Option (A) — pre-bind probing, so adoption does
not depend on `EADDRINUSE` at all — is still open, and is still the one that
retires the `startCommand: null` stopgap; the probe it needs (`probePort`) now
exists.
