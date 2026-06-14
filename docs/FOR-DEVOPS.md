# Bosun, for people who run things

*Audience: an experienced ops/SRE/platform engineer who is fluent in
docker-compose, systemd, Kubernetes, Terraform, Ansible — and has never
written a line of functional programming, nor wants to. You will not need
any of that here. This doc is about what Bosun is, what it touches, what it
leaves alone, and why it is **not** "yet another config format."*

Status: design stage. This describes what Bosun is for, not a shipping
product.

---

## The 30-second version

You already have your services defined — some in a `docker-compose.yml`, some
in systemd units or launchd plists, a couple as bare processes behind an
nginx route table, a few static sites on a CDN. The truth about "what runs
where, on what port, depending on what" is **scattered across all of those
files, and they drift.** The compose file says one thing, the reverse-proxy
config says another, the inventory spreadsheet says a third, and you find out
which one was wrong at 3am.

Bosun **reads the files you already have**, builds one typed model of your
whole deployment, and tells you where the sources disagree, where a
dependency points at nothing, where two things claim the same port, where a
service waits on another service's health check that doesn't exist. Then it
can show you the dependency graph, tell you what would start (and in what
order), bring it up, and — if you want — regenerate those same config files
from the one model so they *stop* drifting.

It is a **checker and reconciler over your existing config**, in the spirit of
`terraform plan` or a linter — not a new format you have to adopt.

---

## The problem it targets

There's a real gap in the tooling. Kubernetes is superb at scheduling
containers across a cluster and healing them — but it's heavy, it assumes
everything is a container, and the YAML surface is enormous. docker-compose is
great for a handful of containers on one host — but it's flat (one launch
mechanism, weak dependency semantics, no notion of the systemd unit next to
it), and it has no idea the rest of your system exists. Terraform provisions
cloud infrastructure beautifully — but it's not a process supervisor and
doesn't model "start the API only after the database reports healthy."

So the **small-to-medium, heterogeneous, multi-mechanism deployment** — a
homelab, a research rig, a few VMs running a deliberate mix of containers,
system services, static sites, and a couple of plain daemons — falls between
the tools. k8s is too much; compose is too little; and the real configuration
ends up spread across four formats that nobody reconciles. That spread is
where the failures live:

> There are far more *representable* configurations than *legal* ones. YAML and
> env-vars let you write a dependency cycle, a port collision, a frontend in a
> profile whose backend isn't, a "wait until healthy" that waits on a service
> with no health check. Every one of those is a config you can write and ship —
> and it only blows up at deploy time.

Bosun's whole job is to shrink the set of configurations you can express down
toward the set that actually works, and to do it **before** anything runs.

---

## What Bosun is — and the xkcd 927 question

If you've been around, your reflex is [xkcd 927](https://xkcd.com/927/):
*"There are 14 competing standards." "We need one universal standard!" …"There
are 15 competing standards."* A tool that claims to unify compose + systemd +
k8s + Terraform sounds exactly like standard #15.

**Here is why it isn't.** xkcd 927 is about formats that *compete to replace
each other* — each new one asks you to throw away the others and rewrite. The
joke only works because adoption is rivalrous: picking one means abandoning the
rest.

Bosun does not ask you to adopt a format. **It reads the formats you already
have.** Its value comes *precisely from there being many of them* — it is the
layer that sits across your compose file and your systemd units and your route
table and tells you where they disagree. A universal *reader/reconciler* is the
opposite of 927: a 927 "universal standard" gets *less* useful the more formats
exist (it's one more to ignore), whereas Bosun gets *more* useful the more
formats your system is smeared across (more drift to catch).

The honest precedents are tools you already trust, none of which are "standard
#15":

- A **typechecker / language server** reads your existing code; it doesn't
  replace the language.
- **`terraform plan`** shows you drift between your config and reality; it
  doesn't replace your infrastructure.
- A **linter** reads your existing files and finds the bugs across them.
- **`EXPLAIN`** reads your existing query.

Bosun is that layer for deployment config: it *consumes* the standards instead
of competing with them.

### The overlay — not a new config file

There is **one** file Bosun adds, and it is the strongest part of the anti-927
argument, not the weakest. Your existing files already hold the *configuration*
— ports, images, commands, env. What they **cannot** express is the
cross-cutting truth that today lives in nobody's file: which compose service
*is* which registry entry, the start-order dependencies you keep in a README or
a bash script, which "wait until healthy" gates on what. The overlay is where
that goes. It is **the format for the stuff that has no other format.**

Three properties keep it from being config-format #15:

- **It never duplicates your config.** It doesn't restate a port or an image;
  it adds *relationships between* the things your real files already define. It
  is strictly **additive**.
- **It is valid empty.** With no overlay at all, Bosun still ingests,
  reconciles, and checks your existing files — the overlay only adds what those
  files structurally can't say. You opt into exactly as much as you need to fix
  a real problem.
- **It never gets shipped downstream.** Whatever you produce, the artifacts
  other tools consume are still ordinary compose / systemd / k8s files. Bosun
  is never a runtime dependency anyone else has to install.

This is a two-tier offering, and you choose your rung:

- **Detect** — the prebuilt binary, zero setup. Point it at your config and it
  reports every problem (the `bosun check` above). Read-only.
- **Reconcile & launch** — author the overlay in a typed DSL and compile it (a
  build step). The payoff: illegal deployments *don't compile*, and Bosun can
  then bring your system up consistently — in dependency order, with the right
  health gates — **without rewriting a single one of your config files.** It
  orchestrates *on top of* your compose/units; it doesn't take them over.

So the only thing you "adopt" is a place to write down the relationships your
tools already assume but can't state — and even at the launch tier, Bosun stays
*non-invasive*: it reads and coordinates your stack, it never rewrites it.

---

## Support / Displace / Ignore

How Bosun relates to each technology in your stack.

### SUPPORT — reads from, and/or writes to (these stay yours)

| Technology | Relationship |
|---|---|
| **docker-compose** | *Ingest + emit.* The first-class target. Reads your services, ports, profiles, health checks; can regenerate the file from the model. |
| **systemd units** | *Ingest + emit.* Bosun's internal dependency model is **built on systemd's own taxonomy** (ordering vs requirement; `Wants`/`Requires`/`Requisite`/`BindsTo`/`PartOf`) — because it's the most honest one in the industry. Reads and writes `.service` files. |
| **launchd (macOS)** | *Ingest + emit.* The macOS equivalent of systemd; same treatment. |
| **Kubernetes manifests** | *Ingest + emit* (later phase). Reads Deployments/Services; can emit them. Bosun is **not** a controller — see Ignore. |
| **Reverse proxies (nginx / Caddy / Traefik) & Ingress** | *Emit, and ideally ingest.* Routes are modelled as first-class edges, so "the route table mentions `/sankey` but nothing serves it" becomes an error, not a 404 you find later. |
| **A service inventory / port registry** | *Ingest.* If you keep a source of truth for "what runs where on what port," Bosun reconciles it against the other sources. (Any inventory works; you don't need a specific one.) |
| **Procfile / 12-factor apps** | *Ingest.* The flat process list becomes nodes in the graph. |
| **Terraform state** | *Ingest* (later phase). Reads *what's actually provisioned* so the orchestration sits correctly on top — Bosun does not provision (see Ignore). |

### DISPLACE — does the job you're currently doing by hand

| What you do today | What Bosun replaces it with |
|---|---|
| **The tribal knowledge of start order** — "bring up the DB, wait, then the API, then the proxy," living in a README or a bash script or someone's head | A typed, **provably acyclic** dependency graph with explicit health gates; the boot order is *computed*, not remembered. |
| **Manually keeping sources in sync** — editing the compose file *and* the route table *and* the inventory and hoping you got all three | One model; the drift between sources is **reported**, and the files can be **regenerated** so they can't diverge. |
| **`is-it-up.sh`** and ad-hoc health-poking | A `plan` step that diffs your intended state against observed reality and tells you exactly what's stale, before you touch anything. |
| **Single-host compose-as-orchestrator that you've outgrown** — flat deps, one mechanism, no cross-tool view | A richer model on the same (or a few) hosts, without jumping to a cluster scheduler. |

Bosun does **not** try to displace Kubernetes as a cluster scheduler, or
Terraform as a cloud provisioner. It displaces the *manual glue between your
tools*, which today has no owner.

### IGNORE — explicitly out of scope (interoperate, don't compete)

| Technology / concern | Why Bosun stays out |
|---|---|
| **Cloud provisioning / IaC** (Terraform, Pulumi, CloudFormation creating VPCs, LBs, managed DBs) | Bosun assumes the infrastructure exists and orchestrates *services on it*. It *reads* Terraform state; it doesn't create infrastructure. |
| **Container image building** (Dockerfile, BuildKit) | Bosun references images and build contexts; it doesn't build them. |
| **Cluster scheduling / bin-packing across many nodes** (the k8s scheduler, Nomad) | Bosun targets a small, **known** set of hosts, not a 1000-node fleet that needs a placement algorithm. |
| **Secrets backends** (Vault, SOPS, sealed-secrets) | Bosun references secrets; it doesn't store or rotate them. |
| **Service mesh, autoscaling, CI/CD pipelines** | Different layer; not Bosun's problem. |
| **Per-environment templating at scale** (Helm, full Kustomize) | Bosun has lightweight grouping (profiles/namespaces) but is a *checker/reconciler*, not a templating engine. |

The one-line test for "ignore": if it **creates capacity** (machines,
networks, images, clusters) or **schedules across a large fleet**, that's not
Bosun — Bosun **orchestrates and reconciles the services that run on capacity
you already have**, across however many mechanisms you happen to use.

---

## What it looks like in practice

Familiar shape — it's a single binary with subcommands:

```
$ bosun check
Reading: docker-compose.yml, ./units/*.service, routes.conf, inventory.json

  DRIFT     tilted-radio: compose calls it "tidal-frontend" (no published port,
            behind edge); inventory calls it "psd3-tilted-radio" :3013 (native).
            Same service, two deployments — ports & names disagree.
  ERROR     edge: route "/sankey" → no backing service.
  ERROR     api: depends_on "databse" — no such service (typo for "database"?).
  ERROR     web-profile not closed: "frontend" needs "backend", not in profile.
  WARN      worker: waits for redis to be "healthy", but redis defines no
            health check — that wait can never be satisfied.

5 issues across 4 sources. 0 of them would surface until deploy time.
```

```
$ bosun plan
Boot order (computed, acyclic):
  stage 1   database, redis
  stage 2   api          (after database healthy)
  stage 3   frontend, worker
  stage 4   edge         (after frontend ready; routes /code, /ee, /sankey)

Against running reality:
  RESTART   api        (config changed: DB host)
  START     worker     (down)
  NOOP      database, redis, frontend, edge   (running & healthy)
```

```
$ bosun graph          # renders the dependency DAG + a live status grid
$ bosun apply          # brings the deployment to the planned state, in order
$ bosun emit compose   # regenerate docker-compose.yml from the model
```

`check` is the part that pays for itself on day one: five real bugs, found
before anything started, across files that no single existing tool reads
together.

---

## "But it's written in a functional language"

It is, and you will never see that. Two things are worth knowing:

1. **The detect tier is a single static binary** (compiled to Go). No runtime,
   no JVM, no Python environment, no dependencies to install. Drop it on a box,
   point it at your config, read the report. The launch tier asks for one build
   step (compiling your overlay) — see below for why that's a feature, not a
   tax.

2. **The implementation language lets the tool guarantee, not just hope.** When
   Bosun says a deployment is valid, it doesn't mean "we ran some checks and
   they passed." It means specific, named classes of failure — dependency
   cycles, references to services that don't exist, two services on one port, a
   health-gated wait on a service with no health check — **cannot be present**,
   the same way a compiled, typechecked program can't have a "method not found"
   at runtime. At the detect tier you get this as a report; at the launch tier
   the **compile step is the gate** — an illegal deployment doesn't compile, so
   it can't be launched. Either way an invalid deployment can't make it past the
   front door, rather than being caught (or missed) by scattered checks later.
   That's the whole reason for the technology choice; the payoff is *fewer 3am
   surprises*, which is a language you do speak.

You configure Bosun by pointing it at your existing files (and, for the launch
tier, by writing the overlay — in which case the tool refuses to let you
*write* the illegal states in the first place). Either way, no functional
programming required of you — the overlay is relationships, not code you'd
recognise as a program.

---

## When NOT to use Bosun

Straight, because it builds trust:

- **You're all-in on Kubernetes at scale.** Then k8s + its controllers already
  own reconciliation across a cluster; Bosun's niche (heterogeneous, few hosts,
  mixed mechanisms) isn't your situation. Bosun can still *check* manifests, but
  it isn't the main event.
- **You need provisioning, not orchestration.** If the job is "create the
  infrastructure," that's Terraform/Pulumi; Bosun sits on top, after.
- **One compose file, one host, no drift, no pain.** If compose alone fully
  describes your world and nothing else touches it, you may not have the problem
  Bosun solves yet. Come back when the second mechanism shows up.

Bosun earns its place exactly when your deployment lives in **more than one
tool at once**, and the gaps between them have started to cost you.
