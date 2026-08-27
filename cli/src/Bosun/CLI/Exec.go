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
	"syscall"
)

// execLineImpl :: EffectFn1 String { ok :: Boolean, code :: Int, message :: String }
var Bosun_CLI_Exec_execLineImpl any = func(args ...any) any {
	line := args[0].(string)
	if strings.HasSuffix(strings.TrimSpace(line), "&") {
		// NODE-FIDELITY: Exec.js spawns a `… &` launch with `{detached:true}`,
		// which `setsid`s the sh into a NEW session/process group. We MUST do the
		// same (`Setsid: true`) — without it the launched sh stays in THIS
		// (supervisor) process group, so daemonize's `ps -o pgid= -p $!` records
		// the SUPERVISOR's group, and a later `kill -- -<pgid>` reaps the
		// supervisor itself, not the service. (The Menagerie's dual-runtime rig
		// caught this divergence: byte-identical command strings, different real
		// effect — group_size 16 under Go vs 3 under node.)
		cmd := exec.Command("/bin/sh", "-c", line)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			return map[string]any{"ok": false, "code": 1, "message": err.Error()}
		}
		// NODE-FIDELITY: node's child_process reaps spawned children via its
		// SIGCHLD handler even when unref'd. Go does NOT auto-reap — a Start()
		// without Wait() leaves the fast-exiting launcher `sh` a ZOMBIE, which
		// retains its pgid (so it counts in the process group and CANNOT be
		// `kill`ed — it's already dead awaiting reap). Reap it in a goroutine so
		// `down`'s group-kill leaves no defunct survivor. (Also caught by the
		// Menagerie rig: forker group_size 4-and-1-survives under Go vs 3-then-0
		// under node.)
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
