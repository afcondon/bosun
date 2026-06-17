# The six Chair operations — gap analysis & build plan

Status: **PLAN** (2026-06-17, Andrew + engine session). Andrew's target: drive
these six operations *from the Chair app*, across three deployment groups —
**polyglot-MBP** (native processes), **polyglot-MacMini** (containers), and
**Atlantis** (the live-coding rig's process tier, replacing DeepStar).

| # | Operation | Group | Engine status |
|---|---|---|---|
| 1 | **up** site + 2 python + 1 julia | MBP (Process) | ✅ `bosun apply fixtures/polyglot-up` (proven, 3×200 + julia WS) |
| 2 | **down** same | MBP (Process) | ⚠️ `bosun down` exists but Process stop is `# MANUAL` — needs task #8 |
| 3 | **up** docker stack | MacMini (Container) | ✅ proven live via the Gnomon-Go binary |
| 4 | **down** docker stack | MacMini (Container) | ✅ `bosun down` → ssh `docker compose stop`, reverse order |
| 5 | **up** Atlantis | MBP (Process daemons) | ◑ modelled (`fixtures/atlantis`) + dry-run correct; live needs daemons buildable |
| 6 | **restart** an Atlantis element | MBP | ⚠️ needs the resident `supervise` handle (task #8 / Stage 2) |

## What landed this session (the data + command substrate)

- **`bosun down [--dry-run] <compose> <registry>`** (`Bosun.Apply.downScript`):
  Stop every service in **reverse boot order**. Container → `docker compose
  stop` (ssh-wrapped for macmini) — so tasks **3 & 4** have full apply↔down
  symmetry. Process → honest `# MANUAL` note (NO port-kill shim — task #8).
- **`x-bosun.process: { cwd, command }`** in the compose adapter → a native
  **Process** executor (requires an absolute cwd; falls through to Unmanaged
  otherwise). This lets ONE compose overlay model a native-process deployment
  *with* `depends_on` boot-order — the general capability the SDI/dev-server and
  Atlantis worlds need.
- **`fixtures/atlantis/`** — the rig's process tier from DeepStar's SPEC:
  `es9-daemon` (57120) + `link-spike` (57122) + `fh2-daemon` (socket) →
  `purerl-tidal` (3012) → `calypso-server` (3060) → `calypso-frontend` (3061),
  all `x-bosun.host: mbp` (local). `bosun check` clean; up/down dry-runs show
  the correct 4-stage DAG and its reverse.

97 tests green; go-conformance byte-identical (35 Go files).

## The two remaining engine gaps (the real work for tasks 2, 5-live, 6)

### A. Principled Process stop/restart (task #8)
An unmanaged local Process has no handle to stop, and a port-kill heuristic is
forbidden (it stops "whoever holds the port," not "what Bosun launched"). Two
principled closes, NOT mutually exclusive:
- **(b) recorded-PID `down`** — `apply` records each launched PID (the `nohup …
  &` child / its pgid) to `WorldState.recorded`; `down`/`restart` read it and
  signal that pgid. Stateless, works for the one-shot CLI the Chair can shell to.
- **(a) supervisor-held handle** — the resident `supervise` mode keeps the child
  handle and kills its own PID. The natural home; required for crash-restart.

### B. The resident `supervise` daemon (ROADMAP Stage 2 delta #2)
`observe → plan → enact` on a loop, holding Process handles, exposing the SAME
`/state` + `/control/*` HTTP surface as `serve` (the HANDOFF-CHAIR round-2
contract — the Chair lights up with zero change). This is where **task 6**
(restart-an-element) and crash-restart live, and the cleanest home for the
Chair to drive **all six** without shelling out.

## The Chair contract (how the six map to engine calls)

Two viable integration shapes; (II) is the principled end-state.

**(I) Chair shells out to the CLI** — fastest to wire; covers 1–4 now:
- up:   `bosun apply  <group-compose> <group-registry> [--targets t.json]`
- down: `bosun down   <group-compose> <group-registry> [--targets t.json]`
- (restart of one element: not expressible via the one-shot CLI yet → needs II)

**(II) Chair drives a resident `supervise` daemon over HTTP** (Stage 2):
- `GET  /state` — the live status of every service (the Chair already polls this
  shape from `serve`; additive fields `supervised`/`restarts`/`desired` per
  ADR D-S1).
- `POST /control/up?group=<g>` / `down?group=<g>` — flip a group's desired state.
- `POST /control/restart?service=<id>` — atomic single-element restart (task 6).

A group = one validated deployment (`polyglot-mbp`, `polyglot-macmini`,
`atlantis`). The daemon holds desired state per group and reconciles via the
pure `plan`; the Chair's six buttons are three `up`s, two `down`s (well, the
Chair picks group+direction), and one `restart`.

## Recommended build order (next sessions)

1. **recorded-PID `down`/`restart`** (task #8b) → tasks **2** and a stateless **6**
   via the CLI, no daemon yet. Smallest unlock.
2. **UDP / process-existence probe** (Stage 2 delta #1) → honest observe of the
   Atlantis OSC daemons (es9/link) and any Process (today's TCP probe mis-reads
   them).
3. **resident `supervise` daemon** (Stage 2 delta #2) + `/control/{up,down,
   restart}` group endpoints → the principled home for all six, crash-restart,
   and the Chair's zero-change dashboard. Retires DeepStar's supervisor role.
4. **Chair wiring** — the six buttons against (II). Co-designed with the Chair
   session.

## Known papercuts surfaced here (fix alongside the above)
- **ssh single-quote escaping**: an ssh-wrapped command containing single quotes
  (e.g. `erl … -eval 'F = …'`) breaks the outer `ssh host '…'` quoting. Bites
  only remote Process commands with quotes; Atlantis dodges it (host: mbp =
  local). Fix: escape inner quotes in the `Ssh` renderer.
- **`renderScript` header** says "APPLY SCRIPT" even for `down`; cosmetic.
- **default compose host** is hardcoded `macmini`; a single-host deployment
  repeats `x-bosun.host` per service. A compose-level default-host would tidy it.
