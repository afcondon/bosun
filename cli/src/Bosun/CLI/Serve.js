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
import { spawn, execSync } from "node:child_process";
import fs from "node:fs";

const INTERNAL_HOST = "127.0.0.1";
const WAIT_TIMEOUT_MS = 30000; // how long to wait for a spawned backend to listen
const WAIT_POLL_MS = 100;
const PROXY_TIMEOUT_MS = 8000; // a bound-but-hung backend → 504, not a wedge
const PROBE_TIMEOUT_MS = 750;  // a localhost TCP connect: is anything listening?
// How often an ADOPTED route's external holder is re-checked. `external` and
// `up` are claims about the world, and the world changes without the config
// changing — so they are re-derived on a clock, not remembered from the moment
// the claim was first made.
const ADOPTION_WATCH_MS = 5000;
// SIGTERM → SIGKILL for a backend we are stopping, and how long after that we
// stop waiting. Kept under the callers' HTTP budgets (chair-server reloads with
// `curl --max-time 8`), because a reload that unbinds a live route waits here.
const STOP_GRACE_MS = 3000;
const STOP_GIVEUP_MS = 1500;
// The Chair polls /state every 1.5s and a drift check re-reads + re-plans the
// registry, so it is cached. A FILE source caches on its mtime+size stamp
// (exact: one computation per file version), so this TTL only governs the
// live-URL source, where there is no stamp and a check costs a curl.
const DRIFT_TTL_MS = 5000;

// The control-surface port. 3997 in normal use — it is the address the Chair,
// chair-server and `bosun reload` all know, so it is a constant, not an option.
// The env override exists for ONE reason: standing a scratch router up beside
// the live one (a test, a fixture) without the two fighting for :3997. Anything
// unparseable falls back rather than binding a surprise.
export const resolveStatusPort = () => {
  const n = Number(process.env.BOSUN_SERVE_STATUS_PORT);
  return Number.isInteger(n) && n > 0 && n < 65536 ? n : 3997;
};

// EffectFn1: uncurried — the effect runs on serveImpl(config).
export const serveImpl = (config) => {
  const states = [];            // proxy-route states, for /state
  const redirects = new Map();  // publicPort -> { serviceId, host, target }, for /state
  const listeners = new Map();  // publicPort -> { server, state? }
  // Mutable because a reload refreshes them: rejections are NOT static (a row
  // can stop being routable while we're resident) and the plan's provenance
  // moves with each re-read.
  let rejected = config.rejected;
  let plannedAt = new Date().toISOString();
  // keyed by source stamp (a file version) — `undefined` forces the first compute
  let driftCache = { stamp: undefined, at: 0, entries: [] };
  // why the last drift check could not be made, or null. Reported in /state:
  // a check that FAILED is not a check that found agreement.
  let registryError = null;

  const bindRoute = (route) => {
    const state = {
      route,
      child: null,
      ready: null,
      stopping: null,
      idleTimer: null,
      // adoption + bind outcome. All three are re-derived from evidence, never
      // held as settled facts: see `recheckAdopted` and the `listening` handler.
      external: false,
      externalCheckedAt: null,
      bound: false,
      bindError: null,
    };
    states.push(state);
    const server = http.createServer((req, res) => handle(state, req, res));
    server.on("upgrade", (req, socket, head) => bridgeUpgrade(state, req, socket, head));
    server.on("clientError", (_e, sock) => { try { sock.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch (_) {} });
    server.on("error", (err) => {
      if (err.code === "EADDRINUSE") {
        // ADOPT: the registered public port is already served — the service was
        // started outside serve (by hand, or another launcher). Benign, not a
        // failure: serve steps aside and reports it running-external rather than
        // "unserved". It can neither lazy-spawn nor proxy this route (the external
        // process owns the public port directly).
        //
        // NOT terminal, as it used to be. The holder can exit, and then this
        // route was reporting `up: true` for a port with nothing listening on it
        // at all, and would never bind it, so lazy-spawn could never fire again
        // — unreachable, and the router saying it was fine (:3028, 2026-08-17).
        // `recheckAdopted` re-probes the claim and reclaims the port.
        if (!state.external) {
          console.log(`  ≈ :${route.publicPort} already served externally (adopted) — ${route.serviceId}`);
        }
        state.external = true;
        state.externalCheckedAt = new Date().toISOString();
        state.bindError = null;
      } else {
        state.bindError = err.code || err.message;
        console.error(`  ✗ cannot bind :${route.publicPort} (${state.bindError}) — ${route.serviceId} unserved`);
      }
      state.bound = false;
    });
    // `on`, not `listen`'s one-shot callback: a reclaimed route listens a SECOND
    // time, and the callback form would not fire again — leaving `bound` false
    // for a port we do hold.
    server.on("listening", () => {
      state.bound = true;
      state.bindError = null;
      state.external = false;
      console.log(`  bound :${route.publicPort} → ${route.serviceId} (idle ${Math.round(route.idleTimeoutMs / 1000)}s)`);
    });
    server.on("close", () => { state.bound = false; });
    listeners.set(route.publicPort, { server, state });
    server.listen(route.publicPort, INTERNAL_HOST);
  };

  // Re-derive adoption from the world rather than from memory. For each route we
  // stepped aside from, probe the public port: still answering ⇒ the claim
  // stands; silent ⇒ the external holder has gone, so drop the claim and take
  // the port back. This is what makes an adopted route recoverable WITHOUT
  // restarting the router.
  //
  // It runs on a clock (the guarantee, for a router nobody is watching), and
  // again from `/state` and from `applyReload` — because a reload is a config
  // diff, and a config diff can never notice that a process died.
  const recheckAdopted = () => {
    const adopted = states.filter((s) => s.external);
    if (adopted.length === 0) return Promise.resolve();
    return Promise.all(adopted.map((s) =>
      probePort(s.route.publicPort).then((alive) => {
        s.externalCheckedAt = new Date().toISOString();
        if (alive) return;
        console.log(`  ↺ :${s.route.publicPort} external holder is gone — reclaiming ${s.route.serviceId}`);
        s.external = false;
        const l = listeners.get(s.route.publicPort);
        // If something grabbed the port between the probe and this listen, the
        // error handler above re-adopts (and says so), so losing the race is safe.
        if (l && l.server && !l.server.listening) l.server.listen(s.route.publicPort, INTERNAL_HOST);
      })
    )).then(() => {});
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

  // Close a listener (and stop any backend behind it). Resolves once BOTH the
  // public port is released and the backend has actually exited — a same-port
  // rebind in the same reload would otherwise EADDRINUSE on the public port, and
  // its first lazy-spawn would race the predecessor for the internal one.
  const unbindPort = (port) => {
    const l = listeners.get(port);
    if (!l) return Promise.resolve();
    listeners.delete(port);
    redirects.delete(port);
    let stopped = Promise.resolve();
    if (l.state) {
      stopped = stopBackend(l.state);
      const i = states.indexOf(l.state);
      if (i >= 0) states.splice(i, 1);
    }
    console.log(`  ⊘ unbound :${port}`);
    const closed = new Promise((resolve) => {
      let done = false;
      const fin = () => { if (!done) { done = true; resolve(); } };
      try { l.server.close(fin); } catch (_) { fin(); }
      setTimeout(fin, 1000); // safety net if a lingering connection stalls close()
    });
    return Promise.all([ stopped, closed ]).then(() => {});
  };

  // The registry file's identity, cheap: mtime+size. `null` when the source is a
  // live URL (nothing to stat). An unreadable file is an ERROR, not a silent
  // fallback: every drift verdict below is computed from it, so "cannot read it"
  // must not present as "it agrees".
  const sourceInfo = () => {
    if (!config.sourceFile) return { stamp: null, modifiedAt: null, error: null };
    try {
      const st = fs.statSync(config.sourceFile);
      return { stamp: `${st.mtimeMs}:${st.size}`, modifiedAt: st.mtime.toISOString(), error: null };
    } catch (e) {
      return { stamp: null, modifiedAt: null, error: `cannot read ${config.sourceFile}: ${msg(e)}` };
    }
  };

  // What the registry ON DISK says that this router hasn't admitted (and the
  // reverse). The third source of truth made visible: a registration can
  // persist and never reach the router, and until this existed the two states
  // were indistinguishable from the router's own /state.
  //
  // We do NOT auto-reload on a stamp change — a reload unbinds and rebinds
  // changed ports, killing live backends, and that is not a thing to do with no
  // operator in the loop. Report it; let `bosun reload` (or the Chair's button)
  // be the act.
  const driftNow = () => {
    const info = sourceInfo();
    const now = Date.now();
    // A check that could not be MADE is not a check that found agreement, so a
    // failure is never cached against the file's stamp (which would pin an empty
    // answer until the file next changed). Retry on the TTL, and carry the
    // reason into /state.
    if (registryError !== null) {
      if (now - driftCache.at < DRIFT_TTL_MS) return driftCache.entries;
    } else if (info.stamp !== null) {
      // A file source: the stamp (mtime+size) identifies the CONTENT, so one
      // computation per file version is both cheap and exact — cache indefinitely
      // while the stamp holds. Note we do NOT short-circuit "the file is what we
      // planned from ⇒ no drift": that is true only of the staleness kinds, and
      // `unaccounted` is a property of the file itself (a row nothing serves),
      // which would then be permanently invisible — the very bug, one level down.
      if (driftCache.stamp === info.stamp) return driftCache.entries;
    } else if (driftCache.stamp === null && now - driftCache.at < DRIFT_TTL_MS) {
      // A URL source has no stamp to key on, so bound it by time instead.
      return driftCache.entries;
    }
    let entries = [];
    let err = info.error;
    if (err === null) {
      try { entries = config.drift(); }
      catch (e) { err = `drift check failed: ${msg(e)}`; }
    }
    if (err !== null && err !== registryError) console.error(`  ✗ ${err}`);
    if (err === null && registryError !== null) console.log("  ✓ registry readable again");
    registryError = err;
    driftCache = { stamp: err === null ? info.stamp : null, at: now, entries };
    return entries;
  };

  // Async, because two of the three things it reports are claims about the world
  // that have to be CHECKED to be reported: an adopted route's holder is probed
  // here (via `recheckAdopted`, which also reclaims the port when it has gone),
  // so `up` never outlives the evidence for it by more than one poll.
  const stateBody = () => recheckAdopted().then(() => {
    const drift = driftNow();
    const { modifiedAt } = sourceInfo();
    return {
      routes: states.map((s) => ({
        serviceId: s.route.serviceId,
        publicPort: s.route.publicPort,
        internalPort: s.route.internalPort,
        // an adopted route is up (served externally), just not by serve. That is
        // now a probed fact, not a remembered one: `recheckAdopted` has just run,
        // and it clears `external` for any holder that has gone.
        up: s.external ? true : !!s.child,
        external: !!s.external,
        // when the adoption claim was last put to the test (null ⇒ never adopted)
        externalCheckedAt: s.externalCheckedAt,
        // does the router actually hold this public port? `bound: false` with
        // `external: false` means NOTHING is listening — no request can arrive,
        // so lazy-spawn can never fire — which otherwise renders as an ordinary
        // idle route.
        bound: !!s.bound,
        bindError: s.bindError,
        pid: s.child ? s.child.pid : null,
      })),
      redirects: [...redirects.entries()].map(([publicPort, r]) => ({ publicPort, ...r })),
      rejected,
      // registered-but-never-seen (and its two siblings). Distinct from
      // `rejected`, which means seen and unusable.
      drift,
      stale: drift.length > 0,
      // `error` non-null ⇒ `drift`/`stale` are the LAST answer, not a current
      // one. Silence there used to read as agreement.
      registry: { source: config.source, plannedAt, modifiedAt, error: registryError },
    };
  });

  // Re-read+re-plan in PureScript (config.reload → a typed diff + the refreshed
  // refusals), then apply it: unbind removed/changed ports (awaiting release)
  // before (re)binding. Shared by SIGHUP and POST /control/reload.
  const applyReload = () => {
    const diff = config.reload();
    return Promise.all(diff.unbind.map(unbindPort)).then(() => {
      diff.bindRoutes.forEach(bindRoute);
      diff.bindRedirects.forEach(bindRedirect);
      rejected = diff.rejected;
      plannedAt = new Date().toISOString();
      // force a recompute: the held plan just moved
      driftCache = { stamp: undefined, at: 0, entries: [] };
      // A reload diffs CONFIGURATION. Reality can have moved without the config
      // moving at all — an adopted route whose holder exited is unchanged on
      // disk, so `serveDiff` never revisits it and the reload used to be a
      // no-op against precisely the failure an operator reaches for it to fix
      // (:3028, 2026-08-17). Re-probe adoption as part of the act.
      return recheckAdopted().then(() => {
        console.log(
          `  ↻ reload applied: -${diff.unbind.length} unbound, ` +
          `+${diff.bindRoutes.length} proxy, +${diff.bindRedirects.length} redirect, ` +
          `${diff.rejected.length} refused`);
        return diff;
      });
    });
  };

  // Children are spawned into their OWN process group (`detached`), so the whole
  // subtree can be signalled — which also means they do not die with us. Make
  // them: every ordinary end of this process takes its backends with it.
  // `exit` is synchronous and fires for a normal exit and an uncaught throw
  // alike; the signal handlers exist so SIGTERM (how `supervise` stops us) and
  // Ctrl-C reach it at all. SIGKILL is the one this cannot cover — that is what
  // `reapOrphanBackends` is for, below.
  let tearingDown = false;
  const teardown = () => {
    if (tearingDown) return;
    tearingDown = true;
    for (const s of states) {
      if (!s.child) continue;
      console.log(`  ⏹ ${s.route.serviceId} — router exiting, SIGTERM`);
      signalGroup(s.child, "SIGTERM");
    }
  };
  process.on("exit", teardown);
  for (const sig of [ "SIGTERM", "SIGINT" ]) {
    process.on(sig, () => { teardown(); process.exit(0); });
  }

  // SIGHUP — same reload as POST /control/reload.
  process.on("SIGHUP", () => {
    try { applyReload().catch((e) => console.error(`  ✗ reload failed: ${msg(e)}`)); }
    catch (e) { console.error(`  ✗ reload failed: ${msg(e)}`); }
  });

  // Sweep survivors of a previous router BEFORE binding: an orphan holding an
  // internal port would otherwise be raced by the first lazy-spawn onto it, and
  // the loser of that race does not reliably exit.
  reapOrphanBackends(config.routes).catch((e) => {
    console.error(`  ✗ orphan sweep failed: ${msg(e)} — binding anyway`);
  }).then(() => {
    for (const route of config.routes) bindRoute(route);
    for (const rd of config.redirects) bindRedirect(rd);

    if (config.statusPort) {
      const status = http.createServer((req, res) => controlRouter(req, res, { states, listeners, stateBody, applyReload }));
      status.on("error", (err) => console.error(`  ✗ /state :${config.statusPort} (${err.code || err.message})`));
      status.listen(config.statusPort, INTERNAL_HOST, () =>
        console.log(`  /state + /control on :${config.statusPort}`));
    }

    // The standing guarantee. /state re-probes adoption too, but a router that
    // nobody is polling must still notice a departed holder and take its port
    // back — otherwise recovery depends on someone looking.
    const watch = setInterval(() => { recheckAdopted().catch(() => {}); }, ADOPTION_WATCH_MS);
    if (watch.unref) watch.unref(); // never the reason this process stays alive
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
// reload→applyReload (serveDiff), spawn→ensureBackend, stop→stopBackend.
function controlRouter(req, res, ctx) {
  const u = new URL(req.url, "http://localhost");
  if (req.method === "OPTIONS") { res.writeHead(204, CORS); res.end(); return; }

  if (req.method === "GET" && (u.pathname === "/state" || u.pathname === "/")) {
    ctx.stateBody()
      .then((body) => sendJSON(res, 200, body))
      .catch((e) => sendJSON(res, 500, { ok: false, error: msg(e) }));
    return;
  }

  if (req.method === "POST" && u.pathname === "/control/reload") {
    Promise.resolve().then(ctx.applyReload).then((diff) =>
      // The caller (chair-server, `bosun reload`, the Chair) needs to know what
      // happened to a SPECIFIC row, and "not in boundRoutes" is not the same as
      // "not routed" — an unchanged row is already bound. So answer with the
      // post-reload verdict for every port, not just the deltas.
      ctx.stateBody().then((after) => sendJSON(res, 200, {
        ok: true,
        unbound: diff.unbind,
        boundRoutes: diff.bindRoutes.map((r) => r.publicPort),
        boundRedirects: diff.bindRedirects.map((r) => r.publicPort),
        routes: after.routes.map((r) => r.publicPort),
        redirects: after.redirects.map((r) => r.publicPort),
        rejected: after.rejected,
        drift: after.drift,
        registry: after.registry,
      }))
    ).catch((e) => sendJSON(res, 500, { ok: false, error: msg(e) }));
    return;
  }

  if (req.method === "POST" && (u.pathname === "/control/spawn" || u.pathname === "/control/stop")) {
    const port = Number(u.searchParams.get("port"));
    const l = ctx.listeners.get(port);
    if (!l || !l.state) { sendJSON(res, 404, { ok: false, error: `no proxy route on :${port}` }); return; }
    const state = l.state;
    const serviceId = state.route.serviceId;
    // An adopted route has no backend of ours to start or stop: the external
    // holder owns the public port directly. Answering `ok` here would report a
    // command that did nothing — spawning would put a second copy of the service
    // on the internal port with nothing proxying to it, stopping would kill
    // nothing while claiming the route was down. Refuse, and say why.
    if (state.external) {
      sendJSON(res, 409, {
        ok: false,
        serviceId,
        external: true,
        error: `:${port} is held by a process bosun serve did not start, so it has no backend to `
          + `${u.pathname === "/control/stop" ? "stop" : "spawn"}. Stop the external holder — the router `
          + `re-probes and reclaims the port within ${Math.round(ADOPTION_WATCH_MS / 1000)}s.`,
      });
      return;
    }
    if (u.pathname === "/control/stop") {
      // Answer when it is actually DOWN, not when the signal has been sent. The
      // old handler nulled `state.child` and replied immediately, so a Chair
      // "reboot" (stop then spawn) could put the new backend on the internal
      // port before the old one had let go of it.
      stopBackend(state).then((r) => sendJSON(res, 200, {
        ok: r.exited,
        serviceId,
        up: !r.exited,
        wasRunning: r.had,
        error: r.exited ? undefined : "SIGTERM then SIGKILL sent; the backend has not exited",
      }));
      return;
    }
    ensureBackend(state)
      .then(() => sendJSON(res, 200, {
        ok: true,
        serviceId,
        up: true,
        // the backend is up, but if the router does not hold the public port
        // nothing can reach it — do not let that pass as an unqualified success
        bound: !!state.bound,
        bindError: state.bindError,
      }))
      .catch((e) => sendJSON(res, 502, { ok: false, serviceId, error: msg(e) }));
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
    // Never spawn over a predecessor that is still dying: they would collide on
    // the internal port, and the loser of that race does not reliably exit.
    const settled = state.stopping || Promise.resolve();
    state.ready = settled.then(() => spawnBackend(state)).catch((err) => { state.ready = null; throw err; });
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
  // An upgraded connection is LIVE for as long as it is open, and no further
  // request ever arrives to bump the idle timer — so a WebSocket service was
  // SIGTERMed mid-session at the 10-minute mark (found 2026-08-17 while deciding
  // whether the itajara looper, a WS daemon holding an audio interface, could
  // safely be router-managed: it could not). Count open upgrades and let `reap`
  // decline while any are live; the timer resumes when the last one closes.
  state.upgrades = (state.upgrades || 0) + 1;
  let counted = true;
  const released = () => {
    if (!counted) return;
    counted = false;
    state.upgrades -= 1;
    if (state.upgrades === 0) bumpIdle(state);   // idle clock restarts now, not before
  };
  socket.on("close", released);
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
    up.on("close", released);
    up.on("error", kill);
    socket.on("error", kill);
  }).catch(() => { released(); try { socket.destroy(); } catch (_) {} });
}

// Signal a backend's whole subtree. Backends are `detached`, so the child IS its
// process group leader and `-pid` reaches everything it started; the direct-kill
// fallback covers a child that has already been reaped.
function signalGroup(child, sig) {
  try { process.kill(-child.pid, sig); }
  catch (_) { try { child.kill(sig); } catch (_) {} }
}

// Stop a backend and resolve only when it has actually EXITED — SIGTERM, then
// SIGKILL at the grace deadline. Stopping was previously treated as
// instantaneous (`state.child = null`, reply sent), which is a belief about the
// world stated one signal too early: the process could still hold its internal
// port, and the very next spawn would race it.
//
// Resolves `{ had, exited }`: `had` distinguishes "there was nothing running"
// from "it stopped", so a caller can report the difference instead of a blanket
// success.
function stopBackend(state) {
  clearIdle(state);
  state.ready = null;
  const child = state.child;
  if (!child) {
    // A stop already in flight is the honest answer to a second stop.
    return (state.stopping || Promise.resolve()).then(() => ({ had: false, exited: true }));
  }
  state.child = null; // no new proxying to it from here on
  const p = new Promise((resolve) => {
    let done = false;
    const finish = (exited) => {
      if (done) return;
      done = true;
      clearTimeout(hard);
      clearTimeout(giveUp);
      resolve({ had: true, exited });
    };
    child.once("exit", () => finish(true));
    signalGroup(child, "SIGTERM");
    const hard = setTimeout(() => {
      console.log(`  ⚑ ${state.route.serviceId} ignored SIGTERM — SIGKILL`);
      signalGroup(child, "SIGKILL");
    }, STOP_GRACE_MS);
    const giveUp = setTimeout(() => finish(false), STOP_GRACE_MS + STOP_GIVEUP_MS);
  }).then((r) => {
    if (state.stopping === p) state.stopping = null;
    return r;
  });
  state.stopping = p;
  return p;
}

// ── orphan reaping (backends that outlived a previous router) ────────────────
//
// The startup half of "a child must not outlive its parent". The `exit` hook in
// `serveImpl` covers every ordinary end of the router; this covers the one it
// cannot — SIGKILL, or the machine going down — and it is the half that was
// missing when a `/control/spawn`ed backend survived a router restart and then
// raced its replacement for the internal port (two daemons on one audio
// interface, 2026-08-17).
//
// What makes the sweep safe to make: the INTERNAL port is Bosun's by
// construction (public + `internalOffset`, chosen by the planner and never by a
// service), and we only ever consider the internal ports of our own routes.
// Anything listening on one at startup is a backend of a previous router — and
// the router is about to fight it for that port regardless.

// port -> Set<pid>, for everything listening on TCP right now. One `lsof`, not
// one per port.
function tcpListeners() {
  let out = "";
  try {
    out = execSync("lsof -nP -iTCP -sTCP:LISTEN -Fpn", {
      stdio: [ "ignore", "pipe", "pipe" ],
      maxBuffer: 8 * 1024 * 1024,
    }).toString();
  } catch (e) {
    // lsof exits non-zero when nothing matches, and may be absent entirely;
    // either way, whatever it managed to print is all we can see.
    out = e && e.stdout ? e.stdout.toString() : "";
  }
  const byPort = new Map();
  let pid = null;
  for (const line of out.split("\n")) {
    if (line.startsWith("p")) pid = Number(line.slice(1));
    else if (line.startsWith("n") && pid !== null) {
      const m = /:(\d+)$/.exec(line);
      if (!m) continue;
      const port = Number(m[1]);
      if (!byPort.has(port)) byPort.set(port, new Set());
      byPort.get(port).add(pid);
    }
  }
  return byPort;
}

// pid -> pgid, so an orphan's whole subtree goes (its own pid is often NOT the
// group leader — the leader was the bash wrapper the dead router spawned).
function processGroups(pids) {
  const groups = new Map();
  if (pids.length === 0) return groups;
  try {
    const out = execSync(`ps -o pid=,pgid= -p ${pids.join(",")}`, {
      stdio: [ "ignore", "pipe", "pipe" ],
    }).toString();
    for (const line of out.split("\n")) {
      const m = /^\s*(\d+)\s+(\d+)\s*$/.exec(line);
      if (m) groups.set(Number(m[1]), Number(m[2]));
    }
  } catch (_) { /* fall back to the pid itself, below */ }
  return groups;
}

function reapOrphanBackends(routes) {
  const byPort = tcpListeners();
  const victims = [];
  for (const r of routes) {
    for (const pid of byPort.get(r.internalPort) || []) {
      if (pid !== process.pid) victims.push({ pid, port: r.internalPort, serviceId: r.serviceId });
    }
  }
  if (victims.length === 0) return Promise.resolve([]);
  const groups = processGroups(victims.map((v) => v.pid));
  const sweep = (sig) => {
    for (const v of victims) {
      const pgid = groups.get(v.pid) || v.pid;
      try { process.kill(-pgid, sig); }
      catch (_) { try { process.kill(v.pid, sig); } catch (_) {} }
    }
  };
  for (const v of victims) {
    console.log(`  ☠ :${v.port} held by pid ${v.pid} — an orphaned ${v.serviceId} backend from a previous router: SIGTERM`);
  }
  sweep("SIGTERM");
  return waitForPortsFree(victims.map((v) => v.port), STOP_GRACE_MS).then((held) => {
    if (held.length === 0) return victims;
    console.log(`  ☠ still held after SIGTERM: ${held.map((p) => ":" + p).join(" ")} — SIGKILL`);
    sweep("SIGKILL");
    return waitForPortsFree(held, STOP_GIVEUP_MS).then((stubborn) => {
      for (const port of stubborn) {
        console.error(`  ✗ :${port} is STILL held after SIGKILL — the next lazy-spawn on it will fail`);
      }
      return victims;
    });
  });
}

// Poll until none of `ports` accepts a connection, or the deadline passes.
// Resolves the ports still held.
function waitForPortsFree(ports, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  const tick = () =>
    Promise.all(ports.map((p) => probePort(p, 300).then((alive) => (alive ? p : null))))
      .then((res) => {
        const held = res.filter((p) => p !== null);
        if (held.length === 0 || Date.now() >= deadline) return held;
        return new Promise((r) => setTimeout(r, WAIT_POLL_MS)).then(tick);
      });
  return tick();
}

// Is anything listening on this port? The one-shot form of `waitForPort` — the
// evidence behind every "up" this router reports about a process it did not
// spawn.
function probePort(port, timeoutMs = PROBE_TIMEOUT_MS) {
  return new Promise((resolve) => {
    const sock = net.connect(port, INTERNAL_HOST);
    let done = false;
    const finish = (alive) => {
      if (done) return;
      done = true;
      try { sock.destroy(); } catch (_) {}
      resolve(alive);
    };
    sock.setTimeout(timeoutMs, () => finish(false));
    sock.once("connect", () => finish(true));
    sock.once("error", () => finish(false));
  });
}

function bumpIdle(state) {
  clearIdle(state);
  state.idleTimer = setTimeout(() => reap(state), state.route.idleTimeoutMs);
}

function clearIdle(state) {
  if (state.idleTimer) { clearTimeout(state.idleTimer); state.idleTimer = null; }
}

function reap(state) {
  // never reap a backend with a live upgraded (WebSocket) connection through it
  if (state.upgrades > 0) return;
  if (state.child) {
    console.log(`  ⏏ ${state.route.serviceId} idle ${Math.round(state.route.idleTimeoutMs / 1000)}s — SIGTERM`);
    // via stopBackend, so the state is cleared when the process is actually gone
    // and a request arriving mid-reap waits rather than racing it.
    stopBackend(state);
  }
}

function sanitize(s) {
  return s.replace(/[:/]/g, "-");
}

const msg = (e) => (e && e.message ? e.message : String(e));
