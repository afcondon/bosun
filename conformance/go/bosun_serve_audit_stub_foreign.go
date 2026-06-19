// Deferred-verb stubs for the gnomon-bosun build (scripts/gnomon-bosun.sh).
//
// `Bosun.CLI.Main` imports every subcommand, so a flat `go build` of it must
// resolve EVERY referenced foreign symbol — including `serve` (the lazy-spawn
// reverse-proxy router) and `serve --audit`, which AC scoped OUT of the first
// gnomon-bosun (the deploy/supervise verbs are the backend stress surface). These
// stubs let the binary link; they are never CALLED by check/plan/observe/apply/
// down/supervise/docker, so they never fire. If someone runs `gnomon-bosun serve`
// they get a clear "use the node CLI" message rather than a silent wrong result —
// the honest boundary of a deferred capability, not a hack.
//
// (The real Go ports — serveImpl is a genuine reverse proxy, auditImpl a
// spawn/probe/teardown loop — land if/when serve is brought onto the Gnomon
// column; the node CLI serves them today.)
package main

// serveImpl :: EffectFn1 ServeConfig Unit
var Bosun_CLI_Serve_serveImpl any = func(args ...any) any {
	panic("gnomon-bosun: `serve` is not supported by the Gnomon build yet (deferred) — use the node CLI: `node cli/run.js serve …`")
}

// auditImpl :: EffectFn1 (Array Route) (Array AuditResult)
var Bosun_CLI_Audit_auditImpl any = func(args ...any) any {
	panic("gnomon-bosun: `serve --audit` is not supported by the Gnomon build yet (deferred) — use the node CLI")
}
