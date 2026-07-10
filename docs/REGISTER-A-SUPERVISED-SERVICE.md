# Adding a service to a running `bosun supervise` group

**Status:** current procedure (written 2026-07-10, after adding **Amphora** —
the Atlantis artefact store, and the group's first *stateful* member — and
rediscovering that the two things a supervised service needs are *not* the same
two a `bosun serve` service needs).

This is the operational how-to for the **keep-alive supervisor** (`bosun
supervise`, one daemon per group, e.g. Atlantis on `:3994`). Its sibling
`REGISTER-A-SERVICE.md` covers the **lazy-spawn router** (`bosun serve`,
`registry/fleet.json`, `:3022`). They are different paths; don't cross them.

## The one thing to know

A `supervise` group's source of truth is its **`compose.yml`** — not
`fleet.json`. To add a member you **edit the compose and `POST
:<groupPort>/control/reload`**. The reload diffs the compose and starts *only*
what changed; the running siblings are untouched.

Do **not**:
- add a supervised service to `registry/fleet.json` / `POST :3022/...` — that is
  the `bosun serve` router's registry. Atlantis members are **not** in it, and
  the Chair does not read the rig from it (it reads the compose — see below).
- hand-run the daemon (`node run.js &`) as its "deployment" — that bypasses the
  supervisor. Building the artifact by hand is fine; *launching* it is Bosun's job.

A Marginalia `:3100` server row for the port is **optional** — it's just an
intent/collision reservation (host + port), the same role the pre-existing
`null`-startCommand rows play. It does not drive supervision or the Chair.

## Procedure

1. **Write the daemon to the `bosun-daemon` skill's 8 rules** — port-from-env,
   prebuilt artifact (no build-at-launch), typed launch env, readiness≠liveness,
   drain-on-signal. A service born to those rules plugs in for free.
2. **Build the artifact.** `spago build` / `cargo build --release` — once,
   beforehand. The compose launches a *prebuilt* thing (a binary, or a tiny
   `node run.js` runner that imports compiled output).
3. **Add the service to the group's `compose.yml`** under `services:`:
   ```yaml
   my-service:
     x-bosun:
       host: mbp                       # LocalExec; ssh-wrap if the group is remote
       # probe: process                # omit → default TCP-to-port on the exposed
       #                                 port (right for an HTTP/TCP server); use
       #                                 `process` for UDP/socket/no-network daemons
       process:
         cwd: /abs/path                # ABSOLUTE — no cwd inheritance
         command: MY_PORT=NNNN node run.js   # port LITERAL in the command (rule 1)
         env: { KEY: value }           # typed launch env (rule 3), if any
       expose:
         - host: NNNN                  # the reachable port (or `socket: /path`)
     # depends_on: [other-service]     # boot order, if any
   ```
4. **Reload the group** (no rig bounce):
   ```sh
   curl -s -X POST http://localhost:<groupPort>/control/reload
   # → {"ok":true,"message":"reload: 1 added, 0 changed, 0 removed, N unchanged"}
   curl -s http://localhost:<groupPort>/state | jq '.services'   # my-service: running
   ```
5. **First-run for a stateful service.** If it owns a DB/store, seed it *after*
   it starts (it must be listening first). The store persists on disk, so this is
   a one-time step; a later supervisor restart re-opens the same state.
6. **Reload the Chair page** — see the gotcha. This is the step that is easy to
   miss and reads as "the Chair is broken".

## The gotcha: the Chair caches the graph per selected project (same-key guard)

Bosun's Chair builds a group's node graph by POSTing the compose path to
`chair-server :3022/analyze` (`Chair/Main.purs` `runAnalyze`). Its 1.5 s
`pollLoop` polls `:<groupPort>/state` and refreshes the **status of nodes that
already exist**; it does **not** add nodes. And `runAnalyze` is **guarded**:
selecting a project only re-analyzes when the key *changes* —

```purescript
GraphR key -> when (map _.key cur /= Just key) (openProject key)  -- Main.purs
```

So after `control/reload` adds a member, it is **running** (`/state` green) yet
**absent from the Chair**, and the obvious refresh attempts fail in a confusing
way:

| Action | Re-analyzes? | Why |
|---|---|---|
| **Full page reload** | ✅ | `currentProject` starts empty, so the guard passes |
| Project-list → back into the **same** group | ❌ | the list view doesn't clear `currentProject`; key unchanged → guard skips |
| A **different** project → back to the group | ✅ | key genuinely changed both times → `openProject` → `runAnalyze` |

**Reliable fixes:** hard-reload the Chair page, **or** click into a *different*
project and back. Re-selecting the group you're already on does nothing.

> **Fixed 2026-07-10** (`Chair/Main.purs` `refresh`): the 1.5 s poll now compares
> the supervised **service keyset** against the previous poll's, and re-analyzes
> when it changes. So a member added (or removed) via `control/reload` now
> **self-appears in the Chair within ~1.5 s** — no manual navigation. It converges
> (after the re-analyze the keysets match) and never loops on a phantom key;
> `openProject` clears `superv` first, so there's no redundant analyze on load.
> The manual workarounds above still apply to an *older* Chair bundle.

## Worked example — Amphora, the first stateful Atlantis member (2026-07-10)

Amphora is a DuckDB-backed HTTP store (`music/live-coding/amphora`, `:3024`).
It was already `bosun-daemon`-shaped: `AMPHORA_PORT` from env, launched as the
prebuilt `node run.js` (imports compiled `output/Amphora.Main`), DuckDB path
cwd-relative. Steps taken:

1. `spago build` in `amphora/` (artifact ready).
2. Added to `fixtures/atlantis/compose.yml` as a stage-0, no-`depends_on`
   service: `cwd amphora`, `command: AMPHORA_PORT=3024 node run.js`, `expose
   host: 3024`, no `probe:` (default TCP-to-port readiness). Nothing depends on
   it — the browser fetches at runtime and falls back gracefully if it's down,
   so boot never blocks on it.
3. `POST :3994/control/reload` → `1 added, 8 unchanged` — the running rig (es9,
   purerl-tidal, superdirt, calypso, triggerfish-frontend, …) was **not**
   bounced.
4. Seeded the store once (`amphora/scripts/seed-balistes.mjs`).
5. Reloaded the Chair → the `amphora` node appeared, `running`.

Rule-5 note: Amphora's "drain" is simply that process exit releases the DuckDB
file lock, so a supervisor restart re-acquires cleanly (verified by
kill+restart). No explicit signal handler was needed for the file-lock case.

## See also

- `.claude/skills/bosun-daemon/SKILL.md` — how to *write* the daemon (the 8 rules).
- `REGISTER-A-SERVICE.md` — the sibling flow for `bosun serve` (`fleet.json`, `:3022`).
- `docs/CONTROL-SURFACE.md` — the full `/state` + `/control/*` seam (`reload`,
  `restart?service=`, `up`/`down`).
