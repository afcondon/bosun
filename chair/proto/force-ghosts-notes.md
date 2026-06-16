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

## Next experiments (designed; need your eyes)

1. **Animate the pivot** (object constancy, §6.1). Render each node as
   `SE.g [transform: translate(x,y)]` with children at *local* 0,0, and add a
   CSS `transition: transform 500ms` on `.node`. Keep node *order stable* across
   layouts (sort by id) so Halogen reuses the `<g>` and the browser tweens it.
   Edges don't tween via CSS — either recompute per tick, fade them out during
   the move, or accept a snap. This turns the static toggle into the real pivot.
   *Risk:* if Halogen recreates the `<g>` it jumps instead of tweening — keying
   by id fixes it. Cheapest dynamic win; do this first.
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
