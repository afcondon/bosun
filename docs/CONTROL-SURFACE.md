# Control surface + live dashboard — two-session work split

Status: **PLANNED** (2026-06-16). The Chair becomes Bosun's live operational
surface: the graph overlays real runtime state and (modally) drives control.
Work is split across two Claude sessions; they meet at the serve HTTP contract.

## The seam (already exists)

- `GET  :3997/state` → `StateView { routes[], redirects[], rejected[] }`
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

1. **Live overlay (read-only, modeless first):** poll `/state` (Cockpit already
   does), pass live `RouteStatus`-by-serviceId + the alias map into `graphView`;
   each node gets a status dot (green up / red down / grey unknown). Composes
   with every layout (deps/host/pack) like any other channel.
2. **Blast-from-down:** a node serve reports `down` auto-drives the existing
   blast-radius amber, so live fallout is visible.
3. **Control modal (next increment):** explicit mode toggle with a TIMEOUT and a
   loud banner — you must not kill a service while exploring. In control mode a
   node click offers spawn/stop/restart via `/control/*`. Decision (Andrew):
   modal, timeout, maximum visual clarity about which mode you're in.
4. Graph becomes the primary live surface; the Cockpit table stays as a
   secondary view.

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
