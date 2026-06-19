# Port model — public port as identity, bind port as placement detail

**Status:** DECISION (2026-06-18). Settled while moving the dev-server registry
into a git-tracked, Bosun-owned source of truth (the SDI replacement) and asking:
if the registry is fleet-wide, are we forcing one port per service across every
machine, with no room for a per-machine exception?

## The question

A fleet-wide registry tags each service with a **host** (`mbp`/`macmini`/…) and
gives it a **port**. If the port is a property of the *service*, then a service
has the same port on every machine it runs on — convenient, but what about the
contingency where you *must* run it on a different port on some other machine
(its usual port is taken there by something Bosun doesn't manage)? Do we have
**port consistency** at the cost of **port flexibility**?

## The reframe: there are two ports, answering different questions

- **Public port** — the address clients and other services know the service
  *by*. It is the service's **identity / contract** (`tilted-radio:frontend`
  *is* `:3013`).
- **Bind (internal) port** — where the process actually listens. `bosun serve`
  already divorces this: `internal = public + 20000` (`internalOffset`), and it
  is free to vary per machine, per spawn. Nobody types it.

So *bind-level* flexibility already exists, abstracted by the router. The only
open question is whether a service's **public** identity may differ per machine.

## The model already allows per-machine ports — as a *divergence*

Bosun does not attach the port to the logical service; it attaches it to the
**facet** — the per-(service, host) placement. The reconcile layer's
divergence-vs-conflict distinction (DECISIONS D-E3) draws the line exactly where
we want it:

- The same service on `mbp:3013` **and** `macmini:4013` is a **divergence** —
  two legitimate facets, expressed as two registry rows (same project + role,
  different host + port). **Not an error.**
- Two *sources* disagreeing about the port for the **same** (service, host) is a
  **conflict** — flagged as drift.

`serve`'s single-binder guard (`PortClaimed`, the arbitrate pass) is **per
machine** — each machine's router binds its own ports — so a different public
port on machine B never collides with machine A.

Therefore the architecture does **not** force port consistency. The choice is
purely what the *convention* (and the registry's day-to-day shape) encourages.

## Decision

**Default: the public port is the service's fleet-stable identity.** One number,
consistent on every machine the service runs on.

Rationale:
- **Lower complexity.** "What port is X?" is answerable without "…on which
  machine?". One well-known address per service.
- **It's a contract, not an accident.** Other services and bookmarks address a
  service by its public port; keeping it stable across placements is a feature.
- **It matches the k8s Service-port intuition** (a stable virtual port; the
  pod/bind port is ephemeral) — the "k8s as Jane St would build it" framing of
  `FEDERATION.md`. The bind port (`+20000`, or a router-assigned port) is the
  ephemeral half, already free.

**Escape hatch (when a contingency forces it): an explicit per-(service, host)
override** — a registry row for that host carrying its own public port. This
needs **no schema or code change**: it is a divergent facet, which the reconcile
model and the router already handle. Flexibility is *available on demand*, not
*designed out* — it just isn't the default, so it doesn't tax the common case.

## What this is NOT

- Not a claim that a service can't move or run in two places — it can; that's a
  divergence.
- Not automatic per-machine port reassignment. If a service's public port is
  unavailable on a machine, `serve` reports it unbound (honest) — it does **not**
  silently pick another port. Re-homing to a different public port on that
  machine is a deliberate act: add the override row. Silent reassignment would
  break the identity/contract property that makes the default worth having.

## Consequence for the registry

The git-tracked `registry/fleet.json` keeps the existing one-row-per-(project,
role) shape as the common case (port = the service's fleet-stable public port).
A per-machine exception is simply a second row for that project+role with a
different `host` and `port`. Tooling must not assume one row per service — but
nothing needs to special-case the exception either; it falls out of the facet
model.
