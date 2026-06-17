# Branch `force-ghosts` — placement & force/ghost experiments

Built while Andrew was out (2026-06-16), so the verifiable parts are done and
the *visual* parts are flagged for his eyes. Grounded in GRAPH-GRAMMAR §14
("placement is impossible to place; interrogate it"). To run: `spago bundle -p
bosun-chair`, restart `chair-server`, open `:3020` → Graph → **multi-host**, then
toggle **↹ group** and hover nodes.

## Done on this branch (verifiable — built 0 warnings)

1. **`x-bosun.host`** (compose adapter) — place a service on a named host.
   `fixtures/topologies/multihost` spreads 6 services over 4 hosts
   (edge-1 / app-1 / data-1 / data-2), with `db-primary` on data-1 and
   `db-mirror` on data-2 (mirror on a *different* host = real redundancy) and
   cross-host deps (`lb→web`, `api→db-primary`). Validates. "multi-host" button.
2. **Host on the node** — 2nd line is now `mechanism · host` (e.g. `container · app-1`).
3. **Cross-host edge marking** — a dependency whose endpoints are on different
   hosts is drawn **amber + heavier** (the fragile network boundary, §14.6). The
   cheap, high-value, layout-neutral placement win.
4. **Layout pivot toggle** (`↹ group: deps | host`) — re-clusters the *same*
   nodes into one column per host. `buildHostNodes` re-positions `buildNodes`'
   output, so **depth/host/reach are retained** across the pivot (the §4.8
   retained-channel idea — a node keeps its boot-depth fill colour in host view).
   Static switch (instant) for now.

## To visually check when back

- multi-host: `lb→web` and `api→db-primary` should be **amber** (cross-host);
  `web→api` grey (same host, app-1). Hosts shown on each node's 2nd line.
- **↹ group** flips to host columns (edge-1 / app-1 / data-1 / data-2); the
  "depended on by" axis disappears; node fills keep their depth colour.
- hover still brushes (deps + routes highlight, rest dims) in both layouts.
- the SVG should be natural-sized, not magnified.

## Done on this branch (cont.) — the animated pivot (2026-06-16)

5. **Swimlane bands + host headers** — host mode draws a faint per-host tinted
   band (blue/green/amber/violet/teal/rose, `hostStyle`/`hostPalette`) behind
   each column with the host name as a header. Bboxes are read off the live node
   positions, so the bands form up as the columns assemble. Fade in via a CSS
   `@keyframes laneIn` (a transition won't fire on element creation).
6. **The pivot is real interpolation, NOT CSS** (Andrew's steer: we have the
   interpolation engine, use it). Adopted `hylograph-transitions` (0.1.0, in
   package set 77.5.0). `Chair.Graph.layoutPositions :: Boolean -> AnalyzeResult
   -> Map String Point` gives a layout's coordinates; `Main` builds a per-node
   `TransitionState Point` with `transitionWith lerpPoint` (CubicInOut, 520ms),
   ticks them in a forked frame loop (`Engine.tick`, ~16ms), and writes the
   interpolated points to `livePos`. The graph renders from `livePos` each frame,
   so **edges follow the nodes** (read via `posOf`) — the fade hack is gone.
   `animGen` supersedes a stale loop on re-toggle. Confirmed "perfect" by Andrew.
   - *Substrate note:* positions now live in a model a tick loop mutates, which
     is exactly what experiments 2–4 need. When the ForceEngine enters at #3,
     unify onto the library `Transition.Coordinator` (its `Consumers` already
     adapt BOTH transitions and force `Simulation` to one tick loop). The Aff-
     delay frame loop is the interim driver; swap to `Transition.RAF`/Coordinator
     when the sim arrives.
   - *Later refinement (parked):* curved/path-redraw edges — Hylograph can redraw
     an edge path per tick (e.g. growing a tree from a root); straight lines
     already track fine, so this is polish, not blocker.

## Next experiments (designed; need your eyes)

1. ~~**Animate the pivot**~~ — DONE (item 6 above), via the interpolation engine
   rather than CSS, so edges follow for free.
2. **Common-fate gather** (§14.4). On hover, give same-host nodes a brief
   synchronised nudge-together-and-settle. Build on the existing brush + the
   transform-translate from (1). A half-second of shared motion = "these share a
   machine," no permanent space spent.
3. **Ghost extraction** (§14.3, the keystone). Home substrate = bubble-pack by
   host (`DataViz.Layout.Hierarchy.Pack`); pull a chosen cross-cutting set (a
   failover group, a mux pool) out with force (`Hylograph.ForceEngine` — follow
   the sim rules in CodeExplorer/CLAUDE.md: one sim/view, stable HATS tree,
   store+call unsubscribe); leave **ghosts** in home cells + faint tethers. The
   ghost positions answer the SPOF question (mirrors' ghosts in different
   host-bubbles = good; same bubble = SPOF). Biggest piece — needs the real
   force engine, not CSS.
4. **Failover-as-behaviour** (§14.5). "Click to ask what breaks" — kill a node,
   watch roles flip / traffic re-route / blast spread. Drive it for real from
   the chaos suite (STRESS-TEST-PLAN §2), not a faked animation.

## Notes

- The static pivot deliberately avoids the force engine (couldn't visually verify
  a sim blind). (1)–(3) are where force/animation actually enter; do them with a
  browser open.
- `buildHostNodes` is intentionally a *re-position* of `buildNodes` (not a
  separate layout) so every other channel (fill, badge, marks) just works in
  both modes — and so the animated pivot in (1) is purely a position tween.

## Live dashboard + small-multiples rack (2026-06-17)

- **Live overlay** (CONTROL-SURFACE.md steps 1–2): the graph reads serve /state
  (the Cockpit poll) as a `NodeLive` channel — status dots (up/down/redirect),
  pulsing down-halo, and blast-from-down (a down node auto-washes its dependents
  amber). Correlation = `reconcile.aliases` → `project:role` (the /state key).
  Demo fixture `fixtures/topologies/live/` + the **◉ live demo** button.
- **Channel rack** (Andrew's small-multiples idea): every mark is now its own
  `Channel` (source/depth/exposure/placement/dependency/traffic/SPOF/live). The
  main view composites the enabled `Set Channel`; a rack of dot/edge thumbnails —
  same viewBox, scaled small — shows each channel ALONE and toggles it. Replaces
  the symbolic legend (a thumbnail shows the real data, not a glyph). Default =
  all on (clutter is a fine resting state — never force a view-flip for hygiene);
  all-off = bare neutral cards. `⚠ SPOF` button retired into the rack.
- Same principle as the pivot: each channel is an orthogonal layer, so the rack
  is just "render layer N alone" — the small multiple is the main view minus the
  other layers. No per-channel special-casing.
