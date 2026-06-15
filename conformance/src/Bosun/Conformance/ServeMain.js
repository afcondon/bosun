// Node twin of the Go `Bosun_Conformance_ServeMain_serveImpl` shim, so the
// serve harness runs on both columns. Same resident reverse-proxy logic as
// cli/src/Bosun/CLI/Serve.js (bind / lazy-spawn / waitForPort / proxy /
// single-flight / idle-reap), the real test being the Go column under -race.
//
// EffectFn1: uncurried — the effect runs on serveImpl(routes).

import http from "node:http";
import net from "node:net";
import { spawn } from "node:child_process";
import fs from "node:fs";

const INTERNAL_HOST = "127.0.0.1";
const WAIT_TIMEOUT_MS = 30000;
const WAIT_POLL_MS = 100;

export const serveImpl = (routes) => {
  for (const route of routes) {
    const state = { route, child: null, ready: null, idleTimer: null };
    const server = http.createServer((req, res) => handle(state, req, res));
    server.on("clientError", (_e, sock) => { try { sock.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch (_) {} });
    server.on("error", (err) =>
      console.error(`  ✗ cannot bind :${route.publicPort} (${err.code || err.message})`));
    server.listen(route.publicPort, INTERNAL_HOST, () =>
      console.log(`  bound :${route.publicPort} → ${route.serviceId} (backend ${route.internalPort})`));
  }
};

function handle(state, req, res) {
  bumpIdle(state);
  ensureBackend(state)
    .then(() => proxy(state, req, res))
    .catch((err) => {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`bosun serve: ${state.route.serviceId} did not come up: ${err && err.message ? err.message : err}\n`);
    });
}

function ensureBackend(state) {
  if (!state.ready) {
    state.ready = spawnBackend(state).catch((err) => { state.ready = null; throw err; });
  }
  return state.ready;
}

function spawnBackend(state) {
  const { route } = state;
  const out = fs.openSync(`/tmp/bosun-serve-${route.serviceId.replace(/[:/]/g, "-")}.log`, "a");
  console.log(`  ⟳ spawn ${route.serviceId}: ${route.launchCommand} (cwd ${route.cwd})`);
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
  const up = http.request(
    { host: INTERNAL_HOST, port: route.internalPort, method: req.method, path: req.url, headers: req.headers },
    (upRes) => { bumpIdle(state); res.writeHead(upRes.statusCode || 502, upRes.headers); upRes.pipe(res); }
  );
  up.on("error", (err) => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end(`bosun serve: proxy error for ${route.serviceId}: ${err.message}\n`);
  });
  req.pipe(up);
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
    console.log(`  ⏏ ${state.route.serviceId} idle — SIGTERM`);
    try { process.kill(-state.child.pid, "SIGTERM"); }
    catch (_) { try { state.child.kill("SIGTERM"); } catch (_) {} }
  }
}
