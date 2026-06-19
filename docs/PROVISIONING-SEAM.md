# Bosun ⇄ Quartermaster — the run/provision seam

**Status:** DIRECTION (2026-06-19, AC). Clarifies the responsibility boundary between
**Bosun** (runs/observes/controls what's aboard) and a companion provisioning project,
**Quartermaster** (stocks the ship). Sibling to `MARGINALIA-SEAM.md` (intent vs ops);
this is ops vs provisioning. "Build is a separate lifecycle phase from run"
(`ARTIFACTS.md`) generalises to "build is a separate *project*."

## The split

| | **Quartermaster** (provision) | **Bosun** (run/observe/control) |
|---|---|---|
| job | get the host into a state where services CAN run | run/observe/control services that ARE runnable |
| owns | toolchain install · **build + ship** artifacts (build-once-ship) · artifact distribution (registry/rsync) · host config (PATH, env, codesign/TCC, `ERL_LIBS`, venvs, container-runtime install, funnel/edge infra) · the **host-capability / pre-flight** check | `/state`+`/control` · supervise/keep-alive · executors (process/docker/launchd/beam) · the Chair · reconcile/check |
| assumes | nothing — it does the setup | provisioning is done; reads a "host ready" signal |

## The seam (the contract surface)

**An artifact reference + a host-readiness signal.** `ARTIFACTS.md` IS this boundary:
Quartermaster produces (a built artifact at a known ref; a host provisioned + verified
ready), Bosun consumes (runs whatever the ref points to; observes it). Bosun never
invokes the build toolchain; the `# MANUAL: build-once-ship` advisory it emits today is
Bosun pointing *across* this seam at a Quartermaster gap.

## What to pull OUT of Bosun (already-present provisioning)

- the **build/ship half** of `apply` — the `SourceBuild` advisory, the registry
  pull/push, build-once-ship orchestration
- the **host-capability / pre-flight** (MENAGERIE Tier 3 → `quartermaster verify`)

## Genuinely SHARED (leave shared, or Quartermaster owns + Bosun reads)

- the **artifact model** (`StaticDir|Binary|BundleRuntime|SourceBuild|Image`) — the
  vocabulary both speak
- **`targets.json` / host identity** — "where + how to reach"; both need it

## Why keep Bosun tight

Bosun is becoming load-bearing (it replaced DeepStar + SDI, supervises the rig). The
thing that supervises your infrastructure should have a *narrow* responsibility; the
messy host/build/toolchain provisioning belongs next door. Same Unix-way ethos as the
rest of the ecosystem.

## Related
- `ARTIFACTS.md` — the artifact axis = the seam's contract surface.
- `MENAGERIE.md` — Tier 3 is Quartermaster's, referenced there for this seam.
- `EXECUTORS.md` · `MARGINALIA-SEAM.md`.
