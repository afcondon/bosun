// Bosun's hand-written Go foreign for the apply execution edge (Phase 6C).
//
// This is the ONE piece of hand-written Go that Bosun owns. It lives HERE, in
// the Bosun repo (not in backend-go's runtime.go), because it is an
// APP-SPECIFIC foreign — backend-go's runtime should stay app-agnostic, and a
// foreign versioned with Bosun can't be clobbered by anything in backend-go.
// `scripts/go-apply.sh` copies this file into the backend-go build dir next to
// the generated `package main` sources, where `go build *.go` resolves the
// otherwise-undefined `Bosun_Conformance_ApplyMain_execLineImpl` symbol.
//
// backend-go foreign ABI: a foreign import `Module.Path.name` becomes a global
// `var Module_Path_name any`; an EffectFn1 is an uncurried `func(args ...any)
// any` performed synchronously; a PureScript record is a `map[string]any`;
// Int/String/Boolean map to Go int/string/bool.
package main

import (
	"os/exec"
	"strings"
	"syscall"
)

// execLineImpl :: EffectFn1 String { ok :: Boolean, code :: Int, message :: String }
//
// A backgrounded launch (`… &`) is fire-and-forget: Start() without Wait and
// with nil stdio (/dev/null), so the daemonising child can't hold an output
// pipe open and hang us (CombinedOutput on a `… &` line DOES hang — the child
// keeps the pipe). exit 0 there means "dispatched"; actual health is the
// observation edge's job. Everything else (docker, ssh) is synchronous with
// captured output and a real exit code.
var Bosun_Conformance_ApplyMain_execLineImpl any = func(args ...any) any {
	line := args[0].(string)
	if strings.HasSuffix(strings.TrimSpace(line), "&") {
		// NODE-FIDELITY, and now load-bearing: Exec.js spawns a `… &` launch
		// `{detached:true}`, which setsid's the sh into a NEW session/group, and
		// `bosun_exec_foreign.go` has matched that since the Menagerie caught the
		// divergence. This harness never did — and until every Process became
		// TRACKED (2026-08-25, the teardown-fidelity change) nothing could tell:
		// its fixture's start commands ended in `&`, so `daemonize` passed them
		// through and no pidfile was ever written. The moment one was, it held
		// the GO BINARY's own process group — shared by every service this run
		// launched — and a single `pidStop` reaped the lot (observed: stopping
		// hellogo-greeter left hellogo-echoer `already-gone`).
		cmd := exec.Command("/bin/sh", "-c", line)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			return map[string]any{"ok": false, "code": 1, "message": err.Error()}
		}
		// Go does not auto-reap; a Start() without Wait() leaves the launcher sh
		// a zombie that still counts in the group and cannot be killed again.
		go func() { _ = cmd.Wait() }()
		return map[string]any{"ok": true, "code": 0, "message": "launched (backgrounded)"}
	}
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
