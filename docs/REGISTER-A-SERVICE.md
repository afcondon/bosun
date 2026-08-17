# Registering a service that `bosun serve` should serve

**Status:** current procedure (written 2026-07-05, after registering the
liquid-purescript docs site the *wrong* way and discovering the right one).
This is the operational how-to for the lazy-spawn router; the responsibility
model behind it is `MARGINALIA-SEAM.md`, the router itself is `BOSUN-SERVE.md`.

## The one thing to know

To add a service to the running `bosun serve` router, **POST one request to the
chair-server on `:3022`**. It assigns the id, denormalises the project
name/slug from Marginalia, atomically writes `registry/fleet.json`, asks the
router to re-admit the new route immediately — and **tells you whether that
worked**.

> **Read the `routing` field of the response, and the status code.** A
> registration has two halves and they can part company: fleet.json is durable,
> the routing half depends on a router that may be down or may refuse the row.
> **`200` = persisted AND routed. `202 Accepted` = persisted, NOT routed** — and
> `routing.note` says which of the three reasons it was. This is new as of
> 2026-08-17; before that a write whose reload silently failed returned a
> confident `200` and the service was invisible in the Chair for three days
> (see CONTROL-SURFACE.md, "serve drift + honest registration").

Do **not**, as a first resort:
- hand-edit `registry/fleet.json` (chair-server owns it),
- `POST` the server to Marginalia `:3100/api/projects/:id/servers` (that path is
  legacy — see the seam note below),
- `kill -HUP` the router by hand (the POST does the reload for you).

All three still *work*, but they bypass the owner and let the registries drift.
If you have already done one of them — or the router was down when you wrote —
**`bosun reload`** brings the router into line, and the Chair's Cockpit shows the
drift with a reload button until you do.

## Why `:3022` and not Marginalia `:3100`

Per `MARGINALIA-SEAM.md`: **Marginalia holds intent, Bosun holds operations.**
Servers, ports, `startCommand`s and hosts have moved out of Marginalia into
Bosun's registry (`registry/fleet.json`), which the **chair-server** owns and
exposes over an HTTP API shape-compatible with Marginalia's old `/api/ports`.

Marginalia is still in the loop for **project identity**: the chair-server POST
looks up the Marginalia project by id to denormalise `projectName` +
`projectSlug` into the row. So the project must exist in Marginalia (intent),
but its *server* row lives in Bosun (ops).

> **Gotcha that bites:** `GET :3100/api/ports/suggest` (Marginalia's DB) and
> `GET :3022/api/ports/suggest` (fleet.json, what the router actually reads) can
> return **different** ports — they did on 2026-07-05 (3023 vs 3000). Always use
> `:3022` for anything Bosun serves, or you may "reserve" a port the router
> considers taken (or free) when it isn't.

## The chair-server registry API (`:3022`, on the MBP)

```
GET    /api/ports                    every server row + live collisions
GET    /api/ports/suggest            next free port from 3000 (over fleet.json)
GET    /api/projects/:id/servers     servers for one project
POST   /api/projects/:id/servers     create a row — assigns id, writes fleet.json, reloads serve
                                     200 routed · 202 persisted-but-not-routed
DELETE /api/servers/:id              remove a row, writes fleet.json, reloads serve
                                     200 removed+unrouted · 202 removed, router not told
```

The `POST` body mirrors the old Marginalia server shape:

```json
{ "role": "frontend",
  "port": 3021,
  "url": "http://localhost:3021",
  "startCommand": "cd /abs/path && npx http-server . -p 3021 -c-1 --cors",
  "description": "...",
  "host": "mbp",
  "tailscaleName": "andrews-macbook-pro",
  "environment": "native" }
```

`id`, `projectId`, `projectName`, `projectSlug` are filled in by the server —
don't send them.

## Procedure

1. **Make sure the project exists in Marginalia** (identity). If not, create it
   there first (`/marginalia` skill) — you need its numeric id.
2. **Ask Bosun for a free port:** `curl -s :3022/api/ports/suggest`.
3. **Derive the `startCommand`** for the service kind. It **must** contain:
   - an absolute **`cd /abs/path &&`** anchor — without it the router spawns the
     process in *its own* cwd and serves the wrong directory;
   - the **literal port number** — `bosun serve` admission rejects a row whose
     `startCommand` doesn't contain its port (`PortNotInStartCommand`).
4. **Test the command** in a subshell and confirm the port serves, *then* kill
   it so the router can bind the port.
5. **Register it:**
   ```sh
   curl -s -X POST http://localhost:3022/api/projects/<id>/servers \
     -H 'Content-Type: application/json' \
     -d '{"role":"frontend","port":<port>,"url":"http://localhost:<port>",
          "startCommand":"cd /abs/path && <serve cmd with -p <port>>",
          "description":"...","host":"mbp",
          "tailscaleName":"andrews-macbook-pro","environment":"native"}'
   ```
   The response is the created row (with its assigned `id`) plus a **`routing`**
   object — the router's answer about THIS row:

   ```json
   "routing": { "persisted": true, "reloaded": true, "routed": true,
                "note": "routed — the router is bound to this port and will lazy-spawn it on first request.",
                "reload": { … the full /control/reload response … } }
   ```

   Three ways it can be `"routed": false` (all answered **202**, all persisted):

   | `note` says | what to do |
   |---|---|
   | `the reload failed: …` | the router wasn't reachable. Start it, or `bosun reload`. |
   | `it will NOT route this row: <reason>` | the row itself is unroutable — usually the literal port missing from `startCommand` (step 3). A reload cannot help; fix the row and re-register. |
   | `the row declares no port` | documentation-only row; nothing to bind. Expected. |

6. **Verify:**
   ```sh
   curl -s :3997/state | jq '.routes[] | select(.publicPort==<port>)'
   curl -s :3997/state | jq '{stale, drift}'     # must be {stale:false, drift:[]}
   curl -sI http://localhost:<port>/             # lazy-spawns the backend, expect 200
   ```

## Worked example — a static site (liquid-purescript docs, 2026-07-05)

A folder of hand-written HTML/CSS at
`/Users/afc/work/afc-work/cloudflare-sites/liquid-purescript`:

```sh
curl -s :3022/api/ports/suggest                                  # -> 3021
curl -s -X POST http://localhost:3022/api/projects/246/servers \
  -H 'Content-Type: application/json' \
  -d '{"role":"frontend","port":3021,"url":"http://localhost:3021",
       "startCommand":"cd /Users/afc/work/afc-work/cloudflare-sites/liquid-purescript && npx http-server . -p 3021 -c-1 --cors",
       "description":"Liquid PureScript docs site — static, Swiss style.",
       "host":"mbp","tailscaleName":"andrews-macbook-pro","environment":"native"}'
# -> row with id assigned; site live at http://localhost:3021
```

`npx http-server . -p <port> -c-1 --cors` is the standard static-serve command
(`-c-1` disables caching for dev; `python3 -m http.server <port> --bind 127.0.0.1`
is the zero-dependency alternative).

> **Not to be confused with `x-bosun.static`.** That is a *CDN publish*
> declaration (host `cloudflare`, `channel: cloudflare-pages-wrangler`) whose
> `apply` is a manual wrangler advisory — it describes a site deployed to
> Cloudflare Pages, **not** a directory served locally over HTTP. See
> `fixtures/static-cdn-widgets/` and `ARTIFACTS.md`. Local dev serving is a
> plain `fleet.json` frontend row as above.

## Committing the registry change (decision D-G1)

`registry/fleet.json` is git-tracked — its history is the audit trail. By
**decision D-G1** (`DECISIONS.md`), the write-owner commits: chair-server
git-adds and commits `fleet.json` right after each write, one commit per
registration, message `registry: <verb> <role> <slug> @<port>`, local, no push.

**Until that lands in chair-server, commit by hand with the same format:**

```sh
git add registry/fleet.json   # run from the bosun repo root
git commit -m "registry: add frontend juliet-whiskey-papa-juliet @3021"
```

Never leave a registry write uncommitted — an uncommitted `fleet.json` diff is
the exact drift D-G1 exists to prevent.

## Port & router facts worth keeping straight

- **Public port = identity** (the address you know the service by). The router
  binds it on `127.0.0.1` and lazy-spawns the backend on **public + 20000**
  (e.g. 3021 → 23021) on the first request.
- **`bosun serve` `/state` is on `:3997`.** (Older docs say `:3998` — that was
  *SDI's* port, the predecessor. Supervise uses `:3996`, docker `:3997`.)
- **Reload is `POST :3997/control/reload`** (equivalent to `SIGHUP`), which the
  chair-server calls for you — or **`bosun reload [--port N]`** from a terminal,
  which POSTs it, prints what got bound, and reads `/state` back to say whether
  the registry and the router now agree.
- **`GET :3997/state` carries `drift` + `stale`.** `drift` is the rows the router
  has no verdict on — *registered but never routed*, which is a different thing
  from `rejected` (*seen and unusable*). If `stale` is true, the router is behind
  the file: `bosun reload`. If a row is in `rejected`, a reload will not help —
  read the reason and fix the row.
- **`external: true` means the port is served by something serve did not start.**
  Benign — it steps aside rather than shadowing. Since 2026-08-17 it is also
  *recoverable*: the router re-probes the holder every 5s and takes the port back
  when it exits, so the route becomes lazy-spawnable again with no restart.
  `externalCheckedAt` says when the claim was last tested; `/control/spawn|stop`
  answer `409` while it stands (there is no backend of ours to act on).
- **`bound: false` with `external: false` means nothing is listening on that
  public port at all** — the router failed to bind it (`bindError`), so no
  request can arrive and lazy-spawn can never fire. Distinct from an idle route.
- **A rejection is not a routing failure to chase.** Ten-odd fleet rows exist for
  documentation / port-collision-avoidance only (null or prose `startCommand`)
  and land in `rejected` by design. They are accounted for, which is the point:
  visible, not silently dropped.

## Known rough edges (2026-07-05)

The seam is landed in mechanism but mid-enactment (MARGINALIA-SEAM.md step 3
— "update the `/marginalia`, `/what-next`, `deploy.md` skills" — is only
partially done, which this doc is part of):

- Some services still have **legacy server rows in Marginalia `:3100`** as well
  as in `fleet.json`; the two aren't synced. For anything Bosun serves, treat
  `:3022`/`fleet.json` as authoritative.
- **Quartermaster** (`ShapedSteer/quartermaster`) has no Marginalia project yet.
- Full findings + history: Marginalia **note on Bosun #227** (2026-07-04/05).
