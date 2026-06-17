# The six Chair operations — gap analysis & build plan

Status: **ENGINE COMPLETE** (2026-06-17, Andrew + engine session). All three
foundational engine gaps (#8 stop, #9 supervise daemon, #10 process probe) are
built, live-proven, and pushed. What remains is **Chair-side wiring** + two
refinements (multi-group control, additive `/state` fields) — see "Remaining"
below. Andrew's target: drive these six operations *from the Chair app*, across
three deployment groups — **polyglot-MBP** (native processes),
**polyglot-MacMini** (containers), and **Atlantis** (the live-coding rig's
process tier, replacing DeepStar).

| # | Operation | Group | Engine status |
|---|---|---|---|
| 1 | **up** site + 2 python + 1 julia | MBP (Process) | ✅ `apply` / `supervise` (proven, 3×200 + julia WS) |
| 2 | **down** same | MBP (Process) | ✅ `bosun down` — group-isolated kill of the recorded PGID (#8b) |
| 3 | **up** docker stack | MacMini (Container) | ✅ proven live via the Gnomon-Go binary |
| 4 | **down** docker stack | MacMini (Container) | ✅ `bosun down` → ssh `docker compose stop`, reverse order |
| 5 | **up** Atlantis | MBP (Process daemons) | ✅ modelled + supervise-able; no-net daemons observed by process-probe (#10) |
| 6 | **restart** an Atlantis element | MBP | ✅ `supervise` `/control/restart?service=` (#9), process-probe keep-alive (#10) |

(live deploy of the *real* Atlantis still needs its daemons buildable — a rig
concern, not a Bosun gap.)

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

## The three engine gaps — ALL BUILT (tasks #8 / #9 / #10)

- **#8b — recorded-PID stop/restart (DONE).** `apply` records the launched
  process GROUP (wrapping the launch `( … ) &` so the exec edge spawns it
  detached → an *isolated* group); `down`/Restart do `kill -- -<pgid>`, precise
  and caller-safe. No port-kill heuristic. Live-proven.
- **#9 — resident `bosun supervise` daemon (DONE).** `observe → plan → enact` on
  a loop; `/state` + `/control/{up,down,restart}` on :3996 (same shape as
  `serve` → Chair lights up unchanged); `desiredUp` makes a manual down HOLD.
  Live-proven: kill → auto-restart; down holds; up restores.
- **#10 — process-existence probe (DONE).** `ProcessAlive` = `kill(-pgid,0)` on
  the recorded group — the honest signal for the UDP/socket Atlantis daemons a
  TCP probe mis-reads. `x-bosun.probe: process`. Live-proven: no-port daemon
  killed → restarted.

## The Chair contract (how the six map to engine calls) — the end-state

The Chair drives a **running, available** Bosun (NOT shell-out — a one-shot
can't hold handles, has no live state, and a stateless kill has the PID-reuse
hazard). The daemon is `bosun supervise`; the surface is HTTP today, with a
WS/SSE push channel as the Stage-2/3 upgrade for instant state.

- `GET  /state` — live status of every service (Chair already polls this shape).
- `POST /control/up` / `down` — flip the group's desired state (stop HOLDS).
- `POST /control/restart?service=<id>` — atomic single-element restart (task 6).

A **group = one validated deployment** (`polyglot-mbp`, `polyglot-macmini`,
`atlantis`). One `supervise` daemon per group (each on its own status port) is
the simplest model — the Chair polls three `/state`s and POSTs to the right one.

## Remaining (Chair-side + two engine refinements)

1. **Chair UI wiring** — the six buttons against `/state` + `/control`. The Chair
   session's work; the contract above is stable.
2. **Multi-group control — DONE.** `bosun supervise [--port N] <compose>
   <registry>` runs one supervisor per group, each on its own status port
   (default 3996). The Chair runs three (polyglot-mbp / polyglot-macmini /
   atlantis), polling + controlling each independently. Proven: two live at once
   on :3996 / :3995. (A single multi-deployment daemon with `/control?group=` is
   a possible future consolidation, not needed.)
3. **Additive `/state` fields** (ADR D-S1: `supervised`/`restarts`/
   `lastTransitionAt`/`desired`) so the Chair sees restarts across its 1.5 s
   poll. All optional — never break the existing decode.

## Known papercuts surfaced here (fix alongside the above)
- **ssh single-quote escaping**: an ssh-wrapped command containing single quotes
  (e.g. `erl … -eval 'F = …'`) breaks the outer `ssh host '…'` quoting. Bites
  only remote Process commands with quotes; Atlantis dodges it (host: mbp =
  local). Fix: escape inner quotes in the `Ssh` renderer.
- **`renderScript` header** says "APPLY SCRIPT" even for `down`; cosmetic.
- **default compose host** is hardcoded `macmini`; a single-host deployment
  repeats `x-bosun.host` per service. A compose-level default-host would tidy it.
