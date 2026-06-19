// Bosun's hand-written Go twin of cli/src/Bosun/CLI/Serve.js — the REAL
// `Bosun_CLI_Serve_serveImpl`, so the gnomon-bosun binary serves Node-free. The
// Go port of the lazy-spawn reverse proxy, driven by the SAME pure ServePlan the
// node shim consumes: PureScript decides admission / port-rewrite / idle policy /
// reload-diff; this shim does the mechanical bind / spawn / poll / proxy / reap.
// APP-SPECIFIC; copied into the gnomon-bosun build by scripts/gnomon-bosun.sh.
//
// Parity with Serve.js: routes are bound on their public port and lazy-spawned
// (single-flight) on first request, reverse-proxied to the internal port, and
// idle-reaped; an EADDRINUSE bind is ADOPTED (served externally) not failed; a
// route's WebSocket upgrades ride httputil.ReverseProxy (Go ≥1.12 bridges them).
// Redirects bind + answer 421 → tailnet URL. A /state + /control endpoint mirrors
// the node shim, and SIGHUP / POST /control/reload call the pure `reload` callback
// (Effect ServeDiff) and apply the typed diff (unbind → rebind).
//
// backend-go ABI: EffectFn1 → func(args ...any) any; a bare `Effect a` (here the
// `reload` field) → a `func() any` thunk; records are map[string]any, arrays
// []any, Int/String Go int/string; nested values may be thunks → _force first.
// PS-callback (reload) invocations are serialised under one mutex (node-fidelity:
// the single-threaded Effect/Ref runtime must never be entered concurrently).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

const cliServeHost = "127.0.0.1"
const cliServeWaitTimeout = 30 * time.Second

type cliRoute struct {
	serviceID, cwd, launch        string
	publicPort, internalPort, idle int

	mu        sync.Mutex
	up        bool
	external  bool
	cmd       *exec.Cmd
	idleTimer *time.Timer
}

type cliListener struct {
	ln       net.Listener
	srv      *http.Server
	route    *cliRoute      // nil for a redirect
	redirect map[string]any // {serviceId,host,target} for /state; nil for a route
}

var (
	cliCbMu    sync.Mutex                 // serialises reload() (the PS callback)
	cliMu      sync.Mutex                 // guards the maps below
	cliByPort  = map[int]*cliListener{}
	cliRoutes  []*cliRoute
)

// serveImpl :: EffectFn1 ServeConfig Unit  (resident — never returns)
var Bosun_CLI_Serve_serveImpl any = func(args ...any) any {
	cfg := _force(args[0]).(map[string]any)
	statusPort := _force(cfg["statusPort"]).(int)
	rejected := _force(cfg["rejected"]).([]any)
	reload := _force(cfg["reload"]).(func() any)

	for _, r := range _force(cfg["routes"]).([]any) {
		cliBindRoute(_force(r).(map[string]any))
	}
	for _, rd := range _force(cfg["redirects"]).([]any) {
		cliBindRedirect(_force(rd).(map[string]any))
	}

	if statusPort != 0 {
		go cliStatusServer(statusPort, rejected, reload)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP)
	go func() {
		for range sig {
			fmt.Println("  ↻ SIGHUP — reloading")
			cliApplyReload(reload)
		}
	}()

	select {} // resident
}

func cliBindRoute(route map[string]any) {
	st := &cliRoute{
		serviceID:    _force(route["serviceId"]).(string),
		cwd:          _force(route["cwd"]).(string),
		launch:       _force(route["launchCommand"]).(string),
		publicPort:   _force(route["publicPort"]).(int),
		internalPort: _force(route["internalPort"]).(int),
		idle:         _force(route["idleTimeoutMs"]).(int),
	}
	target, _ := url.Parse(fmt.Sprintf("http://%s:%d", cliServeHost, st.internalPort))
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		http.Error(w, "bosun serve: proxy error for "+st.serviceID+": "+err.Error(), http.StatusBadGateway)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), cliServeWaitTimeout+5*time.Second)
		defer cancel()
		if err := cliEnsureBackend(ctx, st); err != nil {
			http.Error(w, "bosun serve: "+st.serviceID+" did not come up: "+err.Error(), http.StatusGatewayTimeout)
			return
		}
		cliBumpIdle(st)
		proxy.ServeHTTP(w, r)
	})
	addr := fmt.Sprintf("%s:%d", cliServeHost, st.publicPort)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		if strings.Contains(err.Error(), "address already in use") {
			st.external = true
			cliMu.Lock()
			cliRoutes = append(cliRoutes, st)
			cliByPort[st.publicPort] = &cliListener{route: st} // adopted: no server
			cliMu.Unlock()
			fmt.Printf("  ≈ :%d already served externally (adopted) — %s\n", st.publicPort, st.serviceID)
			return
		}
		fmt.Printf("  ✗ cannot bind :%d (%s) — %s unserved\n", st.publicPort, err, st.serviceID)
		return
	}
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	cliMu.Lock()
	cliRoutes = append(cliRoutes, st)
	cliByPort[st.publicPort] = &cliListener{ln: ln, srv: srv, route: st}
	cliMu.Unlock()
	fmt.Printf("  bound :%d → %s (idle %ds)\n", st.publicPort, st.serviceID, st.idle/1000)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			fmt.Printf("  ✗ :%d %s\n", st.publicPort, err)
		}
	}()
}

func cliBindRedirect(rd map[string]any) {
	serviceID := _force(rd["serviceId"]).(string)
	host := _force(rd["host"]).(string)
	target := _force(rd["target"]).(string)
	publicPort := _force(rd["publicPort"]).(int)
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/plain")
		w.Header().Set("location", target+r.URL.RequestURI())
		w.WriteHeader(421)
		fmt.Fprintf(w, "bosun serve: %s runs on %s. Use %s%s\n", serviceID, host, target, r.URL.RequestURI())
	})
	addr := fmt.Sprintf("%s:%d", cliServeHost, publicPort)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Printf("  ✗ cannot bind redirect :%d (%s)\n", publicPort, err)
		return
	}
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	cliMu.Lock()
	cliByPort[publicPort] = &cliListener{ln: ln, srv: srv, redirect: map[string]any{"serviceId": serviceID, "host": host, "target": target}}
	cliMu.Unlock()
	fmt.Printf("  bound :%d → 421 → %s (%s on %s)\n", publicPort, target, serviceID, host)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			fmt.Printf("  ✗ redirect :%d %s\n", publicPort, err)
		}
	}()
}

// Single-flight lazy-spawn: the first request for a down backend spawns it under
// the route mutex; concurrent requests wait, then reuse.
func cliEnsureBackend(ctx context.Context, st *cliRoute) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.up || st.external {
		return nil
	}
	fmt.Printf("  ⟳ spawn %s: %s (cwd %s)\n", st.serviceID, st.launch, st.cwd)
	logf, _ := os.OpenFile("/tmp/bosun-serve-"+cliSanitize(st.serviceID)+".log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	cmd := exec.Command("bash", "-c", st.launch)
	cmd.Dir = st.cwd
	if logf != nil {
		cmd.Stdout, cmd.Stderr = logf, logf
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // own group so idle-reap kills the tree
	if err := cmd.Start(); err != nil {
		return err
	}
	st.cmd = cmd
	go func() {
		cmd.Wait()
		st.mu.Lock()
		if st.cmd == cmd {
			st.up, st.cmd = false, nil
			if st.idleTimer != nil {
				st.idleTimer.Stop()
			}
		}
		st.mu.Unlock()
		fmt.Printf("  ⏹ %s exited\n", st.serviceID)
	}()
	if err := cliWaitForPort(ctx, st.internalPort); err != nil {
		return err
	}
	fmt.Printf("  ✓ %s listening on :%d\n", st.serviceID, st.internalPort)
	st.up = true
	st.idleTimer = time.AfterFunc(time.Duration(st.idle)*time.Millisecond, func() { cliReap(st) })
	return nil
}

func cliWaitForPort(ctx context.Context, port int) error {
	addr := fmt.Sprintf("%s:%d", cliServeHost, port)
	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for :%d", port)
		default:
		}
		if conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond); err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func cliBumpIdle(st *cliRoute) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.idleTimer != nil {
		st.idleTimer.Reset(time.Duration(st.idle) * time.Millisecond)
	}
}

func cliReap(st *cliRoute) {
	st.mu.Lock()
	cmd := st.cmd
	st.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		fmt.Printf("  ⏏ %s idle %ds — SIGTERM\n", st.serviceID, st.idle/1000)
		syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}

// Close a listener (and kill any backend behind it), releasing the port so a
// same-port rebind in the same reload can't EADDRINUSE.
func cliUnbindPort(port int) {
	cliMu.Lock()
	l := cliByPort[port]
	delete(cliByPort, port)
	if l != nil && l.route != nil {
		for i, st := range cliRoutes {
			if st == l.route {
				cliRoutes = append(cliRoutes[:i], cliRoutes[i+1:]...)
				break
			}
		}
	}
	cliMu.Unlock()
	if l == nil {
		return
	}
	if l.route != nil {
		l.route.mu.Lock()
		if l.route.cmd != nil && l.route.cmd.Process != nil {
			syscall.Kill(-l.route.cmd.Process.Pid, syscall.SIGTERM)
		}
		if l.route.idleTimer != nil {
			l.route.idleTimer.Stop()
		}
		l.route.mu.Unlock()
	}
	if l.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		l.srv.Shutdown(ctx)
	}
	fmt.Printf("  ⊘ unbound :%d\n", port)
}

// Call the pure `reload` (Effect ServeDiff) and apply the typed diff. Serialised
// under cliCbMu so the single-threaded PS Effect/Ref runtime is never re-entered
// concurrently (node-fidelity).
func cliApplyReload(reload func() any) {
	cliCbMu.Lock()
	defer cliCbMu.Unlock()
	diff := _force(reload()).(map[string]any)
	for _, p := range _force(diff["unbind"]).([]any) {
		cliUnbindPort(_force(p).(int))
	}
	for _, r := range _force(diff["bindRoutes"]).([]any) {
		cliBindRoute(_force(r).(map[string]any))
	}
	for _, rd := range _force(diff["bindRedirects"]).([]any) {
		cliBindRedirect(_force(rd).(map[string]any))
	}
	fmt.Println("  ↻ reload applied")
}

func cliStatusServer(port int, rejected []any, reload func() any) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("access-control-allow-origin", "*")
		w.Header().Set("access-control-allow-methods", "GET,POST,OPTIONS")
		w.Header().Set("access-control-allow-headers", "*")
		switch {
		case r.Method == http.MethodOptions:
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodGet && (r.URL.Path == "/state" || r.URL.Path == "/"):
			cliWriteJSON(w, 200, cliStateBody(rejected))
		case r.Method == http.MethodPost && r.URL.Path == "/control/reload":
			cliApplyReload(reload)
			cliWriteJSON(w, 200, map[string]any{"ok": true})
		case r.Method == http.MethodPost && (r.URL.Path == "/control/spawn" || r.URL.Path == "/control/stop"):
			cliControlOne(w, r)
		default:
			cliWriteJSON(w, 404, map[string]any{"ok": false, "error": "not found"})
		}
	})
	srv := &http.Server{Addr: fmt.Sprintf("%s:%d", cliServeHost, port), Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	fmt.Printf("  /state + /control on :%d\n", port)
	if err := srv.ListenAndServe(); err != nil {
		fmt.Printf("  ✗ /state :%d %s\n", port, err)
	}
}

func cliControlOne(w http.ResponseWriter, r *http.Request) {
	port := 0
	fmt.Sscanf(r.URL.Query().Get("port"), "%d", &port)
	cliMu.Lock()
	l := cliByPort[port]
	cliMu.Unlock()
	if l == nil || l.route == nil {
		cliWriteJSON(w, 404, map[string]any{"ok": false, "error": fmt.Sprintf("no proxy route on :%d", port)})
		return
	}
	if strings.HasSuffix(r.URL.Path, "/stop") {
		cliReap(l.route)
		cliWriteJSON(w, 200, map[string]any{"ok": true, "serviceId": l.route.serviceID, "up": false})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), cliServeWaitTimeout+5*time.Second)
	defer cancel()
	if err := cliEnsureBackend(ctx, l.route); err != nil {
		cliWriteJSON(w, 502, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	cliWriteJSON(w, 200, map[string]any{"ok": true, "serviceId": l.route.serviceID, "up": true})
}

func cliStateBody(rejected []any) map[string]any {
	cliMu.Lock()
	defer cliMu.Unlock()
	routes := make([]any, 0, len(cliRoutes))
	for _, st := range cliRoutes {
		st.mu.Lock()
		pid := any(nil)
		if st.cmd != nil && st.cmd.Process != nil {
			pid = st.cmd.Process.Pid
		}
		routes = append(routes, map[string]any{
			"serviceId": st.serviceID, "publicPort": st.publicPort, "internalPort": st.internalPort,
			"up": st.external || st.up, "external": st.external, "pid": pid,
		})
		st.mu.Unlock()
	}
	redirects := make([]any, 0)
	for port, l := range cliByPort {
		if l.redirect != nil {
			rd := map[string]any{"publicPort": port}
			for k, v := range l.redirect {
				rd[k] = v
			}
			redirects = append(redirects, rd)
		}
	}
	rej := make([]any, 0, len(rejected))
	for _, x := range rejected {
		rej = append(rej, _force(x))
	}
	return map[string]any{"routes": routes, "redirects": redirects, "rejected": rej}
}

func cliWriteJSON(w http.ResponseWriter, code int, obj any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(code)
	b, _ := json.MarshalIndent(obj, "", "  ")
	w.Write(append(b, '\n'))
}

func cliSanitize(s string) string {
	return strings.NewReplacer(":", "-", "/", "-").Replace(s)
}
