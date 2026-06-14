# Bosun

*"The Go son."* A typed deployment-DAG tool — and the MVP-gating showcase
for the PureScript→Go backend.

A deployment is a **typed directed graph**: services are nodes, dependencies
are typed edges, a small set of executors bring nodes to life. Bosun's core
IR is a **lingua franca** that docker-compose, systemd, Kubernetes,
Terraform, launchd, Procfiles, and the local SDI registry all *project
onto* — each tool becomes an adapter that parses **into** the IR and renders
**out of** it.

The point is "parse, don't validate" at two altitudes: messy config strings
become precise typed values (ingestion), and a loose multi-source
`Deployment` becomes a tight `ValidatedDeployment` with a proven-acyclic
boot order (validation) — after which `plan` and `apply` are *total*. The
showcase: **"the dozen ways your deploy breaks at 3am — and the half the
compiler won't let you write."**

- **Docs:**
  - [`docs/FOR-DEVOPS.md`](docs/FOR-DEVOPS.md) — **start here if you run
    things and don't care about types** — what Bosun supports / displaces /
    ignores, and why it's not "config format #15."
  - [`docs/PRINCIPLES.md`](docs/PRINCIPLES.md) — the governing discipline
    (all uncertainty at the edges; the invariant-boundary ledger).
  - [`docs/DESIGN.md`](docs/DESIGN.md) — the type design, the cross-tool
    panoply, the two-tier "illegal states" story.
  - [`docs/SCENARIOS.md`](docs/SCENARIOS.md) — 29 scenarios stress-testing
    the types; the open-questions agenda.
  - [`docs/DECISIONS.md`](docs/DECISIONS.md) — ADR-style resolutions to the
    open questions (facet model, stop-propagation, config refs, restart
    conditions).
  - [`spike/`](spike/) — compile-verified proof that the authoring-DSL
    rows-as-sets encoding works (`purs` 0.15.15).
  - [`docs/PRIOR-ART.md`](docs/PRIOR-ART.md) — type-design lessons from
    Propellor, Dhall, CUE, systemd, NixOS, Pulumi, Terraform, Build-à-la-Carte.
- **Family:** a standalone ShapedSteer-family proof-of-concept (Marginalia
  #227, child of ShapedSteer #132). No obligation to share ShapedSteer code;
  embodies the vision, written fresh.
- **Built with:** the PureScript→Go backend. PureScript owns the pure core
  + synchronous I/O; Go owns concurrency (and only concurrency).

Status: **design**. No code yet.
