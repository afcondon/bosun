# Deploy substrates — "Nix-build / mostly-container-deploy", carved out honestly

**Status:** DESIGN (2026-06-19). Companion to `EXECUTORS.md` (the executor
seam), `RUNTIME-SPINE-AND-BUILD-LAYER.md` (build/deploy/run as one typed DAG),
`FEDERATION.md`. Records the working deployment vision **with its explicit
exceptions**, so containers are *one substrate chosen by fitness*, not an
unqualified default.

## The vision, stated

- **Build:** Nix on the build machine → reproducible, content-addressed
  artifacts.
- **Deploy:** mostly containerized, on Linux servers.

This is correct **for the server/web tier** and is the standard pattern. The
only failure mode is *erosion*: if "mostly containers" hardens into "containers
by default," it silently forecloses deployment classes the rest of the system
structurally requires. This doc names them so the default stays a choice.

## The principle: deploy-substrate by fitness

Mirror of *runtime-by-fitness* (the runtime axis: what PS compiles to —
Go/BEAM/Node). The **substrate axis** is *where/how the artifact runs* —
container / static binary / launchd / BEAM release. Container is **one executor
among several** (`process | docker | launchd | nix-store`), chosen per target.

Crucially the two axes **compose** — this is the `{substrate} × {runtime} ×
{target}` cube. A Go binary (runtime) can deploy as a container *or* a bare
binary (substrate); a BEAM service can deploy as a release *or* a container.

**Nix is orthogonal and universal here.** All substrates consume Nix-built,
content-addressed artifacts — a static binary, a BEAM release, *and* a container
image can each be a Nix output. Nix unifies the **build edge**; substrate-by-
fitness diversifies the **run edge**; the artifact-pin (`x-bosun.artifact
{source, pin}`) is the seam between them.

## The fitness table

| Target class | Deploy substrate | Bosun executor | Why this (not a container) |
|---|---|---|---|
| **Linux server / web service** (polyglot site, Mattermost, NextCloud) | OCI container | `docker` | The default. Containers are right here. Build the image *with Nix* (`dockerTools.buildImage`) so the pin carries through. |
| **Bare / minimal / embedded** (the eurorack PS computing surface; any host with no launchd/systemd/docker) | static binary (Gnomon → Go) | `process` (bring-your-own-supervisor) | There is no container runtime on the target — the single binary *is* the deployment. The whole "portable kernel cell" axis. |
| **macOS hardware/audio rig** (`es9-daemon`/CoreAudio, `link-spike`/Link multicast, eurorack hardware) | native process under launchd | `launchd` / `process` (macOS substrate) | Cannot containerize: needs direct hardware + macOS frameworks; Docker-on-mac is a Linux VM with no CoreAudio. A permanent first-class class, not an exception to route around. |
| **BEAM long-lived / distributed / hot-reload** (purerl supervisor, a federation node) | BEAM release on a host (relx/release) | `process` (BEAM/OTP supervision) | Cattle-containers discard the very properties BEAM was chosen for — hot code reload, clustering/distribution, supervision trees. *Fitness call*: a thin OTP-friendly container is possible, but immutable-replace fights OTP. |
| **Static site / edge** (hylograph.net, the polyglot CF Pages) | Cloudflare Pages / static httpd binary | `cloudflare` / `process` | Already non-container; a Gnomon→Go static server or CF Pages, not an image. |

## Two carry-through rules (so the good part of the vision holds)

1. **Build images *with* Nix, not Dockerfiles.** A `FROM ubuntu; COPY binary`
   step leaks the reproducibility you went to Nix for — two content-addressing
   systems with a non-reproducible seam. `dockerTools.buildImage` /
   `buildLayeredImage` make the image a Nix output, so the artifact-pin carries
   straight through to deploy.
2. **The container is a *substrate the executor drives*, not the unit of
   reasoning.** Bosun's typed model (services / ports / health / boot order)
   stays the reasoning layer; the container is the run-substrate, like the OS.
   Container-as-black-box-unit re-opaques the deploy half of the DAG that Nix
   just made transparent — and breaks the one-Sankey-chart goal
   (`RUNTIME-SPINE` §1, §7). Container-as-substrate-under-Bosun does not.

## The failure mode to watch

Not the vision — the *erosion*. "Mostly containers" is fine; "containers by
default, other executors atrophy" is the trap, because the eurorack surface and
the macOS music rig **structurally require** the non-container executors. Keep
`process` / `launchd` / `nix-store` first-class alongside `docker`, exactly as
the runtime axis keeps Go / BEAM / Node first-class alongside each other. Same
discipline, the run edge instead of the compile edge.
