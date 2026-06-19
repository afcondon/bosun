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
	"net/http"
	"strings"
	"sync"
	"time"
)

const residentInternalHost = "127.0.0.1"

// serialises ALL PS-callback invocations, so the single-threaded Effect/Ref
// runtime is never entered concurrently (node-fidelity, see header).
var residentMu sync.Mutex

// nowMs :: Effect Number — a `func() any` thunk (wall-clock ms, like Date.now()).
var Bosun_CLI_Resident_nowMs any = func() any { return float64(time.Now().UnixMilli()) }

// residentImpl :: EffectFn1 Resident Unit — called once; runs forever (resident).
var Bosun_CLI_Resident_residentImpl any = func(args ...any) any {
	cfg := _force(args[0]).(map[string]any)
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
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method == http.MethodGet && (r.URL.Path == "/state" || r.URL.Path == "/") {
			residentMu.Lock()
			body := stateBody().(string)
			residentMu.Unlock()
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
			residentMu.Lock()
			msg := control(verb, arg).(string)
			residentMu.Unlock()
			w.Header().Set("content-type", "application/json")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `{"ok":true,"message":%q}`, msg)
			return
		}
		w.Header().Set("content-type", "text/plain")
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, "not found\n")
	})

	srv := &http.Server{
		Addr:              fmt.Sprintf("%s:%d", residentInternalHost, statusPort),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	fmt.Printf("  resident: /state + /control on :%d, tick %dms. Ctrl-C to stop.\n", statusPort, intervalMs)
	if err := srv.ListenAndServe(); err != nil {
		fmt.Printf("  ✗ resident :%d %v\n", statusPort, err)
	}
	return nil
}
