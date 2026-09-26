// Bosun's hand-written Go twin of cli/src/Bosun/CLI/Resident.js — the resident-
// mode shim (docs/EXECUTORS.md): the watch-loop ticker + the /state + /control
// HTTP surface that keeps the Chair executor-agnostic. It provides the REAL CLI
// foreign symbols `Bosun_CLI_Resident_residentImpl` / `_nowMs`, driven by the
// SAME pure `Resident` record the node shim consumes — so a backend-go build of
// `bosun docker` (or, later, `supervise`) IS a native resident daemon. This is
// the Go column's exercise of the foreign-calls-back-into-PureScript direction
// (a Go shim invoking the `tick`/`stateBody`/`control` Effect closures).
// APP-SPECIFIC; copied into the build dir by scripts/go-docker.sh.
//
// NODE-FIDELITY (the load-bearing subtlety): node runs JS callbacks on a single
// event loop, so the tick and the HTTP handlers never execute the PureScript
// Effect closures concurrently. Go's net/http is goroutine-per-request and the
// ticker is its own goroutine, so without care they'd invoke tick/stateBody/
// control in PARALLEL — and Effect.Ref in the backend-go runtime is a bare map
// with no lock (a data race). So we serialise every PS-callback invocation under
// ONE mutex, recovering node's single-threaded effect execution. (Resident-mode
// analog of the per-route mutex the serve foreign uses.)
//
// backend-go ABI: a bare `Effect a` value is a `func() any` thunk (run by
// calling it); an `EffectFn2` (from mkEffectFn2) is a variadic `func(...any) any`
// taking its 2 args and returning the already-run result; record fields may be
// thunks, so each is _force'd before the type assertion. A `Number` is float64.
package main

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// serialises ALL PS-callback invocations, so the single-threaded Effect/Ref
// runtime is never entered concurrently (node-fidelity, see header).
var residentMu sync.Mutex

// nowMs :: Effect Number — a `func() any` thunk (wall-clock ms, like Date.now()).
var Bosun_CLI_Resident_nowMs any = func() any { return float64(time.Now().UnixMilli()) }

// residentImpl :: EffectFn3 String (Fn3 String String String Boolean) Resident
// Unit — called once; runs forever (resident). args[0] is the bind address,
// args[1] the pure PS admission decision (Bosun.CLI.Resident.admits, an Fn3
// over peer, method, path), args[2] the Resident record.
var Bosun_CLI_Resident_residentImpl any = func(args ...any) any {
	bindHost := _force(args[0]).(string)
	admits := _force(args[1]).(func(...any) any)
	cfg := _force(args[2]).(map[string]any)
	statusPort := _force(cfg["statusPort"]).(int)
	intervalMs := _force(cfg["intervalMs"]).(int)
	tick := _force(cfg["tick"]).(func() any)
	stateBody := _force(cfg["stateBody"]).(func() any)
	control := _force(cfg["control"]).(func(...any) any)

	// periodic tick; serialised against the HTTP handlers. The initial bring-up/
	// observe already ran in PS before runResident, exactly as the node shim.
	go func() {
		t := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
		defer t.Stop()
		for range t.C {
			func() {
				defer func() {
					if r := recover(); r != nil {
						fmt.Printf("  ✗ tick: %v\n", r)
					}
				}()
				residentMu.Lock()
				defer residentMu.Unlock()
				tick()
			}()
		}
	}()

	cors := func(w http.ResponseWriter) {
		h := w.Header()
		h.Set("access-control-allow-origin", "*")
		h.Set("access-control-allow-methods", "GET,POST,OPTIONS")
		h.Set("access-control-allow-headers", "content-type")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		cors(w)
		// Same order as Resident.js: admission before anything else. The peer
		// is the host part of RemoteAddr, as node's socket.remoteAddress is.
		peer, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			peer = r.RemoteAddr
		}
		if allowed, _ := admits(peer, r.Method, r.URL.Path).(bool); !allowed {
			w.Header().Set("content-type", "text/plain")
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprint(w, "forbidden: /state is tailnet-readable at most; /control is local-only\n")
			return
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method == http.MethodGet && (r.URL.Path == "/state" || r.URL.Path == "/") {
			// `defer` inside a closure, not a bare Unlock: a panic anywhere in
			// the PureScript effect used to escape with `residentMu` STILL HELD,
			// and net/http recovers per-connection — so the daemon went on
			// listening while every later /state and /control blocked forever on
			// the lock. That is how a type error in the line below (see the
			// /control branch) presented as a hang rather than a crash.
			body := func() string {
				residentMu.Lock()
				defer residentMu.Unlock()
				return stateBody().(string)
			}()
			w.Header().Set("content-type", "application/json")
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, body)
			return
		}
		if r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/control/") {
			verb := strings.TrimPrefix(r.URL.Path, "/control/")
			arg := r.URL.Query().Get("service")
			if arg == "" {
				arg = r.URL.Query().Get("group")
			}
			// `Bosun.CLI.Resident.ControlResult` stopped being a bare String on
			// 2026-08-17 (b45bb21) and became `{ ok :: Boolean, message ::
			// String }`, precisely so a refusal could not be laundered into a
			// confirmation by the shim. Resident.js was updated; THIS column was
			// not, and `control(...).(string)` panicked on every control verb —
			// then wedged the daemon on the un-deferred mutex above. Nothing
			// could tell: control-parity.sh reads the ROUTER shims, not this one,
			// and menagerie-conf.sh is the only thing that POSTs here.
			res := func() map[string]any {
				residentMu.Lock()
				defer residentMu.Unlock()
				return control(verb, arg).(map[string]any)
			}()
			ok, _ := res["ok"].(bool)
			msg, _ := res["message"].(string)
			status := http.StatusOK
			if !ok {
				status = http.StatusBadRequest
			}
			w.Header().Set("content-type", "application/json")
			w.WriteHeader(status)
			fmt.Fprintf(w, `{"ok":%t,"message":%q}`, ok, msg)
			return
		}
		w.Header().Set("content-type", "text/plain")
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, "not found\n")
	})

	srv := &http.Server{
		Addr:              net.JoinHostPort(bindHost, fmt.Sprint(statusPort)),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	fmt.Printf("  resident: /state + /control on %s:%d, tick %dms. Ctrl-C to stop.\n", bindHost, statusPort, intervalMs)
	if err := srv.ListenAndServe(); err != nil {
		fmt.Printf("  ✗ resident :%d %v\n", statusPort, err)
	}
	return nil
}
