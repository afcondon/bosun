// Bosun's hand-written Go twins of cli/src/Bosun/CLI/Observe.js — the readiness/
// liveness PROBES the resident supervisor reads each tick. These provide the REAL
// CLI foreign symbols `Bosun_CLI_Observe_probe{Http,Tcp,Socket,PgidAlive}Impl`, so
// a backend-go build of the supervise resident (Bosun.Conformance.MenagerieMain)
// observes running reality the same way the node column does from Observe.js.
// APP-SPECIFIC; copied into the build dir by scripts/menagerie-conf.sh.
//
// Synchronous on purpose — the no-Aff seam. Each mirrors its JS twin's contract
// exactly: Down/false on ANY failure (refused, timeout, missing), never a throw.
//
// backend-go ABI: an `EffectFnN` (from the FFI) is a variadic `func(...any) any`
// taking its N already-forced args and returning the run result; `Int` is Go
// `int`, `String` is Go `string`, `Boolean` is Go `bool` (matches Exec/Resident
// twins, which assert args[i] directly without _force).
package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// probeHttpImpl :: EffectFn3 String Int String String — (host, port, path) -> the
// HTTP status code as a string ("200"/"503"/…); "000" on any failure (the JS twin
// returns curl's %{http_code}, "000" on refused/timeout). 3s budget.
var Bosun_CLI_Observe_probeHttpImpl any = func(args ...any) any {
	host := args[0].(string)
	port := args[1].(int)
	path := args[2].(string)
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(fmt.Sprintf("http://%s:%d%s", host, port, path))
	if err != nil {
		return "000"
	}
	defer resp.Body.Close()
	return strconv.Itoa(resp.StatusCode)
}

// probeTcpImpl :: EffectFn2 String Int Boolean — a TCP connect within 3s (the JS
// twin's `nc -z -w 3`).
var Bosun_CLI_Observe_probeTcpImpl any = func(args ...any) any {
	host := args[0].(string)
	port := args[1].(int)
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", host, port), 3*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// probeSocketImpl :: EffectFn1 String Boolean — does the unix-socket file exist?
// (weak liveness; the JS twin is `existsSync`).
var Bosun_CLI_Observe_probeSocketImpl any = func(args ...any) any {
	path := args[0].(string)
	_, err := os.Stat(path)
	return err == nil
}

// probePgidAliveImpl :: EffectFn1 String Boolean — read the recorded PGID and
// `kill(-pgid, 0)`: POSIX signal-0 tests group existence WITHOUT signalling. The
// honest liveness signal for a Bosun-launched process group. A missing file or a
// dead group reads false — exactly the JS twin (`process.kill(-pgid, 0)`).
var Bosun_CLI_Observe_probePgidAliveImpl any = func(args ...any) any {
	pidFile := args[0].(string)
	b, err := os.ReadFile(pidFile)
	if err != nil {
		return false
	}
	pgid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pgid <= 1 {
		return false
	}
	if err := syscall.Kill(-pgid, syscall.Signal(0)); err != nil {
		return false
	}
	return true
}

// probeExecImpl :: EffectFn1 String Boolean — run a command line on the host and
// report whether it exited 0 (the JS twin's `execSync` + 5s timeout). The only
// probe that answers "is it up, whoever started it": every other reading here is
// either a port this service is expected to bind or a process group Bosun itself
// recorded, and a hand-started singleton satisfies neither while being alive.
var Bosun_CLI_Observe_probeExecImpl any = func(args ...any) any {
	line := args[0].(string)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "/bin/sh", "-c", line).Run() == nil
}
