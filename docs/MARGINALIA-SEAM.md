# The Bosun ⇄ Marginalia seam — operations vs intent

**Status:** DIRECTION (decided 2026-06-18, Andrew + Chair session, while wiring the
polyglot-MBP group and hitting a stale `-root` in a Bosun fixture). Records a
responsibility boundary between two existing systems; not yet enacted.

## The decision

A **clean division of responsibility**, not a read-through:

- **Marginalia = the cross-domain *intent* tracker.** What projects exist (across
  programming, music, house, garden, woodworking, infra), their status lifecycle,
  notes, tags, dependencies-as-*meaning*, "what should I work on." The human layer.
- **Bosun = the local *operations* substrate.** How a project is built, where it's
  served, whether it's up, and the controls to change that. The enactment layer.

Marginalia **sheds** its operations data — `servers`, ports, `startCommand`s,
hosts, runtime status. It does **not** keep showing them sourced live from Bosun
(the rejected option #1) — that would just relocate the muddle. If you want ops,
you go to Bosun's Chair; if you want intent, you go to Marginalia.

## Why (not taste — three structural reasons)

1. **Single source of truth kills a whole drift class.** The trigger was concrete:
   the polyglot website's built-site directory moved (`site/website/` → `site/polyglot/`)
   and the Bosun fixture's `-root` still pointed at the stale one — because the same
   ops facts (startCommand, port, host, root) live in *both* Marginalia and Bosun's
   registry. One copy, no drift.
2. **Model fit.** "Built and served in multiple places" — polyglot is already that
   (website/ vs polyglot/, MBP-native vs MacMini-container, dev vs Funnel) — is
   exactly what Bosun's `ValidatedDeployment` + targets/facets expresses and what
   Marginalia's flat one-row-per-server registry cannot. The ops data isn't merely
   duplicated in Marginalia; it has **outgrown** Marginalia's schema.
3. **Responsibility clarity.** Intent vs enactment. "What am I working on / who
   blocks whom / what next" stays Marginalia. "Is it up / start it / where's it
   served" becomes Bosun. The Chair is already becoming that ops pane.

## What this actually entails (it's a workflow move, not just hiding fields)

Registration moves **into** Bosun. Today you register a service *in Marginalia*
(the `/marginalia` skill, the `servers` rows). After this, you **declare** it in a
Bosun compose/registry — `x-bosun.process` + the `bosun-daemon` skill *are* the
registration. So the consolidation is:

- **DeepStar → `bosun supervise`** ✅ (done 2026-06-18; the rig runs under Bosun)
- **SDI → `bosun serve`** — SDI is a lazy-spawn router that reads *Marginalia's*
  registry; that registry-reader role becomes Bosun's. The pointer moves.
- **Marginalia sheds** servers/ports/startCommands/runtime; **keeps** project
  identity, status lifecycle, notes, dependencies-as-meaning, and the entire
  non-software half (house/garden/music) untouched.
- **The Chair becomes the operations dashboard** — the parked "picker page as an
  all-projects dashboard" (CHAIR-DIRECTION.md) is precisely this pane.

## The seam, end-state

A clean API boundary. Marginalia may **deep-link** to the Chair for a project's
ops view, but holds none of the data. A project's deployment description lives in
its Bosun compose/registry (authored per `bosun-daemon`); its tracking/intent
lives in Marginalia. Neither mirrors the other.

## Sequencing (load-bearing — do NOT reverse)

You cannot pull ops data out of Marginalia until Bosun owns the registry for
everything SDI currently serves. Order:

1. **Declare-in-Bosun** — move service deployment descriptions into per-project
   Bosun compose/registry.
2. **SDI → `bosun serve`** — Bosun becomes the lazy-spawn registry-reader.
3. **Then drop Marginalia's ops fields**, and update the `/marginalia`,
   `/what-next`, and `deploy.md` skills that currently source `startCommand`s.

Reverse this and you blind yourself mid-migration (Marginalia stops showing ops
before Bosun can).

## Related

- `AGENT-CONTRACT.md` + `.claude/skills/bosun-daemon` — how services declare
  themselves to Bosun (the new registration surface).
- `CHAIR-DIRECTION.md` — the picker-as-all-projects-dashboard (the ops pane).
- `ROADMAP.md` — the Stage 1/2/3 deploy + supervise arc this sits inside.
- Overarching vision (agent memory) — the Unix-style convergence toward a local
  computing appliance with clean responsibility boundaries; this is one such line.
