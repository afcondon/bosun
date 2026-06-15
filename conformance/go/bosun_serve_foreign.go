// Bosun's hand-written Go foreign for the `bosun serve` resident reverse proxy
// (Phase 7, P3 — the Go column). Like the apply os-exec foreign, this is an
// APP-SPECIFIC shim that lives in the Bosun repo (not backend-go's runtime),
// copied into the build dir by scripts/go-serve.sh so `go build *.go` resolves
// the otherwise-undefined `Bosun_Conformance_ServeMain_serveImpl`. It is the Go
// twin of cli/src/Bosun/CLI/Serve.js, driven by the SAME pure ServePlan.
//
// backend-go foreign ABI: a foreign import `Module.Path.name` becomes a global
// `var Module_Path_name any`; an EffectFn1 is an uncurried `func(args ...any)
// any` performed synchronously; a PureScript record is a `map[string]any`, an
// Array is a `[]any`; Int/String map to Go int/string. Nested field values may
// still be lazy thunks (the GetProp/GetIndex accessors don't force), so each
// extracted value is passed through `_force` (a no-op on a non-thunk) before the
// type assertion.
//
// CONCURRENCY: goroutine-per-request (Go's net/http). Per-route state (the
// spawned child + idle timer) is guarded by a mutex; concurrent first-requests
// single-flight on it. This is the tier that needs the thread-safe runtime —
// the sync.Once thunk fix in backend-go/runtime.go (verified by the RaceSpike
// harness under -race). SERVE-LAYER TIMEOUTS own the degenerate "backend won't
// come up / a force hangs" case: a per-request context deadline turns it into a
// 504, and http.Server.ReadHeaderTimeout bounds slow clients — so a stuck
// request can never silently wedge a goroutine forever (the one case where the
// runtime's deadlock-on-eager-cycle would be worse than the old panic).
package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

const serveInternalHost = "127.0.0.1"
const serveWaitTimeout = 30 * time.Second

type serveRoute struct {
	mu        sync.Mutex
	up        bool
	cmd       *exec.Cmd
	idleTimer *time.Timer
}

// serveImpl :: EffectFn1 (Array Route) Unit  (resident — does not return)
var Bosun_Conformance_ServeMain_serveImpl any = func(args ...any) any {
	routes := _force(args[0]).([]any)
	for _, r := range routes {
		startServeRoute(_force(r).(map[string]any))
	}
	select {} // resident: the router lives until the process is killed
}

func startServeRoute(route map[string]any) {
	publicPort := _force(route["publicPort"]).(int)
	internalPort := _force(route["internalPort"]).(int)
	serviceID := _force(route["serviceId"]).(string)
	cwd := _force(route["cwd"]).(string)
	launch := _force(route["launchCommand"]).(string)
	idleMs := _force(route["idleTimeoutMs"]).(int)

	st := &serveRoute{}
	target, _ := url.Parse(fmt.Sprintf("http://%s:%d", serveInternalHost, internalPort))
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		http.Error(w, "bosun serve: proxy error for "+serviceID+": "+err.Error(), http.StatusBadGateway)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// serve-layer timeout: bound the spawn/readiness wait so a backend that
		// won't come up (or, in the general case, a hung force) yields a 504
		// instead of wedging this goroutine forever.
		ctx, cancel := context.WithTimeout(r.Context(), serveWaitTimeout+5*time.Second)
		defer cancel()
		if err := ensureServeBackend(ctx, st, serviceID, cwd, launch, internalPort, idleMs); err != nil {
			http.Error(w, "bosun serve: "+serviceID+" did not come up: "+err.Error(), http.StatusGatewayTimeout)
			return
		}
		bumpServeIdle(st, idleMs)
		proxy.ServeHTTP(w, r)
	})

	srv := &http.Server{
		Addr:              fmt.Sprintf("%s:%d", serveInternalHost, publicPort),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		fmt.Printf("  bound :%d → %s (backend %d)\n", publicPort, serviceID, internalPort)
		if err := srv.ListenAndServe(); err != nil {
			fmt.Printf("  ✗ :%d %s\n", publicPort, err)
		}
	}()
}

// Lazy-spawn the backend on first request; concurrent first-requests single-
// flight on the mutex (only the first spawns, the rest wait then reuse).
func ensureServeBackend(ctx context.Context, st *serveRoute, serviceID, cwd, launch string, internalPort, idleMs int) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.up {
		return nil
	}
	fmt.Printf("  ⟳ spawn %s: %s (cwd %s)\n", serviceID, launch, cwd)
	logf, _ := os.OpenFile("/tmp/bosun-serve-"+sanitizeServe(serviceID)+".log",
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	cmd := exec.Command("bash", "-c", launch)
	cmd.Dir = cwd
	if logf != nil {
		cmd.Stdout = logf
		cmd.Stderr = logf
	}
	// own process group, so idle-reap can SIGTERM the whole tree (bash -c may
	// fork a child that a bare kill wouldn't reach).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	st.cmd = cmd
	go func() {
		cmd.Wait()
		st.mu.Lock()
		if st.cmd == cmd {
			st.up = false
			st.cmd = nil
			if st.idleTimer != nil {
				st.idleTimer.Stop()
			}
		}
		st.mu.Unlock()
		fmt.Printf("  ⏹ %s exited\n", serviceID)
	}()
	if err := waitForServePort(ctx, internalPort); err != nil {
		return err
	}
	fmt.Printf("  ✓ %s listening on :%d\n", serviceID, internalPort)
	st.up = true
	st.idleTimer = time.AfterFunc(time.Duration(idleMs)*time.Millisecond, func() { reapServe(st, serviceID) })
	return nil
}

func waitForServePort(ctx context.Context, port int) error {
	addr := fmt.Sprintf("%s:%d", serveInternalHost, port)
	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for :%d", port)
		default:
		}
		conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func bumpServeIdle(st *serveRoute, idleMs int) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.idleTimer != nil {
		st.idleTimer.Reset(time.Duration(idleMs) * time.Millisecond)
	}
}

func reapServe(st *serveRoute, serviceID string) {
	st.mu.Lock()
	cmd := st.cmd
	st.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		fmt.Printf("  ⏏ %s idle — SIGTERM\n", serviceID)
		syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}

func sanitizeServe(s string) string {
	return strings.NewReplacer(":", "-", "/", "-").Replace(s)
}
