// Bosun's hand-written Go twin of cli/src/Bosun/CLI/Serve.js — the REAL
// `Bosun_CLI_Serve_serveImpl`, so the gnomon-bosun binary serves Node-free. The
// Go port of the lazy-spawn reverse proxy, driven by the SAME pure ServePlan the
// node shim consumes: PureScript decides admission / port-rewrite / idle policy /
// reload-diff / the stop verdict; this shim does the mechanical bind / spawn /
// poll / proxy / probe / reap. APP-SPECIFIC; copied into the gnomon-bosun build
// by scripts/gnomon-bosun.sh.
//
// Parity with Serve.js: routes are bound on their public port and lazy-spawned
// (single-flight) on first request, reverse-proxied to the internal port, and
// idle-reaped; an EADDRINUSE bind is ADOPTED (served externally) not failed; a
// route's WebSocket upgrades ride httputil.ReverseProxy (Go ≥1.12 bridges them).
// Redirects bind + answer 421 → tailnet URL. BROKERED services are ensured and
// located, never relayed: a 307 on the registered port when the plan could move
// the service off it, `GET /where` always. A /state + /control endpoint mirrors
// the node shim, and SIGHUP / POST /control/reload call the pure `reload`
// callback (Effect ServeDiff) and apply the typed diff (unbind → rebind).
//
// ── THE CONTROL SURFACE IS TWO-COLUMN ───────────────────────────────────────
// Every verb this file answers must also be answered by cli/src/Bosun/CLI/
// Serve.js, and vice versa. That is not a convention, it is checked:
// `scripts/control-parity.sh` extracts the dispatched verbs from BOTH sources
// and refuses to agree that a verb one column serves and the other 404s is a
// finished feature. Broker mode was built entirely on the node side and nobody
// noticed for a week; the check exists so the next one is loud.
//
// backend-go ABI: EffectFn1 → func(args ...any) any; a bare `Effect a` (the
// `reload` / `drift` fields) → a `func() any` thunk; an `FnN` (the `stopVerdict`
// / `whereJson` fields) → a variadic `func(...any) any`; records are
// map[string]any, arrays []any, Int/String Go int/string, `Nullable a` either
// the value or nil; nested values may be thunks → _force first. PS-callback
// invocations are serialised under one mutex (node-fidelity: the
// single-threaded Effect/Ref runtime must never be entered concurrently).
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
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const cliServeHost = "127.0.0.1"
const cliServeWaitTimeout = 30 * time.Second

// A one-shot "is anything listening?" — the evidence behind every `up` this
// router reports about a process it did not spawn.
const cliProbeTimeout = 750 * time.Millisecond
const cliWaitPoll = 100 * time.Millisecond

// SIGTERM → SIGKILL, and how long after that we stop waiting. Kept under the
// callers' HTTP budgets (chair-server reloads with `curl --max-time 8`), because
// a reload that unbinds a live route waits here.
const cliStopGrace = 3 * time.Second
const cliStopGiveup = 1500 * time.Millisecond

type cliRoute struct {
	serviceID, cwd, launch         string
	publicPort, internalPort, idle int

	mu        sync.Mutex
	up        bool
	external  bool
	bound     bool
	bindErr   any // string, or nil when there is nothing wrong
	cmd       *exec.Cmd
	exited    chan struct{} // closed when `cmd` has actually gone
	idleTimer *time.Timer
}

// A BROKERED service. Everything the router needs to ensure it is running and
// then say where it is — and NOT an idle timer, because there is no such thing
// here: a brokered service was started deliberately and holds something (a
// device, a multicast group, a socket file). Reaping it because no request
// arrived is the failure broker mode exists to prevent.
type cliBrokerSpec struct {
	serviceID, cwd, launch string
	publicPort             *int // the 307 door; nil for most brokers, which is normal
	transport              string
	host                   *string
	port                   *int
	path                   *string
	url                    *string
	probe                  string // tcp | socket | none
	probePort              *int
	probePath              *string
	// `Bosun.Serve.brokerStopVerdict`, closed over this row's typed `Probe`.
	// The shim gathers the evidence (do we hold the child, did the probe pass);
	// the CORE weighs it, so both columns reach the same four-way answer from
	// one tested rule rather than from two if-chains at two edges.
	stopVerdict func(...any) any
}

type cliBroker struct {
	// `opMu` serialises the OPERATIONS (ensure, stop) so a spawn is single-flight
	// and a stop in flight is waited on. `mu` guards the fields, and is held only
	// for reads/writes — never across a 4.5s stop, or /state would block behind
	// one.
	opMu sync.Mutex
	mu   sync.Mutex

	spec      cliBrokerSpec
	cmd       *exec.Cmd
	exited    chan struct{}
	bound     bool
	bindErr   any
	spawnFail bool // the last ensure could not start it; retry on the next ask
}

type cliListener struct {
	ln       net.Listener
	srv      *http.Server
	route    *cliRoute      // nil unless this port is a proxy route
	broker   *cliBroker     // nil unless this port is a broker's 307 door
	redirect map[string]any // {serviceId,host,target} for /state; nil otherwise
}

var (
	cliCbMu   sync.Mutex // serialises reload()/drift() (the PS callbacks)
	cliMu     sync.Mutex // guards the maps below
	cliByPort = map[int]*cliListener{}
	cliRoutes []*cliRoute
	// Brokers are keyed by serviceId, NOT by port — half of them have no port to
	// be keyed by (a unix-socket daemon, a UDP fan-out), which is exactly the
	// class broker mode exists for. `cliBrokerOrder` keeps /state's array stable
	// across calls; Go map iteration is randomised and a control surface whose
	// answer reshuffles between polls is unreadable beside the node column's.
	cliBrokers     = map[string]*cliBroker{}
	cliBrokerOrder []string

	// Set once at startup from the ServeConfig, then read by the status server.
	cliWhereJSON  func(...any) any
	cliDrift      func() any
	cliSource     string
	cliSourceFile string
	// REFRESHED BY RELOAD. Captured once, a row that became unroutable while the
	// router was resident appears in no bucket of /state at all — invisible
	// rather than refused, which is half of how a registered service went missing
	// for three days (docs/CONTROL-SURFACE.md, 2026-08-17).
	cliRejected  []any
	cliPlannedAt string
	// why the last drift check could not be MADE, or nil. A check that failed is
	// not a check that found agreement, and silence there reads as agreement.
	cliRegistryError any
)

// serveImpl :: EffectFn1 ServeConfig Unit  (resident — never returns)
var Bosun_CLI_Serve_serveImpl any = func(args ...any) any {
	cfg := _force(args[0]).(map[string]any)
	statusPort := _force(cfg["statusPort"]).(int)
	cliRejected = _force(cfg["rejected"]).([]any)
	cliSource = cliString(cfg["source"])
	cliSourceFile = cliString(cfg["sourceFile"])
	cliPlannedAt = cliNow()
	reload := _force(cfg["reload"]).(func() any)
	cliReloadFn = reload
	if d, ok := _force(cfg["drift"]).(func() any); ok {
		cliDrift = d
	}
	if w, ok := _force(cfg["whereJson"]).(func(...any) any); ok {
		cliWhereJSON = w
	}

	for _, r := range _force(cfg["routes"]).([]any) {
		cliBindRoute(_force(r).(map[string]any))
	}
	for _, b := range _force(cfg["brokers"]).([]any) {
		cliBindBroker(_force(b).(map[string]any))
	}
	for _, rd := range _force(cfg["redirects"]).([]any) {
		cliBindRedirect(_force(rd).(map[string]any))
	}

	if statusPort != 0 {
		go cliStatusServer(statusPort)
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

// ── proxy routes ─────────────────────────────────────────────────────────────

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
		st.bindErr = err.Error()
		fmt.Printf("  ✗ cannot bind :%d (%s) — %s unserved\n", st.publicPort, err, st.serviceID)
		return
	}
	st.bound = true
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
	cmd, exited, err := cliSpawn(st.serviceID, st.cwd, st.launch)
	if err != nil {
		return err
	}
	st.cmd, st.exited = cmd, exited
	go func() {
		<-exited
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
		time.Sleep(cliWaitPoll)
	}
}

func cliBumpIdle(st *cliRoute) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.idleTimer != nil {
		st.idleTimer.Reset(time.Duration(st.idle) * time.Millisecond)
	}
}

// Stop a PROXIED backend, and answer only when it is actually DOWN. Treating a
// stop as instantaneous is a belief about the world stated one signal too early:
// the process can still hold its internal port, and a Chair "reboot" (stop then
// spawn) would then race it.
func cliStopBackend(st *cliRoute) (had bool, exited bool) {
	st.mu.Lock()
	if st.idleTimer != nil {
		st.idleTimer.Stop()
	}
	cmd, done := st.cmd, st.exited
	st.cmd, st.up = nil, false
	st.mu.Unlock()
	return cliSignalAndAwait(cmd, done, st.serviceID)
}

func cliReap(st *cliRoute) {
	st.mu.Lock()
	live := st.cmd != nil
	st.mu.Unlock()
	if live {
		fmt.Printf("  ⏏ %s idle %ds — SIGTERM\n", st.serviceID, st.idle/1000)
		cliStopBackend(st)
	}
}

// ── broker mode (BOSUN-SERVE.md §3c, docs/ENSURE-AND-LOCATE.md) ──────────────
//
// The router ensures the service is running and says WHERE it is; it never
// touches the traffic. Register the entry (what `/where` answers from) and, IF
// the plan could move the service off its registered port, hold that port so a
// caller who dialled the old address is told where to go instead — and so that
// dialling it is still what triggers the spawn.
//
// A broker with no public port binds nothing at all. That is not a degraded
// case: es9-daemon is reached at `~/.es9/control.sock` and link-spike over UDP
// multicast, and for those `/where` is the only door there could be.

func cliRegisterBroker(b map[string]any) *cliBroker {
	spec := cliBrokerSpec{
		serviceID:  _force(b["serviceId"]).(string),
		cwd:        _force(b["cwd"]).(string),
		launch:     _force(b["launchCommand"]).(string),
		publicPort: cliOptInt(b["publicPort"]),
		transport:  _force(b["transport"]).(string),
		host:       cliOptStr(b["host"]),
		port:       cliOptInt(b["port"]),
		path:       cliOptStr(b["path"]),
		url:        cliOptStr(b["url"]),
		probe:      _force(b["probe"]).(string),
		probePort:  cliOptInt(b["probePort"]),
		probePath:  cliOptStr(b["probePath"]),
	}
	if sv, ok := _force(b["stopVerdict"]).(func(...any) any); ok {
		spec.stopVerdict = sv
	}
	cliMu.Lock()
	defer cliMu.Unlock()
	// Carry the live child across a reload that did not change the entry —
	// re-registering must not orphan a running daemon, which for these means an
	// audio interface held by a process nobody is tracking any more.
	if existing, ok := cliBrokers[spec.serviceID]; ok && cliSameBroker(existing.spec, spec) {
		existing.mu.Lock()
		existing.spec = spec
		existing.mu.Unlock()
		return existing
	}
	st := &cliBroker{spec: spec}
	if _, seen := cliBrokers[spec.serviceID]; !seen {
		cliBrokerOrder = append(cliBrokerOrder, spec.serviceID)
	}
	cliBrokers[spec.serviceID] = st
	return st
}

func cliBindBroker(b map[string]any) {
	st := cliRegisterBroker(b)
	st.mu.Lock()
	public := st.spec.publicPort
	label := cliLocatorLabel(st.spec)
	sid := st.spec.serviceID
	st.mu.Unlock()
	if public == nil {
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { cliBrokerRedirect(w, r, st) })
	ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", cliServeHost, *public))
	if err != nil {
		// A broker's public port being held externally is the ORDINARY case once
		// the service has been started by hand: it binds its own registered port
		// when nothing moved it off. Say so once and step aside, exactly as the
		// proxy path does — and do NOT record a bindError, because nothing is
		// wrong.
		st.mu.Lock()
		st.bound = false
		if strings.Contains(err.Error(), "address already in use") {
			st.bindErr = nil
			st.mu.Unlock()
			fmt.Printf("  ≈ :%d already held — %s is brokered, so serve steps aside\n", *public, sid)
		} else {
			st.bindErr = err.Error()
			st.mu.Unlock()
			fmt.Printf("  ✗ cannot bind :%d (%s) — %s 307 unavailable\n", *public, err, sid)
		}
		return
	}
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	st.mu.Lock()
	st.bound, st.bindErr = true, nil
	st.mu.Unlock()
	cliMu.Lock()
	cliByPort[*public] = &cliListener{ln: ln, srv: srv, broker: st}
	cliMu.Unlock()
	fmt.Printf("  bound :%d → 307 → %s (%s, brokered — no relay)\n", *public, label, sid)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			fmt.Printf("  ✗ broker :%d %s\n", *public, err)
		}
	}()
}

// The HTTP door onto a brokered service: ensure it, then get out of the way.
// 307 rather than 302/301 because the method and body must survive — a POST that
// silently became a GET on the way to the real service would be a far nastier
// bug than not redirecting at all. The Location is built from the TRANSPORT
// address, not from the row's `url`: this is an HTTP redirect, and telling an
// HTTP client to go to `ws://…` helps nobody.
func cliBrokerRedirect(w http.ResponseWriter, r *http.Request, st *cliBroker) {
	res, err := cliEnsureAndLocate(st)
	spec := cliSpec(st)
	if err != nil {
		w.Header().Set("content-type", "text/plain")
		w.WriteHeader(502)
		fmt.Fprintf(w, "bosun serve: could not ensure %s: %s\n", spec.serviceID, err)
		return
	}
	if spec.transport != "tcp" || spec.port == nil {
		w.Header().Set("content-type", "text/plain")
		w.WriteHeader(503)
		fmt.Fprintf(w, "bosun serve: %s is brokered at %s, which is not an HTTP address.\n"+
			"Ask GET /where/%s on the control port for the real address.\n",
			spec.serviceID, cliLocatorLabel(spec), spec.serviceID)
		return
	}
	target := fmt.Sprintf("http://%s:%d%s", cliDeref(spec.host), *spec.port, r.URL.RequestURI())
	w.Header().Set("location", target)
	w.Header().Set("content-type", "text/plain")
	// The point of broker mode, stated on every answer: bosun is not carrying
	// this traffic, and a client that wants to know before it commits can ask.
	w.Header().Set("x-bosun-mediation", "broker")
	w.Header().Set("x-bosun-ready", strconv.FormatBool(res.ready))
	w.WriteHeader(307)
	fmt.Fprintf(w, "bosun serve: %s is brokered — go direct to %s\n%s\n", spec.serviceID, target, res.detail)
}

type cliLocated struct {
	ready, started bool
	probe, detail  string
}

// ENSURE-AND-LOCATE — the operation, not an HTTP route. `GET /where` is a thin
// adapter over it and `bosun where` a thin client over that.
//
// Three questions, answered in an order that matters:
//
//  1. Is it ALREADY up? Probe first, always. These services are started
//     deliberately and often by hand, and a pre-flight that answers "I started
//     it" when it was already running is the wrong answer to the question asked.
//  2. If not, start it — once, single-flight, as the proxy path does.
//  3. Did it become ready? Wait for the probe the PLAN chose, and report which
//     one was made. `probe: "none"` means NOTHING WAS CHECKED, never that a
//     check failed.
//
// The wait happens BEFORE the answer is sent; that is the whole contract.
func cliEnsureAndLocate(st *cliBroker) (cliLocated, error) {
	st.opMu.Lock()
	defer st.opMu.Unlock()
	spec := cliSpec(st)
	if cliProbeBroker(spec) {
		return cliLocated{true, false, spec.probe, "already running; " + cliProbeSentence(spec) + " passed"}, nil
	}
	st.mu.Lock()
	child := st.cmd
	st.mu.Unlock()
	if spec.probe == "none" && child != nil {
		// Started by us, and nothing about it is checkable. Say exactly that.
		return cliLocated{false, false, "none", fmt.Sprintf(
			"started by bosun (pid %d); this service publishes no readiness signal serve can check, "+
				"so \"up\" is not a claim it can make", child.Process.Pid)}, nil
	}
	if err := cliSpawnBroker(st, spec); err != nil {
		return cliLocated{}, err
	}
	ready := cliWaitForBroker(spec)
	detail := "started by bosun; " + cliProbeSentence(spec) + " passed"
	if !ready {
		if spec.probe == "none" {
			detail = "started by bosun; no readiness signal to check, so nothing here says it is up"
		} else {
			detail = fmt.Sprintf("started by bosun, but %s has not passed within %dms",
				cliProbeSentence(spec), int(cliServeWaitTimeout/time.Millisecond))
		}
	}
	return cliLocated{ready, true, spec.probe, detail}, nil
}

// Spawn a broker. Deliberately NOT `cliEnsureBackend`: a broker has no
// internal-port rewrite to respect, no idle timer to bump, and no relay waiting
// on it. Callers hold `opMu`, which is what makes it single-flight.
func cliSpawnBroker(st *cliBroker, spec cliBrokerSpec) error {
	st.mu.Lock()
	live := st.cmd != nil
	st.mu.Unlock()
	if live {
		return nil
	}
	logFile := "/tmp/bosun-serve-" + cliSanitize(spec.serviceID) + ".log"
	fmt.Printf("  ⟳ ensure %s: %s  (cwd %s, log %s)\n", spec.serviceID, spec.launch, spec.cwd, logFile)
	cmd, exited, err := cliSpawn(spec.serviceID, spec.cwd, spec.launch)
	if err != nil {
		return err
	}
	st.mu.Lock()
	st.cmd, st.exited = cmd, exited
	st.mu.Unlock()
	go func() {
		<-exited
		st.mu.Lock()
		if st.cmd == cmd {
			st.cmd = nil
		}
		st.mu.Unlock()
		fmt.Printf("  ⏹ %s exited\n", spec.serviceID)
	}()
	return nil
}

// Poll the plan's readiness probe until it passes or the deadline. `none` waits
// for nothing and claims nothing — there is no check to make, and inventing a
// grace period would be inventing evidence.
func cliWaitForBroker(spec cliBrokerSpec) bool {
	if spec.probe == "none" {
		return false
	}
	deadline := time.Now().Add(cliServeWaitTimeout)
	for {
		if cliProbeBroker(spec) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(cliWaitPoll)
	}
}

// The readiness probe the PLAN chose, made. `tcp` is the same connect the proxy
// path waits on; `socket` is the socket file's existence, which is what
// `Bosun.CLI.Observe`'s `SocketReady` already means.
func cliProbeBroker(spec cliBrokerSpec) bool {
	switch spec.probe {
	case "tcp":
		if spec.probePort != nil {
			return cliProbePort(*spec.probePort)
		}
	case "socket":
		if spec.probePath != nil {
			_, err := os.Stat(*spec.probePath)
			return err == nil
		}
	}
	return false
}

func cliProbePort(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", cliServeHost, port), cliProbeTimeout)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func cliProbeSentence(spec cliBrokerSpec) string {
	switch spec.probe {
	case "tcp":
		if spec.probePort != nil {
			return fmt.Sprintf("a TCP connect to :%d", *spec.probePort)
		}
	case "socket":
		return "the socket " + cliDeref(spec.probePath)
	}
	return "no check"
}

func cliLocatorLabel(spec cliBrokerSpec) string {
	switch spec.transport {
	case "unix":
		return "unix " + cliDeref(spec.path)
	case "none":
		return "(no dialable address)"
	}
	if spec.url != nil && *spec.url != "" {
		return *spec.url
	}
	return fmt.Sprintf("%s %s:%s", spec.transport, cliDeref(spec.host), cliDerefInt(spec.port))
}

// Two broker entries are the SAME entry if everything the router acts on is the
// same. Used on reload to decide whether a running child carries over.
func cliSameBroker(a, b cliBrokerSpec) bool {
	return a.launch == b.launch && a.cwd == b.cwd && a.transport == b.transport &&
		cliDeref(a.host) == cliDeref(b.host) && cliDerefInt(a.port) == cliDerefInt(b.port) &&
		cliDeref(a.path) == cliDeref(b.path) && a.probe == b.probe
}

// Stop a BROKERED daemon. Stopping is the same act on both sides, so it is the
// same function as the proxy path's — duplicating the SIGTERM/grace/SIGKILL/
// await-exit sequence to keep the two visually separate would be duplicating the
// subtle part. Nothing here clears an adoption flag, because a broker keeps
// none: whether this daemon is ours is probed at the moment it is asked.
func cliStopBroker(st *cliBroker) (had bool, exited bool) {
	st.opMu.Lock()
	defer st.opMu.Unlock()
	st.mu.Lock()
	cmd, done := st.cmd, st.exited
	st.cmd = nil
	sid := st.spec.serviceID
	st.mu.Unlock()
	return cliSignalAndAwait(cmd, done, sid)
}

func cliSpec(st *cliBroker) cliBrokerSpec {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.spec
}

// Find a broker the way `/where` keys them: by service id, or by EITHER port it
// is associated with — the registered one (which it may hold, for the 307) and
// the one it actually listens on. Those are usually different, which is the
// whole point of the rewrite, so matching on the registered port alone would
// make `where 8180` miss a service the registry plainly declares on :8180.
func cliFindBroker(id string, port int) *cliBroker {
	cliMu.Lock()
	defer cliMu.Unlock()
	if id != "" {
		return cliBrokers[id]
	}
	for _, sid := range cliBrokerOrder {
		st := cliBrokers[sid]
		if st == nil {
			continue
		}
		spec := st.spec
		if (spec.publicPort != nil && *spec.publicPort == port) || (spec.port != nil && *spec.port == port) {
			return st
		}
	}
	return nil
}

// ── child lifetime ───────────────────────────────────────────────────────────

// Spawn into its OWN process group, so idle-reap and stop can signal the whole
// tree (`bash -c` may fork a child a bare kill would not reach). The returned
// channel is closed when the process has actually gone — the only honest signal
// that a stop finished.
func cliSpawn(serviceID, cwd, launch string) (*exec.Cmd, chan struct{}, error) {
	logf, _ := os.OpenFile("/tmp/bosun-serve-"+cliSanitize(serviceID)+".log",
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	cmd := exec.Command("bash", "-c", launch)
	cmd.Dir = cwd
	if logf != nil {
		cmd.Stdout, cmd.Stderr = logf, logf
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	exited := make(chan struct{})
	go func() {
		cmd.Wait()
		close(exited)
	}()
	return cmd, exited, nil
}

// SIGTERM, then SIGKILL at the grace deadline, and resolve only when the process
// has actually EXITED. `had` distinguishes "there was nothing running" from "it
// stopped", so a caller can report the difference instead of a blanket success.
func cliSignalAndAwait(cmd *exec.Cmd, done <-chan struct{}, label string) (bool, bool) {
	if cmd == nil || cmd.Process == nil {
		return false, true
	}
	cliSignalGroup(cmd, syscall.SIGTERM)
	select {
	case <-done:
		return true, true
	case <-time.After(cliStopGrace):
	}
	fmt.Printf("  ⚑ %s ignored SIGTERM — SIGKILL\n", label)
	cliSignalGroup(cmd, syscall.SIGKILL)
	select {
	case <-done:
		return true, true
	case <-time.After(cliStopGiveup):
		return true, false
	}
}

// Backends are their own process-group leaders, so `-pid` reaches everything
// they started; the direct-kill fallback covers a child already reaped.
func cliSignalGroup(cmd *exec.Cmd, sig syscall.Signal) {
	if err := syscall.Kill(-cmd.Process.Pid, sig); err != nil {
		syscall.Kill(cmd.Process.Pid, sig)
	}
}

// ── reload ───────────────────────────────────────────────────────────────────

// Close a listener (and stop any backend behind it), releasing the port so a
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
		cliStopBackend(l.route)
	}
	// A broker's listener going away does NOT stop the service. The listener only
	// answered "go over there"; the service is on its own address holding
	// whatever it holds, and unbinding a 307 is no reason to take an audio
	// interface away from it.
	if l.broker != nil {
		l.broker.mu.Lock()
		l.broker.bound = false
		l.broker.mu.Unlock()
	}
	if l.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		l.srv.Shutdown(ctx)
	}
	fmt.Printf("  ⊘ unbound :%d\n", port)
}

// Call the pure `reload` (Effect ReloadResult) and apply the typed diff.
// Serialised under cliCbMu so the single-threaded PS Effect/Ref runtime is never
// re-entered concurrently (node-fidelity).
func cliApplyReload(reload func() any) map[string]any {
	cliCbMu.Lock()
	diff := _force(reload()).(map[string]any)
	cliCbMu.Unlock()

	for _, p := range _force(diff["unbind"]).([]any) {
		cliUnbindPort(_force(p).(int))
	}
	for _, r := range _force(diff["bindRoutes"]).([]any) {
		cliBindRoute(_force(r).(map[string]any))
	}
	// Brokers arrive WHOLE, not as a delta: a portless broker owns no listener,
	// so a port-keyed diff can say nothing about it (`Bosun.Serve.ServeDiff`).
	// Refresh every entry — `cliRegisterBroker` keeps a running child across an
	// unchanged one — then drop entries the fresh plan no longer has, WITHOUT
	// stopping them: bosun forgetting about a daemon is not a reason to take its
	// device away.
	brokers := _force(diff["brokers"]).([]any)
	fresh := map[string]bool{}
	for _, b := range brokers {
		fresh[_force(_force(b).(map[string]any)["serviceId"]).(string)] = true
	}
	cliMu.Lock()
	kept := cliBrokerOrder[:0]
	for _, sid := range cliBrokerOrder {
		if fresh[sid] {
			kept = append(kept, sid)
		} else {
			delete(cliBrokers, sid)
		}
	}
	cliBrokerOrder = kept
	cliMu.Unlock()
	for _, b := range brokers {
		cliRegisterBroker(_force(b).(map[string]any))
	}
	for _, b := range _force(diff["bindBrokers"]).([]any) {
		cliBindBroker(_force(b).(map[string]any))
	}
	for _, rd := range _force(diff["bindRedirects"]).([]any) {
		cliBindRedirect(_force(rd).(map[string]any))
	}
	cliRejected = _force(diff["rejected"]).([]any)
	cliPlannedAt = cliNow()
	fmt.Printf("  ↻ reload applied: -%d unbound, +%d proxy, +%d redirect, %d brokered, %d refused\n",
		len(_force(diff["unbind"]).([]any)), len(_force(diff["bindRoutes"]).([]any)),
		len(_force(diff["bindRedirects"]).([]any)), len(brokers), len(cliRejected))
	return diff
}

// ── the control surface ──────────────────────────────────────────────────────
//
// GET /state · GET /where/:service · GET /where?port= · POST /control/reload ·
// POST /control/spawn?port=|?service= · POST /control/stop?port=|?service=.
//
// EVERY VERB HERE IS ALSO A VERB IN cli/src/Bosun/CLI/Serve.js's
// `controlRouter`, and `scripts/control-parity.sh` will fail if that stops being
// true. If you are adding a verb, add it there too — or the check goes red and
// says which column is short.
func cliStatusServer(port int) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("access-control-allow-origin", "*")
		w.Header().Set("access-control-allow-methods", "GET,POST,OPTIONS")
		w.Header().Set("access-control-allow-headers", "*")
		switch {
		case r.Method == http.MethodOptions:
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodGet && (r.URL.Path == "/state" || r.URL.Path == "/"):
			cliWriteJSON(w, 200, cliStateBody())
		case r.Method == http.MethodGet && (r.URL.Path == "/where" || strings.HasPrefix(r.URL.Path, "/where/")):
			cliWhere(w, r)
		case r.Method == http.MethodPost && r.URL.Path == "/control/reload":
			cliControlReload(w)
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

// The reload endpoint answers with the post-reload verdict for EVERY port, not
// just the deltas: "not in boundRoutes" is not the same as "not routed" — an
// unchanged row is already bound.
func cliControlReload(w http.ResponseWriter) {
	cliMu.Lock()
	reload := cliReloadFn
	cliMu.Unlock()
	if reload == nil {
		cliWriteJSON(w, 500, map[string]any{"ok": false, "error": "no reload callback"})
		return
	}
	diff := cliApplyReload(reload)
	after := cliStateBody()
	cliWriteJSON(w, 200, map[string]any{
		"ok":             true,
		"unbound":        _force(diff["unbind"]),
		"boundRoutes":    cliPortsOf(diff["bindRoutes"]),
		"boundRedirects": cliPortsOf(diff["bindRedirects"]),
		// Brokers are NAMED, not numbered. Most hold no public port at all
		// (es9-daemon on a unix socket, link-spike on multicast), so a port-keyed
		// answer says nothing about the ones broker mode exists for — and a
		// reload that ensured four daemons reported as a reload that did nothing.
		"brokers":      cliIdsOf(diff["brokers"]),
		"boundBrokers": cliIdsOf(diff["bindBrokers"]),
		"routes":       cliStatePorts(after, "routes"),
		"redirects":    cliStatePorts(after, "redirects"),
		"rejected":     after["rejected"],
		"drift":        after["drift"],
		"registry":     after["registry"],
	})
}

// GET /where/<serviceId> · GET /where?port=<publicPort>
//
// The thin HTTP adapter over `cliEnsureAndLocate`. It answers for PROXIED routes
// too, and that is deliberate: "where is this service" has an answer either way,
// and `mediation` is how the caller learns whether bosun is in the path. A
// client that must not be relayed (a 30 Hz socket, a UDP endpoint) can then
// refuse to proceed rather than silently accept a hop.
//
// 200 ready · 503 a check was made and FAILED (the address is still returned, so
// the caller can retry) · 404 unknown. `probe: "none"` answers 200 with
// `ready: false`, which looks odd until you read it as the rule the rest of
// Bosun follows: a check we could not make reports UNKNOWN with a reason, never
// a silent coercion to down.
func cliWhere(w http.ResponseWriter, r *http.Request) {
	byPort, _ := strconv.Atoi(r.URL.Query().Get("port"))
	id := ""
	if strings.HasPrefix(r.URL.Path, "/where/") {
		id, _ = url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/where/"))
	}
	answer := func(info map[string]any, code int) {
		if cliWhereJSON == nil {
			cliWriteJSON(w, 500, map[string]any{"ok": false, "error": "no /where encoder"})
			return
		}
		cliWriteJSON(w, code, cliWhereJSON(info))
	}

	if st := cliFindBroker(id, byPort); st != nil {
		spec := cliSpec(st)
		res, err := cliEnsureAndLocate(st)
		if err != nil {
			cliWriteJSON(w, 502, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		code := 503
		if res.ready || res.probe == "none" {
			code = 200
		}
		answer(map[string]any{
			"service": spec.serviceID, "mediation": "broker",
			"ready": res.ready, "started": res.started, "probe": res.probe, "detail": res.detail,
			"transport": spec.transport, "host": cliNullStr(spec.host), "port": cliNullInt(spec.port),
			"path": cliNullStr(spec.path), "url": cliNullStr(spec.url),
		}, code)
		return
	}

	// A proxied route: the honest address is the ROUTER's public port, because
	// that is where the service is reachable — through us. Ensure it for the same
	// reason a broker is ensured, so "where is it" and "is it up" are one question
	// with one answer.
	if st := cliFindRoute(id, byPort); st != nil {
		st.mu.Lock()
		had, external, bound, bindErr := st.cmd != nil, st.external, st.bound, st.bindErr
		st.mu.Unlock()
		locate := func(ready bool, detail string) {
			code := 503
			if ready {
				code = 200
			}
			answer(map[string]any{
				"service": st.serviceID, "mediation": "proxy",
				"ready": ready, "started": ready && !had, "probe": "tcp", "detail": detail,
				"transport": "tcp", "host": cliServeHost, "port": st.publicPort,
				"path": nil, "url": fmt.Sprintf("http://%s:%d", cliServeHost, st.publicPort),
			}, code)
		}
		switch {
		case external:
			locate(true, "held by a process bosun serve did not start; it answers on the public port directly")
		case !bound:
			reason := "not bound"
			if s, ok := bindErr.(string); ok && s != "" {
				reason = s
			}
			locate(false, fmt.Sprintf("the router does not hold :%d (%s), so nothing can reach it", st.publicPort, reason))
		default:
			ctx, cancel := context.WithTimeout(context.Background(), cliServeWaitTimeout+5*time.Second)
			defer cancel()
			if err := cliEnsureBackend(ctx, st); err != nil {
				locate(false, "backend did not come up: "+err.Error())
				return
			}
			started := ""
			if !had {
				started = "; started by this call"
			}
			locate(true, fmt.Sprintf("bosun relays :%d to the backend on :%d%s", st.publicPort, st.internalPort, started))
		}
		return
	}

	if id != "" {
		cliWriteJSON(w, 404, map[string]any{"ok": false,
			"error": fmt.Sprintf("no service '%s' is served here. /state lists what is.", id)})
		return
	}
	asked := "?"
	if byPort != 0 {
		asked = strconv.Itoa(byPort)
	}
	cliWriteJSON(w, 404, map[string]any{"ok": false,
		"error": fmt.Sprintf("no service on :%s. /state lists what is.", asked)})
}

// POST /control/spawn|stop. Ports are identity on this surface and stay so;
// `?service=` is accepted BESIDE them because broker mode created a class of
// service with no port to be identified by at all — es9-daemon is reached at
// `~/.es9/control.sock` — and for those, `/where/<id>` could start the daemon
// while nothing could stop it.
func cliControlOne(w http.ResponseWriter, r *http.Request) {
	stopping := strings.HasSuffix(r.URL.Path, "/stop")
	verb := "spawn"
	if stopping {
		verb = "stop"
	}
	id := r.URL.Query().Get("service")
	port, _ := strconv.Atoi(r.URL.Query().Get("port"))
	asked := fmt.Sprintf(":%d", port)
	if id != "" {
		asked = fmt.Sprintf("service '%s'", id)
	}

	// Brokers FIRST, and keyed exactly as `/where` keys them. Looking here at all
	// is the fix for a route that could be STARTED and not STOPPED: `/where`
	// lazy-spawns a brokered daemon so the router holds its child, while this
	// handler consulted only the port table — where a broker appears if it took a
	// 307 port and does not appear at all if it took none. Every brokered row
	// therefore fell through to the "no proxy route" 404, which was a refusal and
	// a misdiagnosis in one sentence.
	if st := cliFindBroker(id, port); st != nil {
		cliControlBroker(w, st, stopping)
		return
	}

	st := cliFindRoute(id, port)
	if st == nil {
		// Two situations that used to share one sentence and want opposite
		// responses from an operator: something IS served here — a 421 redirect to
		// another host — but has no local process to act on, versus nothing is
		// served here at all.
		cliMu.Lock()
		l := cliByPort[port]
		cliMu.Unlock()
		if id == "" && l != nil && l.redirect != nil {
			serviceID, _ := l.redirect["serviceId"].(string)
			if serviceID == "" {
				serviceID = "a service"
			}
			cliWriteJSON(w, 404, map[string]any{"ok": false, "error": fmt.Sprintf(
				":%d is a 421 redirect to %s on another host, so this router has no process here to %s. "+
					"Ask the bosun on that host.", port, serviceID, verb)})
			return
		}
		cliWriteJSON(w, 404, map[string]any{"ok": false, "error": fmt.Sprintf(
			"no proxy route, no broker and no redirect on this router answers to %s. GET /state lists "+
				"everything it holds; if you expected one, the registry row may never have been admitted "+
				"— see /state's \"rejected\" and \"drift\".", asked)})
		return
	}

	st.mu.Lock()
	external, bound, bindErr := st.external, st.bound, st.bindErr
	st.mu.Unlock()
	// An adopted route has no backend of ours to start or stop: the external
	// holder owns the public port directly. Answering `ok` here would report a
	// command that did nothing.
	if external {
		cliWriteJSON(w, 409, map[string]any{"ok": false, "serviceId": st.serviceID, "external": true,
			"error": fmt.Sprintf(":%d is held by a process bosun serve did not start, so it has no backend "+
				"to %s. Stop the external holder.", st.publicPort, verb)})
		return
	}
	if stopping {
		had, exited := cliStopBackend(st)
		body := map[string]any{"ok": exited, "serviceId": st.serviceID, "up": !exited, "wasRunning": had}
		if !exited {
			body["error"] = "SIGTERM then SIGKILL sent; the backend has not exited"
		}
		cliWriteJSON(w, 200, body)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), cliServeWaitTimeout+5*time.Second)
	defer cancel()
	if err := cliEnsureBackend(ctx, st); err != nil {
		cliWriteJSON(w, 502, map[string]any{"ok": false, "serviceId": st.serviceID, "error": err.Error()})
		return
	}
	cliWriteJSON(w, 200, map[string]any{"ok": true, "serviceId": st.serviceID, "up": true,
		"bound": bound, "bindError": bindErr})
}

// `/control/spawn|stop` for a BROKERED service.
//
// Spawn is ensure-and-locate under another name, deliberately: probe-first is
// the same right answer here as it is there, and an operator who hits spawn on
// something already running should be told `started: false`, not handed a second
// copy.
//
// The status rule is `/where`'s, not the proxy path's — 200 when the check
// passed OR there was no check to make, 503 when a check was made and failed. A
// `probe: "none"` daemon answering 503 would be the coercion-to-down that
// PRINCIPLES.md forbids everywhere else.
//
// For STOP, the rule is the proxy path's — bosun does not kill what bosun did
// not start — with one difference in how the fact is obtained: a broker stores
// no adoption flag, because there is nothing to store it FROM. So it is
// re-derived by a probe at the moment it matters, and the four-way answer is
// decided by `Bosun.Serve.brokerStopVerdict`, which is where both columns get it
// from. The shim gathers the evidence; the core weighs it.
func cliControlBroker(w http.ResponseWriter, st *cliBroker, stopping bool) {
	spec := cliSpec(st)
	sid := spec.serviceID

	if !stopping {
		res, err := cliEnsureAndLocate(st)
		if err != nil {
			cliWriteJSON(w, 502, map[string]any{"ok": false, "serviceId": sid, "mediation": "broker",
				"error": err.Error()})
			return
		}
		st.mu.Lock()
		hasChild, bound, bindErr := st.cmd != nil, st.bound, st.bindErr
		st.mu.Unlock()
		answered := res.ready || res.probe == "none"
		code := 503
		if answered {
			code = 200
		}
		cliWriteJSON(w, code, map[string]any{
			"ok": answered, "serviceId": sid, "mediation": "broker",
			// `up` from evidence, or from holding the child when there is no
			// evidence to be had — never from having just run the start command.
			"up": res.ready || hasChild, "started": res.started, "probe": res.probe, "detail": res.detail,
			"at": cliLocatorLabel(spec),
			// The 307 door, which most brokers do not have. `bound: false` here is
			// the ordinary portless case, not a bind failure — `bindError` is how
			// the two are told apart.
			"bound": bound, "bindError": bindErr,
		})
		return
	}

	alive := cliProbeBroker(spec)
	st.mu.Lock()
	hasChild := st.cmd != nil
	st.mu.Unlock()
	verdict := "signal"
	if spec.stopVerdict != nil {
		verdict, _ = spec.stopVerdict(hasChild, alive).(string)
	}
	switch verdict {
	case "adopted":
		cliWriteJSON(w, 409, map[string]any{"ok": false, "serviceId": sid, "mediation": "broker",
			"adopted": true,
			"error": fmt.Sprintf("%s is running at %s, but bosun serve did not start it, so there is no "+
				"child here to signal — and killing a daemon it does not own is not this router's to do. "+
				"Stop that process; the next /where finds it gone and starts a fresh one.",
				sid, cliLocatorLabel(spec))})
		return
	case "unknown":
		// Neither "I stopped it" nor "nothing was running" is a claim that can be
		// supported here: no child of ours to signal, and no probe that could tell
		// us whether something else is up.
		cliWriteJSON(w, 409, map[string]any{"ok": false, "serviceId": sid, "mediation": "broker",
			"adopted": nil,
			"error": fmt.Sprintf("bosun serve holds no child for %s, and this service publishes no "+
				"readiness signal it can check (%s), so it can neither stop it nor claim it is already "+
				"stopped. Whether something is running there is not a question this router can answer.",
				sid, cliLocatorLabel(spec))})
		return
	}
	had, exited := cliStopBroker(st)
	body := map[string]any{"ok": exited, "serviceId": sid, "mediation": "broker",
		"up": !exited, "wasRunning": had}
	if had {
		// Said plainly because it is the first thing an operator will ask after
		// stopping one of these: nothing here suspends the lazy-spawn.
		body["note"] = "brokered: /where will start it again on the next ask; /state observes without starting"
	}
	if !exited {
		body["error"] = "SIGTERM then SIGKILL sent; the daemon has not exited"
	}
	cliWriteJSON(w, 200, body)
}

func cliFindRoute(id string, port int) *cliRoute {
	cliMu.Lock()
	defer cliMu.Unlock()
	if id != "" {
		for _, st := range cliRoutes {
			if st.serviceID == id {
				return st
			}
		}
		return nil
	}
	if l := cliByPort[port]; l != nil {
		return l.route
	}
	return nil
}

func cliStateBody() map[string]any {
	cliMu.Lock()
	routes := make([]any, 0, len(cliRoutes))
	for _, st := range cliRoutes {
		st.mu.Lock()
		pid := any(nil)
		if st.cmd != nil && st.cmd.Process != nil {
			pid = st.cmd.Process.Pid
		}
		routes = append(routes, map[string]any{
			"serviceId": st.serviceID, "publicPort": st.publicPort, "internalPort": st.internalPort,
			"up": st.external || st.up, "external": st.external,
			// does the router actually hold this public port? `bound: false` with
			// `external: false` means NOTHING is listening — no request can arrive,
			// so lazy-spawn can never fire — which otherwise renders as an ordinary
			// idle route.
			"bound": st.bound, "bindError": st.bindErr, "pid": pid,
		})
		st.mu.Unlock()
	}
	// Brokered services are a FOURTH bucket, not a flavour of route: the absence
	// of a `publicPort` is normal rather than a fault, and `pid` is null for the
	// (frequent) case of a daemon started outside bosun.
	brokered := make([]any, 0, len(cliBrokerOrder))
	for _, sid := range cliBrokerOrder {
		st := cliBrokers[sid]
		if st == nil {
			continue
		}
		st.mu.Lock()
		pid := any(nil)
		if st.cmd != nil && st.cmd.Process != nil {
			pid = st.cmd.Process.Pid
		}
		brokered = append(brokered, map[string]any{
			"serviceId": st.spec.serviceID, "publicPort": cliNullInt(st.spec.publicPort),
			"transport": st.spec.transport, "at": cliLocatorLabel(st.spec),
			"url": cliNullStr(st.spec.url), "probe": st.spec.probe,
			"pid": pid, "bound": st.bound, "bindError": st.bindErr,
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
	rej := make([]any, 0, len(cliRejected))
	for _, x := range cliRejected {
		rej = append(rej, _force(x))
	}
	cliMu.Unlock()

	drift := cliDriftNow()
	return map[string]any{
		"routes": routes, "brokered": brokered, "redirects": redirects, "rejected": rej,
		// registered-but-never-seen (and its two siblings). Distinct from
		// `rejected`, which means seen and unusable.
		"drift": drift, "stale": len(drift) > 0,
		// `error` non-null ⇒ `drift`/`stale` are the LAST answer, not a current
		// one. Silence there used to read as agreement.
		"registry": map[string]any{"source": cliSource, "plannedAt": cliPlannedAt,
			"modifiedAt": cliModifiedAt(), "error": cliRegistryError},
	}
}

// The registry on disk vs the plan the router holds — `Bosun.Serve.planDrift`,
// through the `drift` callback. Recomputed per call: node caches it on the
// registry file's mtime+size stamp because the Chair polls /state every 1.5s,
// and that cache is a performance decision this column has no consumer for yet.
// The `recover` is not decoration — `readJsonImpl` PANICS on an unreadable file,
// and a check that could not be MADE must be reported as such, never as the
// empty drift list that means agreement.
func cliDriftNow() []any {
	if cliDrift == nil {
		return []any{}
	}
	entries := []any{}
	var failure any
	func() {
		defer func() {
			if e := recover(); e != nil {
				failure = fmt.Sprintf("drift check failed: %v", e)
			}
		}()
		cliCbMu.Lock()
		defer cliCbMu.Unlock()
		for _, d := range _force(cliDrift()).([]any) {
			entries = append(entries, _force(d))
		}
	}()
	cliMu.Lock()
	cliRegistryError = failure
	cliMu.Unlock()
	if failure != nil {
		return []any{}
	}
	return entries
}

func cliModifiedAt() any {
	if cliSourceFile == "" {
		return nil
	}
	fi, err := os.Stat(cliSourceFile)
	if err != nil {
		return nil
	}
	return fi.ModTime().UTC().Format("2006-01-02T15:04:05.000Z")
}

// ── small helpers ────────────────────────────────────────────────────────────

// The reload callback, reachable from the /control/reload handler. Set once in
// serveImpl; a plain global for the same reason the port tables are.
var cliReloadFn func() any

func cliWriteJSON(w http.ResponseWriter, code int, obj any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(code)
	b, _ := json.MarshalIndent(obj, "", "  ")
	w.Write(append(b, '\n'))
}

func cliSanitize(s string) string {
	return strings.NewReplacer(":", "-", "/", "-").Replace(s)
}

func cliNow() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
}

// `Nullable a` crosses as the value or nil; a thunk is forced first.
func cliOptInt(v any) *int {
	if n, ok := _force(v).(int); ok {
		return &n
	}
	return nil
}

func cliOptStr(v any) *string {
	if s, ok := _force(v).(string); ok {
		return &s
	}
	return nil
}

func cliString(v any) string {
	if s, ok := _force(v).(string); ok {
		return s
	}
	return ""
}

func cliDeref(p *string) string {
	if p == nil {
		return "null"
	}
	return *p
}

func cliDerefInt(p *int) string {
	if p == nil {
		return "null"
	}
	return strconv.Itoa(*p)
}

// A *T back to a JSON-able `any` — nil, not a typed nil pointer, which
// encoding/json would render as `null` anyway but which the PS `whereJson`
// encoder would not recognise as absent.
func cliNullInt(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}

func cliNullStr(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

func cliPortsOf(v any) []any {
	out := []any{}
	for _, x := range _force(v).([]any) {
		out = append(out, _force(_force(x).(map[string]any)["publicPort"]))
	}
	return out
}

func cliIdsOf(v any) []any {
	out := []any{}
	for _, x := range _force(v).([]any) {
		out = append(out, _force(_force(x).(map[string]any)["serviceId"]))
	}
	return out
}

func cliStatePorts(state map[string]any, key string) []any {
	out := []any{}
	for _, x := range state[key].([]any) {
		out = append(out, x.(map[string]any)["publicPort"])
	}
	return out
}

// resolveStatusPort :: Effect Int — `statusPort` (3997) unless
// BOSUN_SERVE_STATUS_PORT says otherwise. The override exists for ONE reason:
// standing a SCRATCH router up beside the live one without the two fighting for
// :3997. Anything unparseable falls back rather than binding a surprise.
var Bosun_CLI_Serve_resolveStatusPort any = func() any {
	n, err := strconv.Atoi(os.Getenv("BOSUN_SERVE_STATUS_PORT"))
	if err != nil || n <= 0 || n >= 65536 {
		return 3997
	}
	return n
}
