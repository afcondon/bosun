# Handoff → Chair session (live-overlay + control-modal work)

From the engine session, 2026-06-16. Companion to `CONTROL-SURFACE.md`
(the two-session split) — this is the "your dependency is ready, go" note.

## Branch state (read first)

Everything is consolidated onto `main`. The shared working tree is now on
**`main` @ `ca1ca4a`** (clean) — work there, not on `force-ghosts`.
`force-ghosts` is stale at the old `53e68a1`; if you want it, `git branch -f
force-ghosts main` or just delete it. `origin/main` is pushed and current.

## Your dependency is unblocked — `bosun serve` runs against a safe fixture

```
node cli/run.js serve fixtures/serve/registry.json
#   binds 4 proxy + 2 redirect public ports; /state + /control on :3997
```

Every admitted backend is a harmless lazy-spawned `python3 -m http.server` —
spawning any of them **never touches the real rig**. The fixture is 4 admitted
mbp Processes (`gallery:frontend`, `gallery:api`, `atlas:frontend`,
`ledger:api`), 2 macmini redirects (`minard:frontend`, `archive:api` — your
second host swimlane), and 2 rejections. Ports `8190-8197`.

## The contract is verified live (build green, exercised end-to-end)

- `GET :3997/state` → `{routes[], redirects[], rejected[]}`, shape **exactly**
  `Chair.State.decodeStateView` (`RouteStatus = {serviceId, publicPort,
  internalPort, up, pid}`). All routes start `up:false, pid:null` until
  spawned — good for blast-from-down dev.
- `OPTIONS /control/*` → `204` + `access-control-allow-origin: *`, methods
  `GET,POST,OPTIONS`. **POST from `:3020` is allowed.**
- `POST :3997/control/spawn?port=N` → `up:true` + real `pid`;
  `/control/stop?port=N` → down; `/control/reload` → typed `serveDiff`.
  (`404` if no proxy route on that port.)
- macmini routes answer `421` + `location:` → tailnet URL (not proxied).

## Correlation rule for the overlay

`/state` keys by canonical `serviceId` (`projectSlug:role`); your graph nodes
key by `localName`. Map through `reconcile.aliases` from the `AnalyzeResult`
you already get from `/analyze`. Note `/state` is the *status* source only —
graph structure (deps for blast-radius, host for swimlanes) still comes from
`/analyze`, so to see correlated colour, your `/analyze` fixture's services
should share `serviceId`s with the serve fixture above (or extend the serve
fixture to mirror your graph — it's not golden-pinned, edit freely).

## Ownership

Engine session owns core/serve/CLI/fixtures; `chair/` is yours. Full runbook +
the verification table are in `docs/CONTROL-SURFACE.md` under "Engine session —
status". Ping via Andrew if you need a contract change or a richer fixture.
