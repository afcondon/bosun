// The resident reverse-proxy loop for `bosun serve` (BOSUN-SERVE.md §3a).
//
// Mechanical half — bind / spawn / poll / proxy / idle-reap — driven entirely by
// the pure ServePlan computed in PureScript. Mirrors SDI's router.mjs +
// spawner.mjs; the *decisions* (routability, port rewrite, idle policy, 421
// targets, what-changed-on-reload) were already made upstream. P2 features:
// 421 redirects, WebSocket bridging, JSON /state, and SIGHUP hot-reload driven
// by the pure serveDiff. P3 replaces this file with a Go shim reading the same
// records.
//
// Date.now / timers / signal + event callbacks live here, at the edge, never in
// the pure core.

import http from "node:http";
import net from "node:net";
import { spawn } from "node:child_process";
import fs from "node:fs";

const INTERNAL_HOST = "127.0.0.1";
const WAIT_TIMEOUT_MS = 30000; // how long to wait for a spawned backend to listen
const WAIT_POLL_MS = 100;
const PROXY_TIMEOUT_MS = 8000; // a bound-but-hung backend → 504, not a wedge

// EffectFn1: uncurried — the effect runs on serveImpl(config).
export const serveImpl = (config) => {
  const states = [];            // proxy-route states, for /state
  const redirects = new Map();  // publicPort -> { serviceId, host, target }, for /state
  const listeners = new Map();  // publicPort -> { server, state? }

  const bindRoute = (route) => {
    const state = { route, child: null, ready: null, idleTimer: null };
    states.push(state);
    const server = http.createServer((req, res) => handle(state, req, res));
    server.on("upgrade", (req, socket, head) => bridgeUpgrade(state, req, socket, head));
    server.on("clientError", (_e, sock) => { try { sock.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch (_) {} });
    server.on("error", (err) =>
      console.error(`  ✗ cannot bind :${route.publicPort} (${err.code || err.message}) — ${route.serviceId} unserved`));
    server.listen(route.publicPort, INTERNAL_HOST, () =>
      console.log(`  bound :${route.publicPort} → ${route.serviceId} (idle ${Math.round(route.idleTimeoutMs / 1000)}s)`));
    listeners.set(route.publicPort, { server, state });
  };

  const bindRedirect = (rd) => {
    const server = http.createServer((req, res) => {
      res.writeHead(421, { "content-type": "text/plain", location: rd.target + (req.url || "") });
      res.end(`bosun serve: ${rd.serviceId} runs on ${rd.host}. Use ${rd.target}${req.url || ""}\n`);
    });
    server.on("error", (err) =>
      console.error(`  ✗ cannot bind redirect :${rd.publicPort} (${err.code || err.message})`));
    server.listen(rd.publicPort, INTERNAL_HOST, () =>
      console.log(`  bound :${rd.publicPort} → 421 → ${rd.target} (${rd.serviceId} on ${rd.host})`));
    redirects.set(rd.publicPort, { serviceId: rd.serviceId, host: rd.host, target: rd.target });
    listeners.set(rd.publicPort, { server });
  };

  // Close a listener (and kill any backend behind it). Resolves once the port is
  // actually released, so a same-port rebind in the same reload can't EADDRINUSE.
  const unbindPort = (port) => new Promise((resolve) => {
    const l = listeners.get(port);
    if (!l) return resolve();
    listeners.delete(port);
    redirects.delete(port);
    if (l.state) {
      killBackend(l.state);
      const i = states.indexOf(l.state);
      if (i >= 0) states.splice(i, 1);
    }
    console.log(`  ⊘ unbound :${port}`);
    let done = false;
    const fin = () => { if (!done) { done = true; resolve(); } };
    try { l.server.close(fin); } catch (_) { fin(); }
    setTimeout(fin, 1000); // safety net if a lingering connection stalls close()
  });

  for (const route of config.routes) bindRoute(route);
  for (const rd of config.redirects) bindRedirect(rd);

  const stateBody = () => ({
    routes: states.map((s) => ({
      serviceId: s.route.serviceId,
      publicPort: s.route.publicPort,
      internalPort: s.route.internalPort,
      up: !!s.child,
      pid: s.child ? s.child.pid : null,
    })),
    redirects: [...redirects.entries()].map(([publicPort, r]) => ({ publicPort, ...r })),
    rejected: config.rejected,
  });

  // Re-read+re-plan in PureScript (config.reload → a typed ServeDiff), then apply
  // it: unbind removed/changed ports (awaiting release) before (re)binding. Shared
  // by SIGHUP and POST /control/reload.
  const applyReload = () => {
    const diff = config.reload();
    return Promise.all(diff.unbind.map(unbindPort)).then(() => {
      diff.bindRoutes.forEach(bindRoute);
      diff.bindRedirects.forEach(bindRedirect);
      console.log(
        `  ↻ reload applied: -${diff.unbind.length} unbound, ` +
        `+${diff.bindRoutes.length} proxy, +${diff.bindRedirects.length} redirect`);
      return diff;
    });
  };

  if (config.statusPort) {
    const status = http.createServer((req, res) => controlRouter(req, res, { states, listeners, stateBody, applyReload }));
    status.on("error", (err) => console.error(`  ✗ /state :${config.statusPort} (${err.code || err.message})`));
    status.listen(config.statusPort, INTERNAL_HOST, () =>
      console.log(`  /state + /control on :${config.statusPort}`));
  }

  // SIGHUP — same reload as POST /control/reload.
  process.on("SIGHUP", () => {
    try { applyReload(); }
    catch (e) { console.error(`  ✗ reload failed: ${e && e.message ? e.message : e}`); }
  });
  // resident: this Effect never returns; the process lives until Ctrl-C.
};

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "*",
};

const sendJSON = (res, code, obj) => {
  res.writeHead(code, { "content-type": "application/json", ...CORS });
  res.end(JSON.stringify(obj, null, 2) + "\n");
};

// GET /state · POST /control/reload · POST /control/spawn?port= · POST
// /control/stop?port=. The control verbs map to machinery serve already owns:
// reload→applyReload (serveDiff), spawn→ensureBackend, stop→killBackend.
function controlRouter(req, res, ctx) {
  const u = new URL(req.url, "http://localhost");
  if (req.method === "OPTIONS") { res.writeHead(204, CORS); res.end(); return; }

  if (req.method === "GET" && (u.pathname === "/state" || u.pathname === "/")) {
    sendJSON(res, 200, ctx.stateBody());
    return;
  }

  if (req.method === "POST" && u.pathname === "/control/reload") {
    Promise.resolve().then(ctx.applyReload).then((diff) =>
      sendJSON(res, 200, {
        ok: true,
        unbound: diff.unbind,
        boundRoutes: diff.bindRoutes.map((r) => r.publicPort),
        boundRedirects: diff.bindRedirects.map((r) => r.publicPort),
      })
    ).catch((e) => sendJSON(res, 500, { ok: false, error: String((e && e.message) || e) }));
    return;
  }

  if (req.method === "POST" && (u.pathname === "/control/spawn" || u.pathname === "/control/stop")) {
    const port = Number(u.searchParams.get("port"));
    const l = ctx.listeners.get(port);
    if (!l || !l.state) { sendJSON(res, 404, { ok: false, error: `no proxy route on :${port}` }); return; }
    if (u.pathname === "/control/stop") {
      killBackend(l.state);
      sendJSON(res, 200, { ok: true, serviceId: l.state.route.serviceId, up: false });
      return;
    }
    ensureBackend(l.state)
      .then(() => sendJSON(res, 200, { ok: true, serviceId: l.state.route.serviceId, up: true }))
      .catch((e) => sendJSON(res, 502, { ok: false, error: String((e && e.message) || e) }));
    return;
  }

  sendJSON(res, 404, { ok: false, error: "not found" });
}

function handle(state, req, res) {
  bumpIdle(state);
  ensureBackend(state)
    .then(() => proxy(state, req, res))
    .catch((err) => {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`bosun serve: backend for ${state.route.serviceId} did not come up\n${err && err.message ? err.message : err}\n`);
    });
}

// Single-flight: the first request for a down backend spawns it; concurrent
// requests await the same promise. A failed/exited backend clears `ready` so a
// later request retries (SDI's readyPromise dedup).
function ensureBackend(state) {
  if (!state.ready) {
    state.ready = spawnBackend(state).catch((err) => { state.ready = null; throw err; });
  }
  return state.ready;
}

function spawnBackend(state) {
  const { route } = state;
  const logFile = `/tmp/bosun-serve-${sanitize(route.serviceId)}.log`;
  const out = fs.openSync(logFile, "a");
  console.log(`  ⟳ spawn ${route.serviceId}: ${route.launchCommand}  (cwd ${route.cwd}, log ${logFile})`);
  const child = spawn("bash", ["-c", route.launchCommand], { cwd: route.cwd, stdio: ["ignore", out, out], detached: true });
  state.child = child;
  child.on("exit", (code, signal) => {
    console.log(`  ⏹ ${route.serviceId} exited (code ${code}, signal ${signal})`);
    if (state.child === child) { state.child = null; state.ready = null; clearIdle(state); }
  });
  return waitForPort(route.internalPort, WAIT_TIMEOUT_MS).then(() => {
    console.log(`  ✓ ${route.serviceId} listening on :${route.internalPort}`);
    bumpIdle(state);
  });
}

function waitForPort(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const sock = net.connect(port, INTERNAL_HOST);
      sock.once("connect", () => { sock.destroy(); resolve(); });
      sock.once("error", () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error(`timeout waiting for :${port}`));
        else setTimeout(attempt, WAIT_POLL_MS);
      });
    };
    attempt();
  });
}

function proxy(state, req, res) {
  const { route } = state;
  const upstream = http.request(
    { host: INTERNAL_HOST, port: route.internalPort, method: req.method, path: req.url, headers: req.headers },
    (upRes) => { bumpIdle(state); res.writeHead(upRes.statusCode || 502, upRes.headers); upRes.pipe(res); }
  );
  // serve-layer timeout (parity with the Go foreign): a backend that bound but
  // hangs on the request must not wedge the proxy — 504 and move on.
  upstream.setTimeout(PROXY_TIMEOUT_MS, () => {
    if (!res.headersSent) {
      res.writeHead(504, { "content-type": "text/plain" });
      res.end(`bosun serve: ${route.serviceId} timed out after ${PROXY_TIMEOUT_MS}ms\n`);
    }
    upstream.destroy();
  });
  upstream.on("error", (err) => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end(`bosun serve: proxy error for ${route.serviceId}: ${err.message}\n`);
  });
  req.pipe(upstream);
}

// WebSocket (and any HTTP Upgrade): lazy-spawn as for a normal request, then
// raw-pipe the client socket to a fresh TCP connection to the backend, replaying
// the upgrade request line + headers.
function bridgeUpgrade(state, req, socket, head) {
  bumpIdle(state);
  ensureBackend(state).then(() => {
    const up = net.connect(state.route.internalPort, INTERNAL_HOST, () => {
      up.write(`${req.method} ${req.url} HTTP/1.1\r\n`);
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        up.write(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`);
      }
      up.write("\r\n");
      if (head && head.length) up.write(head);
      socket.pipe(up);
      up.pipe(socket);
    });
    const kill = () => { try { up.destroy(); } catch (_) {} try { socket.destroy(); } catch (_) {} };
    up.on("error", kill);
    socket.on("error", kill);
  }).catch(() => { try { socket.destroy(); } catch (_) {} });
}

function killBackend(state) {
  clearIdle(state);
  if (state.child) {
    try { process.kill(-state.child.pid, "SIGTERM"); }
    catch (_) { try { state.child.kill("SIGTERM"); } catch (_) {} }
  }
  state.child = null;
  state.ready = null;
}

function bumpIdle(state) {
  clearIdle(state);
  state.idleTimer = setTimeout(() => reap(state), state.route.idleTimeoutMs);
}

function clearIdle(state) {
  if (state.idleTimer) { clearTimeout(state.idleTimer); state.idleTimer = null; }
}

function reap(state) {
  if (state.child) {
    console.log(`  ⏏ ${state.route.serviceId} idle ${Math.round(state.route.idleTimeoutMs / 1000)}s — SIGTERM`);
    try { process.kill(-state.child.pid, "SIGTERM"); }
    catch (_) { try { state.child.kill("SIGTERM"); } catch (_) {} }
  }
}

function sanitize(s) {
  return s.replace(/[:/]/g, "-");
}
