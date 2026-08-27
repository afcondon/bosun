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

   *Survey done (2026-06-17, pre-compaction — the RESUME POINT):* the real
   container stack is `polyglot-deploy/docker-compose.yml` (profiles
   `core`/`minard`/`hypo`/…/`full`); the current non-Bosun deploy is
   `polyglot-deploy/deploy-remote.sh user@host profile`, which **rsyncs build
   artifacts to the mini, builds images there, then `docker compose --profile X
   up -d`**. Bosun's macmini `apply` models the **compose-up step** (ssh-wrapped),
   *not* the rsync+build prelude. Two framings: **(a)** Bosun orchestrates
   compose-up only, images pre-staged via `deploy-remote.sh --build-only`
   (smallest, **recommended first**); **(b)** Bosun models rsync+build as staged
   commands too (more faithful, more to model). **Recommended start:** model the
   `core` profile (edge + website) as a macmini *container* deployment, show a
   `bosun apply --dry-run` of the ssh+`docker compose up -d` script (zero outward
   effect), then live-fire with Andrew present. Note: `polyglot-deploy` still
   wires the *old* polyglot-pythia-showcases `ee/ge-server` python — updating to the current
   `purescript-python` exhibits is its own small co-design. Bonus: macmini
   services are containers, so `bosun down` = `docker compose stop` already works
   (apply↔down symmetry for this target, unlike the local-Process gap — task #8).

   *Progress — the dry-run is now RUNNABLE, on both columns (2026-06-17).* The
   macmini script used to be unrunnable (`ssh … 'docker compose up -d <svc>'`
   with no `cd`, no PATH, plus the union of all 9 profile tags as noise) and the
   ssh login was hardcoded in `Apply`, the tailnet address separately in `Serve`.
   Closed principledly: a typed `Bosun.Target` descriptor (`{ exec, address,
   workdir, envPrefix }`) that both facets resolve from, threaded through
   `applyScript`/`commandFor`; `defaultTargets` is the built-in layer (macmini =
   the real `deploy-remote.sh` recipe), and a `targets.json` (`--targets`,
   `Bosun.Adapters.Targets`) is the GitOps override on top. `fixtures/
   polyglot-core/` is the real core profile (edge + website). `bosun apply
   --dry-run` now emits, in boot order (website then edge):
   `ssh andrew@andrews-mac-mini 'cd /Users/andrew/psd3/polyglot-deploy && export
   PATH=/usr/local/bin:/opt/homebrew/bin:$PATH && docker compose up -d <svc>'`.
   **The Gnomon-Go `ApplyCliMain --dry-run` emits this BYTE-IDENTICAL to node on
   the core fixture** — so the binary that will do the live-fire is proven.
   94 tests green; go-conformance still byte-identical (35 Go files).

   ***LIVE-FIRE DONE — delta #2 COMPLETE (2026-06-17, with Andrew).*** A
   red→green on the real mini, the apply performed by the **Gnomon-Go binary**:
   the mini was found already running the full rig (26 containers, 4 days; `core`
   images + `~/psd3/polyglot-deploy/docker-compose.yml` already present, so no
   build needed). To get a true curl-testable red→green we stopped core by hand
   (`ssh … docker compose stop website edge` → `:80` HTTP 000, RED confirmed),
   then ran the native Go binary (`/tmp/bgo_apply_cli`, = `Bosun.Conformance.
   ApplyCliMain` transpiled via backend-go) on the MBP — it read the real files,
   planned, and **ssh'd to the mini to `docker compose up -d website` then
   `edge`** (both ✓), flipping `:80` back to HTTP 200 (GREEN). So a
   PureScript-compiled-to-Go binary performed a genuine *remote* deploy. The 24
   other containers were untouched. (Teardown stayed by-hand — `bosun down` is
   task #8, not built; the bring-up was Bosun.) **Stage-1 now needs only delta #3
   (TailScale Funnel front) for the full "a stranger loads it" finish.** Side
   note for later: nearly every container reports `unhealthy` (4 days) despite
   serving 200 — misconfigured healthchecks (wget/curl absent in minimal images),
   not dead services; a probe-fidelity item, cf Stage 2 delta #1.
3. **TailScale Funnel front.** Model the public endpoint as a `Published Domain`
   in the `Address` type (the ADDRESS-TYPE work added exactly this), and run the
   `tailscale funnel`/`serve` enablement as a staged command of `apply`.

   ***DONE — delta #3 COMPLETE → STAGE 1 COMPLETE (2026-06-17, with Andrew).***
   Funnel enabled on the mini (`tailscale funnel --bg 80` → public `:443`→local
   `:80`), and **a stranger on cellular (Andrew's phone, off-wifi/off-Tailscale,
   3G) loaded `https://andrews-mac-mini.vaquita-paradise.ts.net/`** — the "a
   stranger loads it" bar, met. (First public hit failed: TailScale Funnel
   provisions a Let's-Encrypt cert on first access — slow over 3G — then caches
   it; the retry loaded. NB MagicDNS resolves the `*.ts.net` name to the tailnet
   IP, so on-tailnet machines hit the edge *directly*, bypassing Funnel — the
   off-tailnet phone was the only true public test.) **Then MODELLED principledly
   so `apply` owns it:** a service with a `Published` address emits a second,
   post-launch staged command `tailscale funnel --bg <listening-port>` on its
   host (`Bosun.Apply.publishCommands`; `applyScript` `concatMap`s launch ++
   publish). macmini `Target` PATH gained the Tailscale.app CLI dir;
   `fixtures/polyglot-core` edge declares `x-bosun.expose [{host:80},{domain:
   …ts.net}]`. 95 tests; go-conformance byte-identical (35 Go files); the
   **Gnomon-Go `--dry-run` emits the funnel-bearing script byte-identical to
   node** — and the emitted line is exactly the hand-run that brought the
   endpoint up, so proven-correct by construction.

   **Known follow-up (separate task — Marginalia #134 co-design):** the deployed
   stack is the *old* full-rig compose (`~/psd3/polyglot-deploy/docker-compose.
   yml`, dated Feb 12), so the public page is the **old** polyglot front page.
   Getting the **new website + the Julia example + the current backends** into
   the config is the #134 co-design, expected and tracked separately.

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
hand-written in Go and kept in the Bosun repo at the time (a flat
`conformance/go/`, copied at build; upstream candidates for backend-go, same
posture as the os-exec shim — both postures are gone now: the library foreigns
moved upstream on 2026-08-24 and Bosun's own co-located beside their `.purs` on
2026-08-27). YAML support via `gopkg.in/yaml.v3` (a one-line go.mod;
`normalizeYaml` matches the JSON/js-yaml runtime shape). **A `--dry-run` diff of
the rich `fixtures/macmini` YAML compose is byte-identical node-vs-Go** — so the
whole ingest→decode→plan→script path is conformance-proven across columns, not
just the hardcoded Detect fixture. Reproduce: `scripts/go-apply-cli.sh`. The
known key-order caveat (Go map iteration vs JS insertion order) is documented in
`backend-go/foreign/Foreign.Object.go` (it lived in Bosun's `conformance/go/`
until 2026-08-24, when the registry-package FFI moved upstream where it
belongs); it does not bite boot-ordered apply scripts.

Remaining for Stage 1: delta #2 (macmini live-fire) and delta #3 (Funnel front)
— the genuinely-new acts; everything local is now proven, **on both the node and
the Gnomon-Go columns, from real files.**

**Does NOT need:** the resident `supervise` mode. A one-shot `apply` plus the
mini's docker `restart: unless-stopped` keeps a public site up; keep Stage 1
lean. Idle-reap (`bosun serve`) is the wrong posture for an always-on public URL.

**Done when:** Andrew shares a Funnel URL and a stranger loads the showcase; the
deploy was performed by the Gnomon-compiled Go binary; `bosun observe` reports
the stack healthy on the mini.

**✅ MET (2026-06-17).** A stranger (Andrew's phone, off-Tailscale, cellular)
loaded `https://andrews-mac-mini.vaquita-paradise.ts.net/`; core was brought up
by the Gnomon-Go binary over ssh; the edge serves HTTP 200. **STAGE 1 COMPLETE.**
Caveat for #134: the page is the *old* polyglot front (stale deployed compose) —
refreshing the content is the separate co-design task. Next up: Stage 2
(`supervise` + Rust monitoring) and/or the #134 content refresh; the purerl
conformance column floats alongside.

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

**`down` / teardown — per-executor stop verbs, NO unmanaged-process shim
(AC 2026-06-17).** Bosun's `Stop` enactment is principled *per executor* and
should stay that way:
- **Container** — `docker compose stop` (already implemented; works ssh-wrapped
  for macmini). The MacMini deploy is containers, so apply↔down symmetry already
  holds there.
- **launchd / systemd** — `launchctl bootout` / `systemctl stop` (the
  launchd-executor work above).
- **Unmanaged local `Process`** — currently `# MANUAL: stop process (no managed
  handle)`, and it must STAY honestly Manual until done properly. **Do NOT ship a
  stop-by-port (`lsof … | kill`) or pgrep-by-command heuristic** — it stops
  "whatever holds the port," not "what Bosun launched," and would be the kind of
  shim that hides the missing real feature. The two principled options: (a) the
  Stage-2 resident **supervisor holds the child handle** and kills its own PID
  (the natural home); or (b) a stateless `bosun down` reads launched PIDs from
  `WorldState.recorded` (the reserved D-7/D-8 slot) that `apply` writes. Tracked
  as a task; lands with Stage 2, not before.
