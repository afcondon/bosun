// Bosun's hand-written Go twin of cli/src/Bosun/CLI/Audit.js — the REAL
// `Bosun_CLI_Audit_auditImpl`, for `gnomon-bosun serve --audit` (Node-free).
// One-shot: for each admitted route, spawn its backend in its OWN process group,
// poll the internal port for a TCP connect within the readiness budget, tear the
// whole tree down, and report {serviceId, publicPort, ok, ms, message}. Mirrors
// the serve shim's spawn + readiness, minus the resident proxy. APP-SPECIFIC;
// copied into the gnomon-bosun build by scripts/gnomon-bosun.sh.
//
// backend-go ABI: EffectFn1 (Array Route) (Array AuditResult) → func(args ...any)
// any, arg an []any of route map[string]any, result an []any of result maps.
package main

import (
	"fmt"
	"net"
	"os/exec"
	"syscall"
	"time"
)

const cliAuditReadyTimeoutS = 8

// auditImpl :: EffectFn1 (Array Route) (Array AuditResult)
var Bosun_CLI_Audit_auditImpl any = func(args ...any) any {
	routes := _force(args[0]).([]any)
	results := make([]any, 0, len(routes))
	for _, r := range routes {
		route := _force(r).(map[string]any)
		serviceID := _force(route["serviceId"]).(string)
		publicPort := _force(route["publicPort"]).(int)
		internalPort := _force(route["internalPort"]).(int)
		cwd := _force(route["cwd"]).(string)
		launch := _force(route["launchCommand"]).(string)

		t0 := time.Now()
		ok := false
		msg := ""
		cmd := exec.Command("bash", "-c", launch)
		cmd.Dir = cwd
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // own group → kill the whole tree after
		if err := cmd.Start(); err != nil {
			msg = "spawn failed: " + err.Error()
		} else {
			addr := fmt.Sprintf("127.0.0.1:%d", internalPort)
			deadline := time.Now().Add(cliAuditReadyTimeoutS * time.Second)
			for time.Now().Before(deadline) {
				if conn, e := net.DialTimeout("tcp", addr, 200*time.Millisecond); e == nil {
					conn.Close()
					ok = true
					break
				}
				time.Sleep(200 * time.Millisecond)
			}
			if cmd.Process != nil {
				syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
			}
			go cmd.Wait() // reap, no zombie
			if ok {
				msg = "came up"
			} else {
				msg = fmt.Sprintf("did not bind :%d within %ds", internalPort, cliAuditReadyTimeoutS)
			}
		}
		results = append(results, map[string]any{
			"serviceId": serviceID, "publicPort": publicPort,
			"ok": ok, "ms": int(time.Since(t0).Milliseconds()), "message": msg,
		})
	}
	return results
}
