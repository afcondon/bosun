// Bosun's hand-written Go twin of cli/src/Bosun/CLI/Exec.js — the execution
// edge (`execLine`). Unlike the Phase-6C ApplyMain shim (which declared its own
// `Bosun_Conformance_ApplyMain_execLineImpl`), this provides the REAL CLI
// foreign symbol `Bosun_CLI_Exec_execLineImpl`, so a backend-go build of any
// CLI module that reaches `Bosun.CLI.Exec.execLine` (here: `bosun docker`'s
// ssh `docker compose ps`/`up`/`stop`) resolves against the same os-exec
// behaviour the node column gets from Exec.js. APP-SPECIFIC; copied into the
// build dir by the scripts that need it.
//
// A backgrounded launch (`… &`) is Start()-without-Wait, nil stdio — the
// daemonising child can't hold a pipe open and hang us (CombinedOutput on a
// `… &` line DOES hang). Everything else (docker, ssh) is synchronous with
// captured output + a real exit code.
package main

import (
	"os/exec"
	"strings"
)

// execLineImpl :: EffectFn1 String { ok :: Boolean, code :: Int, message :: String }
var Bosun_CLI_Exec_execLineImpl any = func(args ...any) any {
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
