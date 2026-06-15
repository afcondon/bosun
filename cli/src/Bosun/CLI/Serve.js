// The resident reverse-proxy loop for `bosun serve` (BOSUN-SERVE.md §3a).
//
// Mechanical half — bind / spawn / poll / proxy / idle-reap — driven entirely by
// the pure ServePlan computed in PureScript. Mirrors SDI's router.mjs +
// spawner.mjs; the *decisions* (routability, port rewrite, idle policy, 421
// targets) were already made upstream. P2 adds: 421 redirects for remote
// services, WebSocket upgrade bridging, and a read-only JSON /state endpoint.
// P3 replaces this file with a Go shim reading the identical route records.
//
// Date.now / timers / event callbacks live here, at the edge, never in the
// pure core.

import http from "node:http";
import net from "node:net";
import { spawn } from "node:child_process";
import fs from "node:fs";

const INTERNAL_HOST = "127.0.0.1";
const WAIT_TIMEOUT_MS = 30000; // how long to wait for a spawned backend to listen
const WAIT_POLL_MS = 100;

// EffectFn1: uncurried — the effect runs on serveImpl(config).
export const serveImpl = (config) => {
  const states = [];

  for (const route of config.routes) {
    const state = { route, child: null, ready: null, idleTimer: null };
    states.push(state);

    const server = http.createServer((req, res) => handle(state, req, res));
    server.on("upgrade", (req, socket, head) => bridgeUpgrade(state, req, socket, head));
    server.on("clientError", (_e, sock) => { try { sock.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch (_) {} });
    server.on("error", (err) =>
      console.error(`  ✗ cannot bind :${route.publicPort} (${err.code || err.message}) — ${route.serviceId} unserved`));
    server.listen(route.publicPort, INTERNAL_HOST, () =>
      console.log(`  bound :${route.publicPort} → ${route.serviceId} (idle ${Math.round(route.idleTimeoutMs / 1000)}s)`));
  }

  for (const rd of config.redirects) {
    const server = http.createServer((req, res) => {
      res.writeHead(421, { "content-type": "text/plain", location: rd.target + (req.url || "") });
      res.end(`bosun serve: ${rd.serviceId} runs on ${rd.host}. Use ${rd.target}${req.url || ""}\n`);
    });
    server.on("error", (err) =>
      console.error(`  ✗ cannot bind redirect :${rd.publicPort} (${err.code || err.message})`));
    server.listen(rd.publicPort, INTERNAL_HOST, () =>
      console.log(`  bound :${rd.publicPort} → 421 → ${rd.target} (${rd.serviceId} on ${rd.host})`));
  }

  if (config.statusPort) {
    const status = http.createServer((_req, res) => {
      const body = {
        routes: states.map((s) => ({
          serviceId: s.route.serviceId,
          publicPort: s.route.publicPort,
          internalPort: s.route.internalPort,
          up: !!s.child,
          pid: s.child ? s.child.pid : null,
        })),
        redirects: config.redirects.map((r) => ({
          serviceId: r.serviceId, publicPort: r.publicPort, host: r.host, target: r.target,
        })),
      };
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(body, null, 2) + "\n");
    });
    status.on("error", (err) => console.error(`  ✗ /state :${config.statusPort} (${err.code || err.message})`));
    status.listen(config.statusPort, INTERNAL_HOST, () => console.log(`  /state on :${config.statusPort}`));
  }
  // resident: this Effect never returns; the process lives until Ctrl-C.
};

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
  // detached so we can SIGTERM the whole process group on idle.
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
