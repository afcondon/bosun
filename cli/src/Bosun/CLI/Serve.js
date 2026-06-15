// The resident reverse-proxy loop for `bosun serve` (BOSUN-SERVE.md §3a).
//
// This is the mechanical half — bind / spawn / poll / proxy / idle-reap —
// driven entirely by the pure `ServePlan` computed in PureScript. It mirrors
// SDI's router.mjs + spawner.mjs, but the *decisions* (which services are
// routable, the port rewrite, the idle policy) were already made upstream; here
// we only execute. P3 replaces this file with a Go `httputil.ReverseProxy`
// shim reading the identical route records.
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

// EffectFn1: uncurried — the effect runs when called with the arg (cf.
// execLineImpl, probeHttpImpl). NOT the curried `(x) => () => …` Effect form.
export const serveImpl = (routes) => {
  for (const route of routes) {
    const state = { route, child: null, ready: null, idleTimer: null };

    const server = http.createServer((req, res) => handle(state, req, res));
    server.on("clientError", (_err, socket) => {
      try { socket.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch (_) {}
    });
    server.on("error", (err) => {
      console.error(
        `  ✗ cannot bind :${route.publicPort} (${err.code || err.message}) — ` +
        `${route.serviceId} will not be served`
      );
    });
    server.listen(route.publicPort, INTERNAL_HOST, () => {
      console.log(
        `  bound :${route.publicPort} → ${route.serviceId} ` +
        `(idle ${Math.round(route.idleTimeoutMs / 1000)}s)`
      );
    });
  }
  // resident: this Effect never returns; the process lives until Ctrl-C.
};

function handle(state, req, res) {
  bumpIdle(state);
  ensureBackend(state)
    .then(() => proxy(state, req, res))
    .catch((err) => {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(
        `bosun serve: backend for ${state.route.serviceId} did not come up\n` +
        `${err && err.message ? err.message : err}\n`
      );
    });
}

// Single-flight: the first request for a down backend spawns it; concurrent
// requests await the same promise. A failed/exited backend clears `ready` so a
// later request retries (SDI's readyPromise dedup).
function ensureBackend(state) {
  if (!state.ready) {
    state.ready = spawnBackend(state).catch((err) => {
      state.ready = null;
      throw err;
    });
  }
  return state.ready;
}

function spawnBackend(state) {
  const { route } = state;
  const logFile = `/tmp/bosun-serve-${sanitize(route.serviceId)}.log`;
  const out = fs.openSync(logFile, "a");
  console.log(
    `  ⟳ spawn ${route.serviceId}: ${route.launchCommand}  ` +
    `(cwd ${route.cwd}, log ${logFile})`
  );
  // detached so we can SIGTERM the whole process group on idle (bash -c may
  // fork a child that wouldn't die with a bare child.kill()).
  const child = spawn("bash", ["-c", route.launchCommand], {
    cwd: route.cwd,
    stdio: ["ignore", out, out],
    detached: true,
  });
  state.child = child;
  child.on("exit", (code, signal) => {
    console.log(`  ⏹ ${route.serviceId} exited (code ${code}, signal ${signal})`);
    if (state.child === child) {
      state.child = null;
      state.ready = null;
      clearIdle(state);
    }
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
    {
      host: INTERNAL_HOST,
      port: route.internalPort,
      method: req.method,
      path: req.url,
      headers: req.headers,
    },
    (upRes) => {
      bumpIdle(state);
      res.writeHead(upRes.statusCode || 502, upRes.headers);
      upRes.pipe(res);
    }
  );
  upstream.on("error", (err) => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end(`bosun serve: proxy error for ${route.serviceId}: ${err.message}\n`);
  });
  req.pipe(upstream);
}

function bumpIdle(state) {
  clearIdle(state);
  state.idleTimer = setTimeout(() => reap(state), state.route.idleTimeoutMs);
}

function clearIdle(state) {
  if (state.idleTimer) {
    clearTimeout(state.idleTimer);
    state.idleTimer = null;
  }
}

function reap(state) {
  if (state.child) {
    console.log(
      `  ⏏ ${state.route.serviceId} idle ` +
      `${Math.round(state.route.idleTimeoutMs / 1000)}s — SIGTERM`
    );
    try { process.kill(-state.child.pid, "SIGTERM"); }
    catch (_) { try { state.child.kill("SIGTERM"); } catch (_) {} }
  }
}

function sanitize(s) {
  return s.replace(/[:/]/g, "-");
}
