# The Menagerie — a dual-runtime conformance rig for Bosun's control surface

**Status:** DIRECTION (2026-06-19, Chair→Engine). A spec for a purpose-built test
rig, born from the two-mode milestone (drive polyglot up/down/restart from the Chair
across docker + native). Owner: Engine (it lives in the backend repo + CI). Name is a
placeholder — a *menagerie* of tiny diverse creatures (processes), each a specimen
exercising one behaviour.

## Why this exists — the gap it fills

We have **byte-identical conformance** (node ≡ Gnomon emit the same command strings).
We do **not** have **behavioural conformance** (the two binaries, actually *run*,
produce the same real effects). The `down` no-op bug (2026-06-19) proved the gap is
load-bearing: the command strings were identical and correct-*looking*; the bug was
in what happened when they ran (recorded pgid ≠ live pgid → `kill -<stale>` → nothing
died). A byte-diff can never catch that. **The Menagerie is the run-it-for-real tier
between "same strings" and "same effects."**

It is also the vehicle for **dogfooding Gnomon in production** (see the runtime
discussion in the worklog): run the rig under the Node binary AND the Gnomon binary,
assert parity. Divergence = a Gnomon bug found by real usage, which is exactly the
validation Gnomon needs before public release. The dual-runtime property is the
safety net: anything Gnomon gets wrong, Node is the proven oracle to diff against.

## Design principle: tiny but real, diverse on purpose

- **Real, not mock.** Each process genuinely runs and does one small job (serves a
  counter, forks a worker, crashes on a timer, re-execs itself). Mocks wouldn't
  exercise the runtime paths we care about.
- **Diverse on purpose.** Each specimen is chosen to hit a *distinct* axis of the
  supervise/control surface. The rig is deliberately "stupidly complex" so one boot
  covers as much of the contract as possible.
- **Coherent whole.** They compose into a toy telemetry pipeline (clock → producers →
  aggregator → frontend, plus an edge), so the Chair view is a *meaningful* DAG and
  the dependencies/coupling are real, not contrived.
- **Stdlib-only, no hardware, no network peers, no ssh.** Unlike Atlantis (needs the
  ES-9/FH-2 plugged in) and polyglot-macmini (needs the mini + Funnel), the Menagerie
  runs entirely on a single CI box. That's the point: it tests the *control surface*,
  not a rig.

## The cast — each specimen is one axis

| specimen | what it really does | axis under test |
|---|---|---|
| **ticker** | binds a port, emits a monotonic tick every 100 ms | fast-bind baseline; readiness == liveness |
| **slowboot** | `sleep 8` then binds | **boot-grace** — reads `Starting` not `Down`; ONE launch, no relaunch storm |
| **flapper** | binds, then exits non-zero after a random 1–3 s | **backoff** — `suspendedUntil`, restart counter climbs but throttled; the `↻` self-heal |
| **wedged** | starts, stays alive, NEVER binds its port | boot-grace **expiry → Failed** (genuinely stuck → restart); readiness≠liveness |
| **forker** | spawns 2 child workers in its process group | **pgid reaping** — `down` must kill the whole tree (THE regression guard for the 06-19 bug) |
| **socketd** | binds a unix socket, no TCP port | socket-probe readiness; non-port liveness |
| **lazyready** | binds instantly; `/health` returns 503 for 5 s then 200 | **readiness ≠ liveness** (the es9 false-green lesson) |
| **selfbg** | double-forks / daemonizes itself | the `alreadyBackgrounds` path — Bosun must NOT re-daemonize, but must still reap the right group |
| **needsenv** | refuses to bind unless `MENAGERIE_KEY` is set | typed `env` injection on the process executor (the ERL_LIBS case) |
| **oneshot** | computes a value, prints it, exits 0 | `completed-ok` state — not Failed, not restarted under `Never`/`OnFailure` |
| **leader** + **follower-a** + **follower-b** | followers are `part-of` leader | **coupled co-restart** (one_for_all), boot order, blast-radius |
| **aggregator** | pulls from ticker + producers (`requires(healthy)`) | real dependency chain; health-gated start |
| **edge** | a tiny router fronting aggregator+frontend; declares `x-bosun.routes` | **topology requirement** — EDGE MISSING flags when absent, quiet when present |
| **frontend** | serves an HTML status page of the whole rig | gives the Chair (and a human) something real to look at |

~15 processes, every one justified. Restart policies spread across the cast
(`Always` for the pipeline, `Never` for oneshot, `OnFailure` for flapper) so the
policy field is exercised too.

## What CI asserts (per scenario, per runtime) — REAL effects, not strings

1. **bring-up:** all daemons reach `running` within budget; **slowboot** takes ~8 s
   with a SINGLE launch (boot-grace held); **oneshot** reaches `completed-ok`;
   **wedged** ends `Failed` after grace; **needsenv** fails without its env, binds
   with it.
2. **steady state:** **flapper**'s restart counter climbs but is *throttled*
   (backoff arms `suspendedUntil`); every service is a single process (no storm).
3. **down:** ALL ports free + ALL process trees reaped — **forker's children gone
   too** (the regression guard); **socketd**'s socket removed; `desired=down` held.
4. **restart:** restarting **leader** cycles both followers (coupling); a single
   service restart yields exactly one new pgid, no orphan.
5. **up again:** clean return to full green.
6. **topology:** drop **edge** → `bosun check` flags EDGE MISSING; restore → quiet.

## The dual-runtime matrix (the dogfood)

Run the whole scenario file **twice — `NODE_BIN` and `GNOMON_BIN`** — and assert:
- every behavioural assertion passes under both;
- `/state` snapshots at stable checkpoints are **equal across runtimes**, modulo
  timestamps/pids (reuse the existing differential oracle);
- any divergence is a Gnomon finding → the validation backlog before public release.

Builds on the existing `scripts/go-*.sh` plumbing (Gnomon transpile + `go build`),
which already gives ~80% of the Gnomon-side build.

## Three drivers, one fixture

- **CI** — `scripts/menagerie-conf.sh`: boots the rig under each binary, drives the
  resident HTTP surface (`/state`, `/control/{up,down,restart}` — the SAME contract
  the Chair speaks, so no browser needed), runs the assertions, diffs the two
  runtimes, exits non-zero on any failure or divergence.
- **CLI** — `bosun supervise --port N fixtures/menagerie/{compose,registry}` plus a
  `menagerie-drive` poking script, for manual exploration.
- **Chair** — register the Menagerie as a picker project (`compose.yml` +
  `registry.json`, like the study fixtures). The "stupidly complex" DAG is both a
  **visual sanity check** of the control surface AND the best demo of the Chair: a
  human arms it, hits ▼/▲, and watches 15 diverse specimens flip — flapper
  self-healing, slowboot lagging, the leader cycling its followers, forker's tree
  going down together.

## The container variant — separate, release-gating, runtime-AGNOSTIC

A parallel fixture running the SAME logical cast as **containers**, exercising the
SAME `/control` + `/state` endpoints. NOT in the always-run process CI — **gated to
environments with a container runtime**, run to gate releases.

Crucially, the container executor must **not hardcode `docker`**. Model a
`ContainerRuntime` capability (the `compose/up/down/ps/inspect` verbs) with swappable
adapters — this extends `EXECUTORS.md`'s substrate taxonomy: **"container" is a
family, not a vendor.**
- **docker** — today.
- **Apple `container`** — macOS 26 native containerization; anticipated.
- **podman / nerdctl / containerd** — Linux/CI variants.
- **a future Bosun-native container** — own the substrate someday.

Per-runtime conformance is the same shape as the dual-*language* matrix: same
observable behaviour across container runtimes. So the release gate eventually runs
the cast across {docker, apple-container, …} × {node, gnomon} — the full grid, all
behind one `/state`+`/control` contract the Chair never has to know about.

## Sequencing

1. **The cast + the process CI** (`menagerie-conf.sh`, node ≡ gnomon behavioural) —
   the core, always-runs tier. Regression-guards the pgid/reap class immediately.
2. **The Chair picker entry** — visual driver, ~free (it's just a fixture).
3. **The container variant + `ContainerRuntime` abstraction** — release gate; starts
   docker-only, designed for the multi-runtime grid.

## Tier 3 (planned) — the runtime-launch matrix / host pre-flight  →  belongs to QUARTERMASTER, not Bosun

**Ownership corrected (2026-06-19, AC):** this is the **provisioning test**, not a
Bosun test. "Can this host launch a Julia/Erlang/Rust workload?" verifies the host
was *provisioned* correctly — Quartermaster's acceptance test. Bosun only *consumes*
the resulting per-host/runtime "ready?" signal and gates on it; what I earlier called
`bosun preflight` is really `quartermaster verify`. Kept here only for the seam — see
`PROVISIONING-SEAM.md`. The rest of this section is the spec, to move with it.

A SEPARATE concern from the cast above. The Menagerie tests supervise *axes* with one
CI-portable runtime; this tests the *workload runtimes* we actually launch into, with
one trivial axis ("it launched and is observable"). The full axes×runtimes
cross-product is infinite; we run two thin lines through it, not the grid.

**Not CI — deploy-time / host pre-flight.** CI runners don't have Julia, GHC, Erlang,
the right Python, or codesigned Rust binaries. So this is a **host-capability check**:
"can THIS target launch each runtime this deployment declares?" — run at/before
deploy. It's the concrete form of the bare-metal-robustness guard (catches Julia
uninstalled / wrong Python on PATH / `ERL_LIBS` missing / Rust binary not
TCC-codesigned *before* a real deploy fails).

**Scope (what matters to us):** Node, Go, Python, Julia, Erlang/BEAM, Rust (+ Haskell
if/when a Haskell binary enters the rig). The polyglot backends collapse into this set
— PureScript→{JS,Go,Python,Julia} is Node/Go/Python/Julia launch, so this covers
Jurist/Pythia/Gnomon outputs too. Each test: a trivial-but-real workload per runtime
(bind a port / print / exit 0) launched through the REAL process executor, asserting
start + observability, and surfacing the known quirks: Julia ~35 s cold-start (the
boot-grace must tolerate it), Erlang `ERL_LIBS`/`cowboy.app`, Rust TCC/codesign,
Python interpreter/venv.

**Home:** a `bosun preflight` verb (rig-doctor-adjacent; the natural job for the
per-host `bosun-agent` in `EXECUTORS.md`) — given a deployment, verify each target can
launch each declared service's runtime. Makes "can I deploy this here?" a typed
pre-flight answer, the deploy-time analog of the Menagerie's CI-time conformance.

## Engine — review notes (2026-06-19, before implementing)

Strong yes on the rig and the dual-runtime dogfood. Read against the current code,
here's what's already load-bearing (don't rebuild it), the four gaps the cast
actually surfaces, the dual-runtime mechanics, and a sequencing tweak.

### Already supported — the cast is mostly expressible today
- **All the states exist.** `Bosun.Plan.Status` already has `Starting`, `InBackoff`,
  `CompletedOk`, `Failed`, `Down`, `Running`, `Unknown` — and `Bosun.Supervisor.refine`
  is the **pure** tick-transition that produces them (boot-grace → `Starting` then
  `Failed`; crash → backoff `suspendedUntil` → `InBackoff`; `restarts`/`since` for the
  `↻ N` badge). Time is a parameter, so it rides go-conformance like `plan`. **slowboot,
  wedged, flapper need no new supervisor code** — they're fixtures that exercise paths
  that already exist (and were under-tested: the whole point).
- **All restart policies exist.** `BaseRestart = Never | OnFailure | Always |
  UnlessStopped`. Cast covers Never/OnFailure/Always; consider one `UnlessStopped` too.
- **Probe kinds for lazyready and socketd already observe.** `observe` implements
  `HttpGet {expectStatus}` (so **lazyready**'s 503→200 is a real assertion, not new
  work) and `SocketReady AbsPath` (so **socketd** is observable today). `TcpConnect`
  too. No probe work needed for those.
- **PartOf co-restart is modelled.** `Edge.BindsTo`/`PartOf`, `Plan` ("PartOf dependents
  Restart" on crash-coupling), the Compose adapter parses `part-of`. **leader+followers**
  should work end-to-end — but this path has never been exercised live, so treat the
  triad as the *first real test* of coupling, and budget a fix if the blast-radius
  propagation has a bug (it's exactly the class of thing this rig exists to find).
- **edge/topology** just landed (`TopologyDrift`); the EDGE MISSING assertion is ready.

### The four gaps the cast surfaces (in priority order)
1. **`oneshot` → `CompletedOk` needs an exit-status channel — and we don't capture one.**
   `refine` keeps `CompletedOk` once seen, but nothing ever *enters* it: the observe edge
   returns `Down` for any not-listening process, and a TCP/HTTP probe cannot tell "exited
   0" from "exited 1" — both look `Down`, and `Down → Start`, so a oneshot under `Never`
   would be **relaunched forever** (a real bug this specimen would catch). Fix is small and
   principled: have `Substrate.daemonize` capture `$?` to a sibling exit-file
   (`…<id>.exit`) when the command is foreground-completing, and have `observeService`
   read it — present&0 → `CompletedOk`, present&≠0 → `Failed`, absent&group-alive →
   `Starting`/`Running`, absent&group-dead → `Down`. Pure string + one observe read; rides
   go-conformance. **This is a prerequisite for oneshot and should land first.**
2. **`selfbg` exposes a genuine design fork — the sharpest spec/impl tension.** Today a
   command ending in `&` is left **untracked**: `daemonize` records no pgid, so `down`
   *cannot* reap it. The spec wants "Bosun must NOT re-daemonize **but must still reap the
   right group**" — which the current opt-out design does not satisfy. This is really a
   second **identity-tracking strategy** for the process substrate (alongside
   "Bosun-backgrounds-and-records-pgid"): the *forking/`PIDFile=`* pattern — the daemon
   writes its own pidfile, Bosun reads THAT (systemd `Type=forking`, the classic
   double-fork daemon). Principled and a real deployment shape, so it belongs in
   `Bosun.Substrate` as a typed launch mode, not a hack. **Decision needed (AC/Chair):**
   does selfbg test (a) the new forking-pidfile tracking mode [my recommendation — it's a
   real capability and keeps the spec's assertion honest], or (b) the honest current
   contract "Bosun detects self-backgrounding and opts out; `down` leaves it"? The fixture
   differs by which we commit to.
3. **`flapper` timing must be deterministic for cross-runtime `/state` equality.** A random
   1–3 s crash makes a node-vs-Gnomon `/state` snapshot diff flaky. Seed it
   (`MENAGERIE_SEED` / fixed interval per specimen) so checkpoints reproduce. More
   generally: assert flapper *behaviourally* (restart counter monotonic, `suspendedUntil`
   armed, ≤1 process) and **exclude its volatile fields from the cross-runtime snapshot
   diff**, rather than trying to snapshot it mid-flap.
4. **`/state` cross-runtime equality needs a volatile-field canonicalizer.** The pure
   transition is already proven node≡Gnomon (`go-supervise-conf.sh`); the resident adds
   real pids/timestamps. Reuse the View-equality discipline but add a normalizer that
   strips/zeroes `pid`, absolute `since`/`suspendedUntil` (bucket to armed/not), and
   listen-ports, then assert structural equality at **quiescent** checkpoints (all-green;
   oneshot completed; wedged failed). Don't diff during transients.

### Dual-runtime mechanics — the path is already real
The "boot under GNOMON_BIN" claim is **feasible and partly proven**: `go-docker.sh`
already runs a **native Gnomon binary serving `/state` + `/control`** via the
`Bosun.CLI.Resident` Go foreign (`residentImpl` + `nowMs`), with byte-identical `/state`
and a control round-trip. `Bosun.CLI.Supervise` fills the *same* `Resident` record, so
`menagerie-conf.sh` drives the **supervise** resident through that **same** foreign — no
new Gnomon server work, just point the existing harness at the supervise mode. The pure
supervisor logic is already in the Go column (`go-supervise-conf.sh`). So the genuinely
new Go-side surface is small (the supervise resident's tick = observe+enact, where enact
is the os-exec foreign we already ship).

### CI hygiene (learned from the down-bug repro)
- **Dedicated, documented port block** clear of SDI/Marginalia/dev (propose **8790–8809**),
  collision-checked by `validate` B3 before boot.
- **Hard trap-cleanup by pgid on EXIT/ERR** in `menagerie-conf.sh` — dogfood `bosun down`
  for it. A behavioural-conformance rig that leaks orphans poisons its own next run (we
  just lived this); cleanup is a first-class requirement, not an afterthought.
- **Separate heavy CI target**, NOT `spago test`: slowboot 8 s + lazyready 5 s + flap
  window + up/down/restart × 2 runtimes ≈ 60–120 s. It's a conformance job, not a unit test.
- **Specimens in Python stdlib** (matches `fixtures/hello`, present on every box we run —
  no build step, no runtime dep), each a tiny script with behaviour knobs via env
  (`MENAGERIE_SEED`, interval, grace). The PureScript→{JS,Go} dogfood is cute but
  over-engineered for v1 — defer.

### Sequencing tweak — capability-first, MVP triad, then enrich
Don't write 15 fixtures then debug. Order:
0. **Land gap #1 (exit-status channel)** + resolve gap #2 (selfbg decision) — the only
   model/substrate changes; re-prove go-conformance after each.
1. **MVP triad: ticker + slowboot + forker** under `menagerie-conf.sh`, node≡Gnomon.
   This is the core loop + boot-grace + **the pgid-reap regression guard** (forker is the
   direct guard for the 06-19 bug) — the highest-value 20%.
2. Enrich: flapper, wedged, lazyready, socketd, needsenv, oneshot, leader/followers,
   aggregator, edge, frontend — each with its assertion, each re-proving dual-runtime.
3. Chair picker fixture (free), then the container variant + `ContainerRuntime` capability.

Net: the spec is well-supported; ~80% is fixtures over existing machinery. The real
engineering is gap #1 (small), gap #2 (a principled new tracking mode, pending your call),
and the `/state` canonicalizer. No objection to the boundary with Quartermaster.

## Related

- `EXECUTORS.md` — the substrate taxonomy the container family extends.
- `HANDOFF-ENGINE.md` — the down-fix that motivated the behavioural tier.
- `ARTIFACTS.md` / topology (`x-bosun.routes`) — exercised by edge + the artifact specimens.
