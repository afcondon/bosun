# Phase 6C (Go column) — make the Go binary do the devops

**Goal:** the *Go binary* (PureScript → backend-go) computes the deploy plan
with the pure core and **executes** it via os-exec — the deepest form of the
"can the Go program do the devops?" headline. (`bosun apply` already does this
live on the node column; this is the Go column.)

Everything is scaffolded. **Your one manual step** is adding a single foreign
shim to `backend-go/runtime.go` — because that's a file in *your* backend-go
repo, and runtime.go is the hand-maintained foreign catalogue.

## Why only one foreign

The harness `Bosun.Conformance.ApplyMain` is deliberately **I/O-free**: it
hardcodes a two-service hello fixture, runs the pure pipeline
(`reconcile → validate → plan → applyScript`) to a command script, and executes
each line. So the only foreign beyond the pure-core/`Effect.Console` surface
(which backend-go already has) is **os-exec**. No Go ports of js-yaml / fs /
`process.argv` are needed.

The harness runs on **node** already (verified), via its `.js` twin foreign — so
the PureScript side is proven. This is purely the Go shim.

## The step: add the foreign to `runtime.go`

backend-go foreign convention (read off the existing shims):
- a global `var Module_Path_name any = …`, dots → underscores;
- an `EffectFnN` foreign is an uncurried `func(args ...any) any` that performs
  the effect and returns the result synchronously;
- a PureScript record is a `map[string]any` keyed by label;
- `Int` → Go `int`, `String` → `string`, `Boolean` → `bool`.

So `Bosun.Conformance.ApplyMain.execLineImpl :: EffectFn1 String { ok, code,
message }` becomes:

```go
// Bosun apply execution edge (Phase 6C): run one shell line. A backgrounded
// launch (`… &`) returns as soon as the shell forks; the fixture redirects the
// child's output to a file, so CombinedOutput sees EOF immediately and does not
// hang. exit 0 = "dispatched"; actual health is the observation edge's job.
var Bosun_Conformance_ApplyMain_execLineImpl any = func(args ...any) any {
	line := args[0].(string)
	out, err := exec.Command("/bin/sh", "-c", line).CombinedOutput()
	if err != nil {
		code := 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
		return map[string]any{"ok": false, "code": code, "message": strings.TrimSpace(string(out))}
	}
	return map[string]any{"ok": true, "code": 0, "message": strings.TrimSpace(string(out))}
}
```

Add `"os/exec"` to runtime.go's import block. `strings` and `os` are already
imported.

> Note: paste this anywhere among the other `var …_foreign any = …` shims (e.g.
> next to the `Effect_Console_*` block). It does **not** go in a per-module
> file — backend-go's foreigns all live in `runtime.go`, which `go-apply.sh`
> copies into the build dir.

## Then run it

```bash
cd /Users/afc/work/afc-work/ShapedSteer/bosun
./scripts/go-apply.sh
```

The script transpiles the harness via backend-go, `go build`s it, runs the
binary, then independently `curl`s the two ports. Expected:

```
==> RUN the Go binary (it executes the deploy)
apply (Go column): 2 command(s)
  OK  cd /tmp/bosun-hello-go && nohup python3 -m http.server 8774 >echoer.log 2>&1 &
  OK  cd /tmp/bosun-hello-go && nohup python3 -m http.server 8773 >greeter.log 2>&1 &
apply (Go column): done.
==> verify …
   8773 -> HTTP 200
   8774 -> HTTP 200
```

`HTTP 200` on both = **a native Go binary, compiled from PureScript, just
deployed a running rig.** Clean up with `pkill -f 'http.server 877'`.

(If `go build` fails with an undefined `…execLineImpl`, the foreign isn't in
runtime.go yet — that's this step.)
```
