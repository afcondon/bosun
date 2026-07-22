# Bosun's Chair (standalone app) — DEPRECATED 2026-07-22

The Chair's operating surface — the cockpit, the supervise view, the graph, the
CHANNELS, and the armed control — is being **lifted into Brunel**
(`ShapedSteer/minard-for-nix`) as a Halogen component, per the assembly plan
(Brunel absorbs the Chair; this is Fold 3, the armed control, ported last and
verbatim). Brunel becomes the single operating surface, and — the reason for the
move — gains a **machine selector**: the same interface, targetable at any box in
the fleet (MBP, mac-mini, …), because the only per-machine variable is the host
(`localhost` → the selected machine's tailnet name; the Bosun ports are identical
on every box).

**Status: retained, not removed.** This standalone app still builds and runs
(`spago build -p bosun-chair`; frontend on `:3020`, `chair-server` on `:3022`).
It is kept functional for reference and rollback until Brunel's port has landed
and been exercised on a real performance — exactly as SDI was kept after Bosun
superseded it. Do not develop it further; new work goes into Brunel's ported
component.

## What the port entails (for whoever picks it up)

- **Registry deps to add to Brunel**: affjax, affjax-web, http-methods,
  halogen-svg-elems, hylograph-transitions, web-dom, argonaut-codecs,
  foreign-object, routing, routing-duplex.
- **Depend on `bosun-protocol`** (NOT vendor). The `/analyze` + `/state` wire
  contract was extracted out of `Bosun.View` into a thin `bosun-protocol` package
  (types + codecs, zero engine) on 2026-07-22, so there is nothing to copy —
  Brunel path-deps `bosun-protocol` like any consumer, and so does its own
  `topology.json` ingest (collapsing the coarse re-model it hand-rolls today). One
  contract, N consumers, no duplication. The Chair keeps its **direct `/analyze`
  fetch** (it needs the rich shape the CHANNELS render from).
- **Host-parameterize**: `serveBase`/`analyzeBase`/`controlBase` stop being
  `localhost` constants and derive from a component `Input = { host }`; add
  `receive` so Brunel's machine dropdown re-scopes it live. This *is* the
  machine-axis change — componentizing and machine-targeting are the same edit.
- **Wire** the component into a Brunel tab with the machine dropdown; keep the
  armed-control safety gate verbatim (it drives the live eurorack).
- **Cross-origin**: a browser on one box reaching another box's Bosun needs the
  target to bind tailnet-reachable + allow CORS, *or* Brunel's backend proxies to
  the selected machine's Bosun (preferred — no CORS, reuses the tailnet channel).
