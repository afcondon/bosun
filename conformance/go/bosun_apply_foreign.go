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
		if err := exec.Command("/bin/sh", "-c", line).Start(); err != nil {
			return map[string]any{"ok": false, "code": 1, "message": err.Error()}
		}
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
