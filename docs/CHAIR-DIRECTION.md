# Bosun's Chair — the direction (post small-multiples, 2026-06-17)

Andrew, on seeing the live overlay + small-multiples channel rack land:
*"this is THE direction that will enable everything I want to do."*

The rack made a latent principle explicit: **every relationship and every action
wants its own visible surface — not a hidden gesture, a modal, or a buried form.**
That is the Bosun/Hylograph thesis (direct manipulation of the elements of a
complex system) applied to operating infrastructure, and it's the through-line
for everything below. The AWS-console failure mode — multi-dimensional structure
navigated through nested forms and tabs — is exactly what we're refusing.

## The principle

Replace hidden/modal/modifier interactions with **visible, direct, spatial
affordances.** Each orthogonal channel is already its own layer (that's what made
the rack a free "render layer N alone"); push the same orthogonality onto
*actions* and *navigation*, not just *display*.

## Ideas arising (Andrew, this session) — not yet built

1. **Dock the rack to an edge; give the main view the whole canvas.** The
   small-multiples strip lives along the top / bottom / side as a fixed rail,
   maximising real estate for the primary surface. The minis are always-present
   context, never a view you flip *to*.

2. **Control affordances as full-fill node buttons (the "control minimap").** A
   node's runtime state becomes its own button, by direct fill:
   - stopped node → entire rect filled green = press to **launch**;
   - running node → rect split (e.g. half red / half blue) = **stop** | **reboot**;
   - large, unmissable, no menu. The control surface IS the node, not a modal over
     it. (The earlier "modal control mode with a timeout + loud banner" decision
     may be subsumed by this — if the affordance is this explicit and only the
     *control* minimap is armed, the "don't kill while exploring" risk drops. To
     re-examine when we build it; CONTROL-SURFACE.md step 3.)

3. **Navigation as a minimap, not a modifier-click.** Going to a service's
   Marginalia project page is its own visible mini-affordance, not a hidden
   ⌘/alt-click on the node.

4. **Deprecate modifier clicks generally.** Every hidden gesture should become a
   visible surface (a mini, a fill button, a dedicated region). Discoverability by
   construction.

## Scaling thesis (to validate)

Open question whether this reaches enterprise scale — but the bet is yes, *if the
main view is zoomable and draggable*. Pan/zoom + the always-docked rack + direct
on-node affordances should hold up for quite large setups. The pack/host/deps
layouts already give structure; zoom/pan gives navigation; the rack gives the
legend/filters without stealing canvas. Test against a deliberately large fixture
once pan/zoom lands.

## Sequencing (suggested, not fixed)

- **Cheap, high-leverage first:** dock the rack to an edge (1) — pure layout, no
  new model. Then pan/zoom on the main SVG (scaling thesis) — also mostly
  view-plumbing, unlocks the large-fixture test.
- **Then the control minimap (2)** — needs the armed/safe-mode story worked out
  against the full-fill affordance, but it's the headline of "Chair as control
  surface" (CONTROL-SURFACE.md step 3).
- **Then navigation minis (3) + modifier-click deprecation (4)** — once the
  pattern of "affordance = a small visible surface" is established by (1)–(2).

## Parking lot (2026-06-18, surfaced while testing the live Atlantis rig)

- **The picker page as an all-projects dashboard.** Put the small runtime
  minimap (the one in the top-right overlay) on each card in the project selector,
  so the landing page becomes a live status board for *every* monitored project at
  once — and let you **attach** to several supervisors simultaneously (watch all,
  drill into one for the detailed graph). This is the deferred multi-supervisor
  "top-level Minard altitude" view, now with a concrete home: the picker.
- **A stats page with sparklines that persist through restart events.** The
  supervise restart counters reset on a deliberate group down/up (clean slate),
  so `↻N` is per-up-session, not lifetime. A separate stats surface that records
  transitions durably (sparkline the *counter*, not the sampled status — a same-
  tick relaunch is invisible to status sampling but shows as a counter blip) would
  give real flap history. Hylograph already has the machinery. Not for today.

Related: `CONTROL-SURFACE.md` (the two-session split + control modal),
`BEAM-OBSERVER.md` (same Chair over an OTP observer — these affordances apply
verbatim to restarting a purerl-tidal voice), `AGENT-CONTRACT.md` +
`.claude/skills/bosun-daemon` (writing daemons that plug into all this cleanly).
