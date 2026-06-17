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

**Progress — local apply proven (2026-06-17).** Delta #1 is done as a *local*
deploy: `bosun apply fixtures/polyglot-up` brings up the whole showcase on the
MBP on its canonical ports — website (:3040 → HTTP 200), the two python
explorers (:8081/:8082 → HTTP 200), and the julia atlas (:3210, a WebSocket
service → `listening on ws://0.0.0.0:3210`). `bosun observe` then reports all
four `running`. Two things surfaced and were fixed/recorded:
- **Bug fixed — env-prefix eaten by `nohup`.** The julia row's `startCommand`
  begins `ATLAS_PORT=3210 julia …`; `daemonize` wrapped it as `nohup
  ATLAS_PORT=3210 julia …`, and `nohup` tried to exec the literal string
  `ATLAS_PORT=3210`. Fix: `nohup env <cmd>` (`env` honours the leading `VAR=val`
  assignment; transparent passthrough otherwise). **Conformance-neutral** — the
  `ApplyMain` Go-column fixture's command ends in `&` (the already-backgrounds
  branch, untouched), and node/Go share the source. Regression test added
  (`ApplySpec`); 91 green.
- **Probe-fidelity caveat (feeds Stage 2 delta #1).** Before this deploy, SDI
  was port-squatting :3040/:3210 and `bosun observe`'s TCP-to-port probe read
  julia as `running` while HTTP/WS was dead (a *false* positive). The richer
  probe Stage 2 needs (UDP/OSC + process-existence) is the same gap.
- **SDI coexistence.** The MBP's SDI lazy-spawn router squats every registered
  dev port. To let Bosun genuinely own the deploy the canonical ports were freed
  (SDI `launchctl bootout` + kill the stale hand-started python), then `apply`'d;
  SDI was restored and now **skips** the four Bosun-held ports and serves the
  rest — the incremental SDI→Bosun cutover working in miniature (Andrew:
  "we are going to replace SDI with Bosun soon").

**The GO BINARY now does the file-driven deploy (2026-06-17, same session).** The
prior Go-column proof (`go-apply.sh`) deployed a *hardcoded* fixture; the full
`bosun apply <compose> <registry>` reading REAL files had only ever run on node.
Closed that: `Bosun.Conformance.ApplyCliMain` is the real `runApply` pipeline
(argv → read files → ingest → reconcile → validate → plan → applyScript → exec),
transpiled via backend-go and run as a native binary — it read the real
`registry.json` (+ compose) and **live-deployed all four polyglot services**
(3× HTTP 200 + julia WS). This drove the Json-decode foreigns the hardcoded
harnesses never exercised — `Data.Argonaut.Core` (`_caseJson` Fn7, `from*`,
`stringify`) and `Foreign.Object` (`_lookup`, `keys`, `toArrayWithKey`, …) — newly
hand-written in Go and kept in the Bosun repo (`conformance/go/*.go`, package
main, copied at build; upstream candidates for backend-go, same posture as the
os-exec shim). YAML support via `gopkg.in/yaml.v3` (a one-line go.mod;
`normalizeYaml` matches the JSON/js-yaml runtime shape). **A `--dry-run` diff of
the rich `fixtures/macmini` YAML compose is byte-identical node-vs-Go** — so the
whole ingest→decode→plan→script path is conformance-proven across columns, not
just the hardcoded Detect fixture. Reproduce: `scripts/go-apply-cli.sh`. The
known key-order caveat (Go map iteration vs JS insertion order) is documented in
`foreign_object_foreign.go`; it does not bite boot-ordered apply scripts.

Remaining for Stage 1: delta #2 (macmini live-fire) and delta #3 (Funnel front)
— the genuinely-new acts; everything local is now proven, **on both the node and
the Gnomon-Go columns, from real files.**

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

**The decision tier already exists.** `supervise` is the pure `plan` run on a
loop, not new logic: `baseChange` already maps `Failed → Restart`, `InBackoff →
NoOp` (backoff respected), `Down → Start`, and already propagates `Restart …
(DependencyRestarted xid)` to dependents (coupled co-restart). The policy IR is
`Service.restart :: RestartPolicy { base :: Never|OnFailure|Always|
UnlessStopped, backoff {minSec, maxRetries} }`. So only the *watch-loop* and the
*enactment edge* are new.

**Two deltas (the only real gaps):**
1. **A probe for the Rust daemons.** es9-daemon and link-spike speak
   **OSC/UDP**, but `effectiveProbe` is TCP-to-port. Add a UDP/OSC-ping and/or
   process-existence probe variant to the `Probe` model.
2. **A resident `supervise` mode** = observe → `plan` → enact, on a loop.
   Keep-alive + restart-on-crash with the IR's backoff. It is `serve` minus the
   proxy plus a liveness watchdog driven by the pure `Plan`.

**Contract commitments to the Chair** (HANDOFF-CHAIR.md round 2 — these gate the
live dashboard for Stage 2):
- **`supervise` exposes the SAME `/state` + `/control/*` HTTP surface as `serve`**
  (shared `controlRouter`/`stateBody`; differ only in lifecycle policy). The
  Chair lights up against it with zero change — the single biggest integration
  risk, closed by construction.
- **Additive `/state` fields** (the Chair's poll is 1.5 s, so restarts must be
  observable across poll misses): `supervised :: Boolean`, `restarts :: Int`,
  `lastTransitionAt :: Number`, `desired :: "up"|"down"`. All optional.
- **Manual STOP holds** (`desired=down` suspends auto-restart — "stop means
  stop"); base policy still governs crash response when `desired=up`.
- **Atomic `POST /control/restart?port=N`** on both `serve` and `supervise`, so
  the supervisor can't race the Chair's reboot and a transient `down` won't trip
  the co-restart group.
- **Coupled co-restart is enacted HERE, in Stage 2** (Node/Go), via the planner's
  existing `DependencyRestarted` propagation, as one staged batch so `/state`
  flips the whole `part-of` group down→up within one poll window. Stage 3/BEAM
  only makes the same semantics *native* OTP — the lockstep-reboot demo does
  **not** wait for the BEAM.

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

## Parking lot — OS-tool executors & launchd as a distinct lifecycle (not now)

Captured 2026-06-17 (Andrew), to fold in around the SDI-replacement / `supervise`
work (Stage 2), **not a change to the staged plan above.**

When Bosun subsumes SDI and supervises the OS-process tier, it should fold in the
native Unix/macOS tooling as observe/control surfaces — `ps`/`top` for liveness
and resource state, **`launchctl` for launchd-managed jobs** — and recognise that
a **launchd / "Login Items" launched process is a wholly different state (and
executor) than a plain `nohup`'d one.** It has its own lifecycle vocabulary
(`bootstrap`/`bootout`/`kickstart`/`enable`, KeepAlive policy, loaded-vs-unloaded,
domain `gui/<uid>`) that does **not** map onto `nohup …`/`kill <pid>` — so its
`Start`/`Stop`/`Restart`/observe edges must route through `launchctl`, and its
status is richer than up/down (loaded-but-stopped, KeepAlive-throttled, etc.).

Concrete grounding from this session: SDI itself is a launchd KeepAlive agent
(`net.hylograph.sdi`); freeing its ports needed `launchctl bootout
gui/$(id -u)/…` and restoring it `launchctl bootstrap …` — a plain `kill` just
respawns. That's the exact asymmetry to model.

This is mostly *additions to existing seams*, not new architecture:
- **Executor** already has a `LaunchdJob` variant (and `Bosun.Apply` currently
  stubs it as `Manual ("launchctl load " <> label)`); promote it to real
  `launchctl bootstrap/bootout/kickstart` staged commands. Mirror for systemd
  (`systemctl`) on Linux hosts.
- **D-E11** already models launchd `KeepAlive` as `RestartPolicy` conditions —
  the policy IR is there; this is the *enactment + observation* half.
- **Stage 2 delta #1** already calls for a process-existence probe; `launchctl
  list <label>` / `ps`/`top` are its launchd/native implementations (alongside
  the UDP/OSC ping for the Rust daemons).

So: a launchd-aware executor + a `launchctl`/`ps`-backed observe probe, landing
with the resident `supervise` mode. Noted; continuing with the plan as written.
