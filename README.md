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

- **Design:** [`docs/DESIGN.md`](docs/DESIGN.md) — the type design, the
  cross-tool panoply, the MISU tiers, the real drifted-system grounding.
- **Family:** a standalone ShapedSteer-family proof-of-concept (Marginalia
  #227, child of ShapedSteer #132). No obligation to share ShapedSteer code;
  embodies the vision, written fresh.
- **Built with:** the PureScript→Go backend. PureScript owns the pure core
  + synchronous I/O; Go owns concurrency (and only concurrency).

Status: **design**. No code yet.
