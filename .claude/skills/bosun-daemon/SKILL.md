---
name: bosun-daemon
description: How to write a long-running daemon/service that plugs cleanly into Bosun supervision — port-from-env, prebuilt launch, readiness-vs-liveness, drain-on-signal, the agent contract. Load when authoring OR revising any daemon that Bosun will (or might) supervise — and when designing a new one so it's born Bosun-native instead of retrofitted.
---

# Writing a Bosun-supervisable daemon

Bosun launches long-running processes, keeps them alive, restarts what crashes,
and surfaces their state on a live dashboard (Bosun's Chair). The first-generation
rig daemons — **deepstar, sdi, fh2-config, link-spike, es9-daemon** — were each
written with no shared architecture and no Bosun to plug into, so each needed
retrofitting (false-green status, build-at-launch flapping, dropped launch env,
no clean dismount). Write the next one to these eight rules and it plugs in for
free. Each rule cites the lesson that earned it.

## The rules

1. **Port/address from an env var or CLI flag — and embed it literally in the
   launch command.** Never hardcode. SDI and Bosun relocate ports by string-
   rewriting the registered command, so the literal port must appear in it.

2. **Be a prebuilt artifact, not build-at-launch.** Bosun *runs* artifacts; it
   does not build them. Ship a compiled binary, or a tiny toolchain-free runner
   (`node run-daemon.mjs`), and `build` beforehand. Never `spago run` / `cargo
   run` / `npm run build && …` at launch — that adds compile latency to every
   start and makes the toolchain a runtime dependency.
   *Lesson: fh2's `spago run --daemon` flapped under supervise; a prebuilt
   `run-daemon.mjs` that imports compiled `main` and calls it fixed it.*

3. **Launch env is typed data.** Anything the launch needs — `ERL_LIBS`,
   `BACKEND_PORT`, etc. — belongs in the compose `x-bosun.process.env: { K: v }`,
   not baked into a wrapper script or assumed from an interactive shell.
   *Lesson: `ERL_LIBS=_build/default/lib` lived in DeepStar's per-service env;
   the port to Bosun dropped it and the BEAM boot-crashed on a missing cowboy.app.*

4. **Readiness ≠ liveness, and you are the only authority on yours.** A live
   process is not a *serving* one. If you depend on hardware, a bound port, or a
   socket, **check it** — and exit (or report `failed`) when it's absent at
   startup AND when it disconnects at runtime. Never run hollow reporting green.
   *Lesson: es9-daemon name-matched a macOS aggregate device that persists when
   the ES-9 is unplugged, so it reported `running` with no hardware; fh2 exited
   if the FH-2 was missing at launch but never noticed a runtime unplug.*

5. **Clean shutdown releases exclusive resources.** On `SIGTERM`, drain before
   exiting: release the audio device / MIDI ports / sockets / locks, so a restart
   can re-acquire them. Exclusive resources held by a zombie or a second instance
   are the classic failure.
   *Lesson: black-start discipline — two BEAMs fighting :3012, or two es9-daemons
   on one audio device, produce baffling behaviour.*

6. **Bosun owns the lifecycle — you report, you don't self-manage.** No self-
   restart, no deciding to stay down. Bosun launches, signals, and restarts; you
   expose health and drain on signal. (The only reason to take control inward
   would be a mission-critical dismount that must *refuse* an interrupt — rare.)

7. **Link `bosun-agent` (per-language lib, Bosun-repo-owned) and supply two
   callbacks:** `readiness() -> Health` (your device/port check, rule 4) and
   `drain()` (your cleanup, rule 5). The lib owns the socket, the wire format, and
   the SIGTERM handler. Until the agent ships in your language, rules 4 + 5 alone
   give Bosun's process-probe honest binary up/down.

8. **Register in the compose.** `x-bosun.process { cwd (ABSOLUTE), command, env }`
   + the right `probe:` — `process` for UDP/socket/no-network daemons, `tcp`/`http`
   for networked, `health` once your agent is wired — + `depends_on` (boot order)
   + `expose` (reachability).

## Reference

The full agent wire protocol, the pgid×health status-mapping table, and the
per-language build plan live in `docs/AGENT-CONTRACT.md` in the Bosun repo.
`docs/SDI-COMPATIBILITY.md` is the sibling checklist for the lazy-spawn router.
