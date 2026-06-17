# Bosun — productionization roadmap

Status: **PLAN** (2026-06-17, Andrew + engine session). The forward plan from
"MVP proven" to "the tool we actually run." Continues `BUILD-PLAN.md` (the
phase-history log); realises the vision in `BEAM-OBSERVER.md`; meets the Chair
at `CONTROL-SURFACE.md`.

## What Bosun is, as a spec

- **Multi-runtime.** One pure PureScript core, compiled three ways: **Node**
  (reference), **Go** via Gnomon/`backend-go` (proven byte-identical through
  Detect → Plan → Apply), **Erlang** via purerl (the third column, Stage 3).
- **The flagship Gnomon showcase.** "A PureScript program compiled to Go
  deploys a real, public website." Not a toy corpus — a tool doing devops.
- **A real tool, on real systems.** Deploys **Polyglot Showcase** (Stage 1) and
  supervises **Atlantis**, the live-coding rig (Stages 2–3); more later.

The tri-runtime story is **not a separate stage** — it is a property each stage
exhibits:

| Stage | Runtime milestone |
|---|---|
| 1 | the **Go** binary (Gnomon) performs the live MacMini deploy |
| 2 | (Node/Go maintained; supervise mode is pure, rides both columns) |
| 3 | the **Erlang** column lands — `bosun-core` on purerl + native BEAM introspection |

## Stage 1 — deploy Polyglot Showcase, public over TailScale Funnel

**Goal.** `bosun apply` the Polyglot Showcase stack onto the MacMini and serve
it over a TailScale Funnel URL shareable with anyone — the Go (Gnomon) binary
doing the deploying.

**Already proven (BUILD-PLAN Phases 5–6C):** pure `plan`; pure `applyScript ::
ValidatedDeployment -> Plan -> Array StagedCommand` (Process → `cd && cmd`,
Container → `docker compose`, macmini → `ssh`-wrapped), conformance-gated so the
Go binary emits the identical script; `bosun apply --dry-run`; live `apply`
fires via `os-exec`; a Go binary already deployed a running rig to **HTTP 200**.
The apply path *already ssh-wraps macmini commands.*

**Deltas to build:**
1. **Co-design the Polyglot deployment in Bosun's vocabulary** (Marginalia
   #134): the showcase `Deployment` — site httpd + the PS-backend demos (the
   two python backends, the julia backend, …) — as `Service`s with executors,
   reachability, deps/boot-order. Start small: httpd + a couple of backends.
2. **MacMini live-fire** (Marginalia #16): run the proven `apply` against the
   real mini (`ssh andrew@andrews-mac-mini` + `docker compose up -d`), with
   Andrew present, dry-run first. This is the one genuinely new act — every
   prior live deploy was local (`fixtures/hello`).
3. **TailScale Funnel front.** Model the public endpoint as a `Published Domain`
   in the `Address` type (the ADDRESS-TYPE work added exactly this), and run the
   `tailscale funnel`/`serve` enablement as a staged command of `apply`.

**Does NOT need:** the resident `supervise` mode. A one-shot `apply` plus the
mini's docker `restart: unless-stopped` keeps a public site up; keep Stage 1
lean. Idle-reap (`bosun serve`) is the wrong posture for an always-on public URL.

**Done when:** Andrew shares a Funnel URL and a stranger loads the showcase; the
deploy was performed by the Gnomon-compiled Go binary; `bosun observe` reports
the stack healthy on the mini.

## Stage 2 — Rust monitoring, then retire DeepStar

**Goal.** Bosun supervises Atlantis's OS-process tier (es9-daemon, link-spike,
purerl-tidal-as-a-node, calypso, the config daemons) well enough to replace
DeepStar's supervisor role.

**The mapping (already mostly built).** DeepStar's daemon set is a `Deployment`
of `Process` services; `up`=`apply`, `down`=Plan-Stop (D-E5), `restart`=stop+
spawn, `status`=`observe`, `logs`=serve's child-stdio redirect, `list`=the
report layer.

**Two deltas (the only real gaps):**
1. **A probe for the Rust daemons.** es9-daemon and link-spike speak
   **OSC/UDP**, but `effectiveProbe` is TCP-to-port. Add a UDP/OSC-ping and/or
   process-existence probe variant to the `Probe` model.
2. **A resident `supervise` mode.** Keep-alive + restart-on-crash with backoff.
   It is `serve` minus the proxy plus a liveness watchdog; the **restart-policy
   + backoff is already in the IR**. The restart *decision* is a pure `Plan`;
   only the watch-loop is a foreign edge.

**Scope boundary.** Only DeepStar's *supervisor* role folds into Bosun.
DeepStar's calibration runner, pre-flight checks, and empirical pitch table are
music-domain logic and **stay a separate tool**.

**Done when:** the rig boots and stays up under `bosun supervise`; killing a
daemon triggers a Bosun restart; `bosun status` matches (then supersedes)
`deepstar status`; DeepStar's supervision is switched off.

## Stage 3 — see *into* the BEAM, and show it

**Goal.** Render purerl-tidal's live per-voice supervision tree inside the same
Chair surface — voices appearing/vanishing as you live-code, click-to-restart a
voice — so Atlantis is one typed, visual supervisor across Rust/Node/Go *and*
the BEAM internals.

**The view model already exists:** the Chair's containment (nested bands/
circles) is a supervision tree; the requirement gradient (part-of / ordered /
independent) is one_for_all / rest_for_one / one_for_one (see the OTP↔Bosun
table in `BEAM-OBSERVER.md`). What is missing is the **feed**, and there are two
flavors:

- **A1 — self-report (Bosun stays on Node).** purerl-tidal emits its
  supervision tree as JSON over its existing WS verb surface; Bosun ingests it
  as another observe source; the `purerl-tidal` node deepens from a leaf into a
  sub-supervisor of voices. Ships without the purerl backend. Requires a small
  change in the *purerl-tidal* repo.
- **A2 — native (Bosun on the BEAM).** `which_children`/`process_info` directly;
  control via `supervisor:restart_child` or purerl-tidal's verbs. Generic, no
  self-report — but needs the purerl column (below) + edge FFI.

**Recommendation:** ship **A1** for "show it working," with **A2** as the
elegant endgame (same view model, swapped feed adapter — the whole point of the
observe seam). Dynamic voices ⇒ prefer a **push** feed (a voice lights up on
start) over polling; reuse the `serveDiff` add/remove machinery.

**Done when:** a live-coding session shows voices appearing in the Chair in real
time and a click restarts one; the Erlang column is demonstrated.

## Parallel track — the purerl conformance column (start anytime)

Run the I/O-free harness (`Bosun.Conformance.Main`) on purerl, exactly as the
Go column does (`scripts/go-conformance.sh`). **Independent of Stages 1–2; blocks
nothing.** Cheap, high-information: it completes the tri-runtime showcase
(Node + Go + BEAM byte-identical) **and** decides Stage 3's flavor — if purerl
is close, A2 (native) is in reach; if not, A1 (self-report) is the path.
**Step 0:** does `bosun-core` compile under purerl, and what is the foreign gap?
(Set/Map/NEA/validation/Generic/Foldable/String — purerl's prelude/collections
coverage is more mature than backend-go's was, but scope it first, same as the
Go "module-specific foreign grind.")

## Sequencing & risk

```
Stage 1  ── integration of proven machinery + macmini live-fire     LOW risk, HIGH external payoff
Stage 2  ── one probe variant + one resident mode (mostly pure)     MED risk, real operational cutover
Stage 3  ── novel; depends on a purerl-tidal change (other repo)    HIGH uncertainty → last
   └─ purerl conformance column: parallel, anytime, informs Stage 3's flavor
```

Stages are value-and-risk ordered: ship the externally-visible win first, the
operational win next, the showpiece last. The conformance column floats
alongside.
