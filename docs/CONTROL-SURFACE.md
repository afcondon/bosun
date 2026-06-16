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
