# Bosun executors — the supervision-substrate taxonomy

**Status:** DIRECTION (2026-06-18). Generalises the observe/control seam
(`CONTROL-SURFACE.md`, `BEAM-OBSERVER.md`) from "Process now, Docker/BEAM later"
into an open taxonomy: Docker, the BEAM/OTP, macOS `launchd`, Linux `systemd` are
all **peers** — each a supervisor that owns some units' lifecycle. Bosun's job is
to present all of them through *one* surface (the Chair). Surfaced doing the
MacMini survey, where the container group revealed it is a fundamentally different
lifecycle from the process group.

## The core distinction — who owns keep-alive

A service runs on a **substrate**, and Bosun stands in one of two relations to it:

1. **Bosun-as-supervisor** — Bosun launches the unit and runs the keep-alive loop
   itself (`Bosun.Supervisor`: observe → plan → restart). The substrate is bare OS
   **processes** (pgid). This is `bosun supervise`, proven on the rig + polyglot-MBP.

2. **Bosun-over-a-supervisor** — a *foreign* supervisor owns the unit's lifecycle
   and keep-alive; Bosun **observes** its state and **relays** control verbs to it,
   but does not run the loop. Docker (restart policies), the BEAM/OTP (supervision
   tree), `launchd` (`KeepAlive`), `systemd` (`Restart=`) are all this.

Most of Bosun's future reach is mode 2. The mistake to avoid is building each one
as a special case; they share an interface.

## The uniform interface (the seam)

Every executor implements two operations:

- **`observe() → /state`** — each unit's id + status (+ readiness where the
  substrate provides it). Same `/state` shape already shipped (services map +
  additive `supervision`/health fields).
- **`control(verb, target)`** — `up` / `down` / `restart`, mapped to the
  substrate's native verbs.

Behind the **same `/state` + `/control` HTTP contract** the Chair already speaks,
so **the Chair stays executor-agnostic** — it drives a Docker group, a launchd
agent, and a process exactly alike. That contract is the load-bearing invariant.

## The substrate table

| executor | observe | up / down / restart | keep-alive owner | readiness signal |
|---|---|---|---|---|
| **process** | pgid probe / `bosun-agent` | launch detached · `kill -pgid` · relaunch | **Bosun** (`supervise`) | `bosun-agent` health, or exit-on-unready |
| **docker** | ssh `docker compose ps` + health | ssh `docker compose up -d / stop / restart` | **Docker** (`restart:`) | docker `healthcheck` (native!) |
| **beam/otp** | OTP introspection (which children alive) | start/stop/restart child via RPC | **OTP** (supervisor strategy) | `process_info` / readiness msg |
| **launchd** | `launchctl print` | `kickstart` · `bootout` · `kickstart -k` | **launchd** (`KeepAlive`) | none native → wants a probe |
| **systemd** | `systemctl show` | `systemctl start / stop / restart` | **systemd** (`Restart=`) | `sd_notify` / a probe |

(`launchd` is not hypothetical — Marginalia's API/frontend/whisper already run as
LaunchAgents on the MacMini; today Bosun can't see them.)

## What this re-frames

- **The `↻` "will self-heal" glyph generalises.** It means "*this unit's substrate
  will restart it*" — Bosun's policy for process, `restart:` for docker, the OTP
  strategy for beam, `KeepAlive` for launchd, `Restart=` for systemd. The Chair
  reads one glyph; each executor supplies the fact. (Where keep-alive is
  substrate-owned, Bosun reports it; it doesn't run it.)
- **Readiness is per-substrate, and containers are *ahead*.** Docker healthchecks
  give honest readiness for free — the very thing the rig daemons lacked (es9
  false-green) and `bosun-agent` is being built to add for processes. launchd /
  systemd are liveness-only and will want a probe. So `AGENT-CONTRACT.md` is
  "readiness for the process executor"; docker has it natively.
- **Deploy/teardown vs keep-alive are different verbs.** For Docker the `up`/`down`
  the Chair issues are *deploy/teardown* (ssh `docker compose up -d`/`stop`, plus
  the `tailscale funnel` publish step) — Docker does the per-container keep-alive
  between them. For process, `up`/`down` flip a keep-alive the supervisor runs.
  Same verbs at the contract; different meaning under the hood. The Chair doesn't
  need to care; the executor does.

## The shape of the code

- **Pure core stays substrate-agnostic** — the planner, `ValidatedDeployment`, the
  `/state` model. ✓ already.
- **An `Executor` interface** = `observe` + `control` (+ a `readiness` capability
  flag). The seam. Each substrate is a small adapter behind it.
- **Adapters:** `process` (✓, with `bosun-agent` as its readiness arm) · `docker`
  (next) · `beam` (`BEAM-OBSERVER.md`) · `launchd` · `systemd`. Each adapter is
  thin; where one has decision logic, conformance-pin it (the node≡Go discipline).
- **A deployment may be heterogeneous.** The real polyglot deploy already spans
  substrates: docker (edge/website, macmini) + process (showcases, mbp) + launchd
  (marginalia, macmini). The resident observe/control mode takes a deployment whose
  **each service declares its executor**, and routes observe/control per-service to
  the right adapter. **One dashboard, many substrates** — that's the end-state.
- **The IR grows an explicit `executor` tag.** Today it's implicit (process via
  `x-bosun.process`, container via a compose service with a build/image). Make it
  an open, named axis so `launchd`/`systemd`/`beam` are first-class, not bolted on.

## Sequencing

1. **Docker-on-Node adapter** — the first mode-2 executor, behind the existing
   contract. Lights up the MacMini group in the Chair with zero Chair change.
   Proves the seam carries a foreign supervisor. (Engine handoff below.)
2. **Extract the `Executor` interface** from `{process, docker}` — once two real
   adapters exist, the shared shape is visible and safe to name.
3. **launchd** (Marginalia/whisper already run this way — immediate real value),
   then **beam** (purerl-tidal voices — `BEAM-OBSERVER.md`), then **systemd**
   (when a Linux host enters the picture).

## Related

- `CONTROL-SURFACE.md` — the observe/control seam this generalises.
- `BEAM-OBSERVER.md` — the beam executor, already sketched.
- `AGENT-CONTRACT.md` + `.claude/skills/bosun-daemon` — readiness for the *process*
  executor.
- `MARGINALIA-SEAM.md` — why all this ops surface is Bosun's, not Marginalia's.
- `CHAIR-DIRECTION.md` — the one dashboard over all of it.
