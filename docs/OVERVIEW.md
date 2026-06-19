# Bosun, the Chair, and Quartermaster — how the three fit together

A plain explanation of three tools that share one job — *get a set of services
running on some machines and keep them running* — split three ways. (Draft, kept
as the basis for a future README/webpage.)

## The split

There is one job, and each tool takes a different slice of it:

- **Quartermaster** gets a machine *ready* and gets the *artifacts* built.
  (provisioning — the occasional, fiddly, host-specific work)
- **Bosun** *runs* the services, watches them, and keeps them up.
  (operating — the continuous, load-bearing work)
- **The Chair** is the *window* a human looks through to see what's running and
  press buttons. (the control surface)

What ties them together is a **single description of the deployment** — a
`compose.yml` (the containerised view) plus a `registry.json` (the list of
services, ports, hosts, launch commands). All three tools read those same two
files. There is one source of truth for "what services exist, where they run,
how they start"; nobody keeps a private copy.

## What each one does

### Quartermaster — provision

Answers two questions *before* anything runs:

- **Can this machine actually launch these?** `quartermaster verify` looks at each
  service, works out what it needs (node, python, julia, a container engine, a
  built binary…), and checks the target host actually has it — plus that the
  working directories exist. You run it against a host before deploying, so you
  learn "julia isn't installed on the mini" now, not halfway through a failed
  deploy.
- **Build the things that need building.** `quartermaster build` takes anything
  defined as "build from this source directory" and builds it **once** into a
  pinned image pushed to a registry, so every host runs identical bytes instead
  of each rebuilding its own slightly-different copy.

### Bosun — operate

Takes over once the host is ready and the artifacts exist. One command-line tool,
a handful of verbs:

- `check` — does the description even make sense? (two services fighting over a
  port, a dependency cycle, two definitions of one service that disagree). Pure
  analysis; changes nothing.
- `observe` — what's actually running right now?
- `plan` — given what's running versus what you want, what would change?
- `apply` — make it so: start things in dependency order, locally or over ssh to
  another machine.
- `supervise` — the resident mode: stay running, watch the services, restart what
  crashes — sensibly (wait out a slow starter instead of relaunching it in a
  panic; back off on something crash-looping).
- `down` — stop everything, cleanly (kills the whole process tree, not just the
  parent).

Bosun never builds anything and never installs a toolchain. If it notices a
service that *should* have been built-and-shipped, it leaves a note saying "run
`quartermaster build`." That note is the boundary.

### The Chair — watch and control

A small web app. Bosun's resident modes (`supervise`, the docker manager, the
proxy) all expose the same small HTTP interface: a `/state` endpoint that reports
what's up / down / restarting, and a `/control` endpoint that takes "bring up /
take down / restart this." The Chair polls `/state` and draws it (green/red,
restart counts, which machine), and its buttons POST to `/control`. It looks the
same whether it's pointed at native processes on a laptop or Docker containers on
a server — the Chair doesn't know about ssh or docker; it just speaks that one
interface.

## Using them together

```
   describe          provision              run                 watch/control
  ┌─────────┐      ┌──────────────┐    ┌──────────────┐       ┌───────────┐
  │ compose │─────▶│ Quartermaster│───▶│    Bosun     │◀─────▶│ the Chair │
  │ registry│  │   │ verify       │ │  │ check→apply  │ /state│ (browser) │
  └─────────┘  │   │ build        │ │  │ →supervise   │/control└───────────┘
        same files──┘              └─ artifact + "host ready" ─┘
```

A first deployment, start to finish:

1. Write (or already have) the `compose` + `registry` describing the rig.
2. **Quartermaster verify** against each target host — fix anything it flags (a
   missing runtime, a missing directory) before going further.
3. **Quartermaster build** anything that builds from source; the images land in
   the registry.
4. **Bosun check** the description — clear up collisions or cycles.
5. **Bosun apply** (or `supervise`, to keep it alive) — the services come up.
6. Open **the Chair** in a browser to watch them, and use its buttons to restart
   or take down individual pieces without touching a terminal.

Steady state: `supervise` keeps everything alive; you glance at the Chair for
health and click restart when something needs a kick. When the deployment
changes, you edit the `compose`/`registry`, re-`verify`/`build` if the change
needs new runtimes or artifacts, and `apply` again — Bosun works out the
difference and only changes what moved.

## Why three and not one

The three jobs have different shapes. Provisioning is occasional, fiddly, and
machine-specific — you don't want that mess inside the thing supervising your
infrastructure around the clock. Running and keeping-alive *is* load-bearing and
continuous, so it wants to be a small, narrow, trustworthy program. A web UI is a
presentation concern that shouldn't know about ssh or build toolchains. Splitting
them keeps each one simple and lets them be swapped or skipped independently —
you can run Bosun with no Chair, or provision a host by hand and still let Bosun
run it.

## Status (where the design actually stands)

- **Bosun** — built and in real use; replaced a couple of older home-grown
  launchers. Also compiles to a single native binary that needs no Node at
  runtime.
- **The Chair** — built; already drives both native processes (on the laptop) and
  Docker over ssh (on the Mac Mini) through the one `/state`+`/control` interface.
- **Quartermaster** — newest. `verify` (local and remote, over ssh) and `build`
  (live `docker build` + push on the build host) both work today, and — like
  Bosun — it also compiles to a single native binary that needs no Node at runtime
  (byte-identical to the node build). Proven end-to-end against the real mini:
  build+push the polyglot `edge` image, then Bosun deploys the rig.

The split above is the whole design as it's meant to fit together.

## See also

- `PROVISIONING-SEAM.md` — the exact Bosun ⇄ Quartermaster boundary.
- `ARTIFACTS.md` — the artifact axis (build is a separate lifecycle phase).
- `EXECUTORS.md` — the executor substrates the Chair is agnostic over.
