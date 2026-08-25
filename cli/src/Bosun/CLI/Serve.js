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
  // BROKERED services, keyed by serviceId — NOT by port, because half of them
  // have no port to be keyed by (a unix-socket daemon, a UDP fan-out). This is
  // the table `/where` answers from, and the reason it is a second table rather
  // than a flag on `states`: a broker has no relay, no idle timer and possibly
  // no listener, so almost nothing in the proxy state machine applies to it.
  const brokers = new Map();
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
      // the INTERNAL port was already listening when we went to spawn: we relay
      // to a backend we did not start (`spawnBackend`). Re-derived like the
      // others — there is no child, so no `exit` event to clear it.
      adoptedBackend: false,
      adoptedBackendAt: null,
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
    // The BACKEND-side claim gets the same treatment for the same reason: an
    // adopted backend has no child of ours, so no `exit` event fires when it
    // goes, and nothing else would ever clear `ready` — the route would proxy
    // to a dead internal port forever and never spawn again.
    const backends = states.filter((s) => s.adoptedBackend && !s.child);
    // And the BROKERED doors, which this sweep did not walk at all — so a 307
    // port adopted at bind time was never taken back, the very bug closed for
    // proxy routes on 2026-08-17 living on in the new bucket (§7.4).
    //
    // A brokered service gets ONE arm here, not two, and the missing one is the
    // point: there is no broker equivalent of the `adoptedBackend` check above,
    // because a broker records no adoption claim to go stale. `ensureAndLocate`
    // probes before it spawns and `brokerStopVerdict` re-derives ownership at
    // the moment it is asked, so nothing about the PROCESS needs a clock. Only
    // the LISTENER does — a port we stepped aside from has no other event that
    // could ever tell us the holder left.
    //
    // Which also means: reclaiming a door must touch `bound`/`aside` and
    // NOTHING else. Not `child`, not `ready`. The 307 listener only ever said
    // "go over there"; whether the daemon is running is a separate question
    // with a separate answer, and `unbindPort` already refuses to conflate them
    // in the other direction.
    const doors = [...brokers.values()].filter((s) => s.aside);
    if (adopted.length === 0 && backends.length === 0 && doors.length === 0) return Promise.resolve();
    const doorChecks = doors.map((s) =>
      probePort(s.broker.publicPort).then((alive) => {
        s.asideCheckedAt = new Date().toISOString();
        if (alive) return;
        console.log(`  ↺ :${s.broker.publicPort} holder is gone — reclaiming the 307 door for ${s.broker.serviceId}`);
        s.aside = false;
        const l = listeners.get(s.broker.publicPort);
        // Only OUR listener for this broker, and only if it is not already
        // listening: a reload may have replaced the entry (or dropped it, for a
        // broker that no longer takes a port) between the probe and here. If
        // something grabs the port first, the error handler re-adopts and says
        // so, so losing the race is safe.
        if (l && l.brokerState === s && l.server && !l.server.listening) {
          l.server.listen(s.broker.publicPort, INTERNAL_HOST);
        }
      })
    );
    const backendChecks = backends.map((s) =>
      probePort(s.route.internalPort).then((alive) => {
        if (alive) return;
        console.log(`  ↺ :${s.route.internalPort} adopted backend is gone — ${s.route.serviceId} respawns on the next request`);
        s.adoptedBackend = false;
        s.ready = null;
        clearIdle(s);
      })
    );
    return Promise.all(doorChecks.concat(backendChecks).concat(adopted.map((s) =>
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
    ))).then(() => {});
  };

  // ── broker mode (BOSUN-SERVE.md §3c) ───────────────────────────────────────
  //
  // The router ensures the service is running and says WHERE it is; it never
  // touches the traffic. Register the entry (this is what `/where` answers
  // from) and, IF the service has a public port we were able to move it off,
  // hold that port so a caller who dialled the registered address is told where
  // to go instead — and so that dialling it is still what triggers the spawn.
  //
  // A broker with no public port binds nothing at all. That is not a degraded
  // case: es9-daemon is reached at `~/.es9/control.sock` and link-spike over UDP
  // multicast, and for those `/where` is the only door there could be.
  const registerBroker = (b) => {
    const existing = brokers.get(b.serviceId);
    // Carry the live child across a reload that did not change the entry —
    // re-registering must not orphan a running daemon (which, for these, means
    // an audio interface held by a process nobody is tracking any more).
    const state = existing && sameBroker(existing.broker, b)
      ? Object.assign(existing, { broker: b })
      // `aside`: the registered public port was already held when we went to
      // bind the 307 listener, so we stepped away from it. The broker-table
      // twin of a proxy route's `external`, and re-derived the same way — see
      // `recheckAdopted`. It says nothing whatever about the DAEMON: a door we
      // do not hold and a service that is not running are unrelated facts.
      : { broker: b, child: null, ready: null, stopping: null, bound: false, bindError: null,
          aside: false, asideCheckedAt: null };
    brokers.set(b.serviceId, state);
    return state;
  };

  const bindBroker = (b) => {
    const state = registerBroker(b);
    if (b.publicPort === null || b.publicPort === undefined) return;
    const server = http.createServer((req, res) => brokerRedirect(state, req, res));
    // A WebSocket client will not follow a redirect, so there is nothing clever
    // to do here — but there IS an honest answer, and it is not silence.
    server.on("upgrade", (req, socket) => brokerRefuseUpgrade(state, req, socket));
    server.on("clientError", (_e, sock) => { try { sock.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch (_) {} });
    server.on("error", (err) => {
      // A broker's public port being held externally is the ORDINARY case once
      // the service has been started by hand: it binds its own registered port
      // when nothing moved it off. Say so once and step aside, exactly as the
      // proxy path does.
      state.bindError = err.code === "EADDRINUSE" ? null : (err.code || err.message);
      state.bound = false;
      if (err.code === "EADDRINUSE") {
        // Say it once, not once per reclaim attempt: a door we lose the race
        // for is re-listened by the sweep, and a line per five seconds would
        // bury everything else in the log.
        if (!state.aside) {
          console.log(`  ≈ :${b.publicPort} already held — ${b.serviceId} is brokered, so serve steps aside`);
        }
        // The bind that just failed IS evidence about the port, and the only
        // evidence there is until the first sweep probes it.
        state.aside = true;
        state.asideCheckedAt = new Date().toISOString();
      } else {
        console.error(`  ✗ cannot bind :${b.publicPort} (${state.bindError}) — ${b.serviceId} 307 unavailable`);
      }
    });
    // `on`, not `listen`'s one-shot callback, for the reason `bindRoute` gives:
    // a reclaimed door listens a SECOND time and the callback form would not
    // fire again, leaving `bound` false for a port we do hold.
    server.on("listening", () => {
      state.bound = true;
      state.bindError = null;
      state.aside = false;
      console.log(`  bound :${b.publicPort} → 307 → ${locatorLabel(b)} (${b.serviceId}, brokered — no relay)`);
    });
    server.on("close", () => { state.bound = false; });
    listeners.set(b.publicPort, { server, brokerState: state });
    server.listen(b.publicPort, INTERNAL_HOST);
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
    // `serviceId` on the listener entry so the control surface can NAME what
    // holds this port when it refuses to act on it. A refusal that cannot say
    // which service it is about sends the operator back to /state to find out.
    listeners.set(rd.publicPort, { server, serviceId: rd.serviceId });
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
    // A broker's listener going away does NOT stop the service. The listener
    // only answered "go over there"; the service is on its own address, holding
    // whatever it holds, and unbinding a 307 is no reason to take an audio
    // interface away from it. `applyReload` re-registers or drops the entry.
    // The adoption claim goes with the listener it was about. Leaving `aside`
    // set would leave the sweep probing a port this router no longer has a
    // listener for, and — the moment the holder exits — trying to re-listen on
    // a server that has just been closed and unregistered.
    if (l.brokerState) { l.brokerState.bound = false; l.brokerState.aside = false; }
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
        // `adoptedBackend` counts as up for the same reason `external` does: a
        // backend we relay to is serving whether or not we are its parent. Both
        // have just been re-probed.
        up: s.external || !!s.child || !!s.adoptedBackend,
        external: !!s.external,
        // when the adoption claim was last put to the test (null ⇒ never adopted)
        externalCheckedAt: s.externalCheckedAt,
        // we relay to this route's backend but did not start it, so `pid` is
        // null and no idle-stop will ever reach it. Said plainly, because a
        // route that is up with no pid otherwise reads as a bug.
        adoptedBackend: !!s.adoptedBackend,
        adoptedBackendAt: s.adoptedBackendAt,
        // does the router actually hold this public port? `bound: false` with
        // `external: false` means NOTHING is listening — no request can arrive,
        // so lazy-spawn can never fire — which otherwise renders as an ordinary
        // idle route.
        bound: !!s.bound,
        bindError: s.bindError,
        pid: s.child ? s.child.pid : null,
      })),
      // Brokered services are a FOURTH bucket, not a flavour of route: `up` here
      // is a probed fact (they are frequently started outside bosun), and the
      // absence of a `publicPort` is normal rather than a fault.
      brokered: [...brokers.values()].map((s) => ({
        serviceId: s.broker.serviceId,
        publicPort: s.broker.publicPort,
        transport: s.broker.transport,
        at: locatorLabel(s.broker),
        url: s.broker.url,
        probe: s.broker.probe,
        // did the router start this one, or was it already there
        pid: s.child ? s.child.pid : null,
        bound: !!s.bound,
        bindError: s.bindError,
        // `bound: false` was carrying four situations and the comment beside it
        // claimed two — portless (the ordinary case: es9-daemon is a socket),
        // stepped aside, blocked by a bind error, and mid-reclaim were all one
        // `false`. `door` names which (`Bosun.Serve.brokerDoor`), so the Chair
        // and an operator can tell "no door by design" from "a door somebody
        // else is holding". `holderAnswers` is `aside`: the last evidence about
        // that port, from the EADDRINUSE or from the sweep that just ran.
        door: s.broker.door({ bound: !!s.bound, bindFailed: s.bindError !== null, holderAnswers: !!s.aside }),
        // when the adoption claim was last put to the test (null ⇒ never adopted)
        doorCheckedAt: s.asideCheckedAt || null,
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
      // Brokers arrive whole, not as a delta: a portless broker owns no
      // listener, so a port-keyed diff can say nothing about it (see
      // `Bosun.Serve.ServeDiff`). Refresh every entry — `registerBroker` keeps a
      // running child across an unchanged one — then drop entries the fresh plan
      // no longer has, WITHOUT stopping them: bosun forgetting about a daemon is
      // not a reason to take its device away.
      const fresh = new Set(diff.brokers.map((b) => b.serviceId));
      for (const id of [...brokers.keys()]) if (!fresh.has(id)) brokers.delete(id);
      diff.brokers.forEach(registerBroker);
      diff.bindBrokers.forEach(bindBroker);
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
          `${diff.brokers.length} brokered, ${diff.rejected.length} refused`);
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
  //
  // BROKERED children are deliberately NOT in this sweep. A proxied backend is
  // useless without the router in front of it, so it dies with us; a brokered
  // daemon is on its own address holding a device, and every client of it talks
  // to it directly. Restarting the router must not stop the music. The next
  // `ensureAndLocate` probes before it spawns, so it finds the survivor and
  // reports `started: false` — the router re-adopts rather than duplicating.
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
    for (const b of config.brokers) bindBroker(b);
    for (const rd of config.redirects) bindRedirect(rd);

    if (config.statusPort) {
      const status = http.createServer((req, res) =>
        controlRouter(req, res, { states, listeners, brokers, stateBody, applyReload, whereJson: config.whereJson }));
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

// ── THIS SURFACE IS TWO-COLUMN. Adding a verb here is half the change. ──────
//
// Gnomon (PureScript→Go) is the PRIMARY runtime; this file is the development
// shell's half of the same shim. Every path, every `?key=` and every
// `x-bosun-*` header below must also exist in
// conformance/go/bosun_cli_serve_foreign.go, and `scripts/control-parity.sh`
// (run by `npm test`) goes red when one column has something the other lacks.
// Broker mode was added here alone and nothing could tell for a week — hence
// the check, and hence this note where the next verb gets written.
//
// GET /state · GET /where/:service · POST /control/reload · POST
// /control/spawn?port= · POST /control/stop?port=. The control verbs map to
// machinery serve already owns: reload→applyReload (serveDiff),
// spawn→ensureBackend, stop→stopBackend, where→ensureAndLocate. For a BROKERED
// port the same two verbs go to `controlBroker`, which reaches the same two
// operations from the other side (ensureAndLocate / stopBroker).
function controlRouter(req, res, ctx) {
  const u = new URL(req.url, "http://localhost");
  if (req.method === "OPTIONS") { res.writeHead(204, CORS); res.end(); return; }

  if (req.method === "GET" && (u.pathname === "/state" || u.pathname === "/")) {
    ctx.stateBody()
      .then((body) => sendJSON(res, 200, body))
      .catch((e) => sendJSON(res, 500, { ok: false, error: msg(e) }));
    return;
  }

  // GET /where/<serviceId>  ·  GET /where?port=<publicPort>
  //
  // The thin HTTP adapter over `ensureAndLocate`. It answers for PROXIED routes
  // too, and that is deliberate: "where is this service" is a question with an
  // answer either way, and `mediation` is how the caller learns whether bosun is
  // in the path. A client that must not be relayed (a 30 Hz socket, a UDP
  // endpoint) can then refuse to proceed rather than silently accepting a hop.
  //
  // 200 ready · 503 a check was made and it FAILED (the address is still
  // returned, so the caller can retry) · 404 unknown.
  //
  // `probe: "none"` answers 200 with `ready: false`, which looks odd until you
  // read it as the rule the rest of Bosun follows: a probe kind we cannot
  // observe reports UNKNOWN with a reason, never a silent coercion to down
  // (PRINCIPLES.md, `Bosun.CLI.Observe`). Answering 503 for a UDP fan-out we
  // deliberately did not probe would be exactly that coercion, and would fail
  // every naive `if status != 200` caller against a service that is fine.
  if (req.method === "GET" && (u.pathname === "/where" || u.pathname.startsWith("/where/"))) {
    const byPort = Number(u.searchParams.get("port"));
    const id = u.pathname.startsWith("/where/") ? decodeURIComponent(u.pathname.slice("/where/".length)) : "";
    const answer = (obj, code) => sendJSON(res, code, ctx.whereJson(obj));

    // Keyed by port, a broker answers to EITHER port it is associated with: the
    // registered one (which it may hold, for the 307) and the one it actually
    // listens on. They are usually different — that is the whole point of the
    // rewrite — and a broker that binds nothing has only the second, so matching
    // on `publicPort` alone would make `where 8182` miss a service the registry
    // plainly declares on :8182.
    const brokerState = id
      ? ctx.brokers.get(id)
      : [...ctx.brokers.values()].find((s) => s.broker.publicPort === byPort || s.broker.port === byPort);
    if (brokerState) {
      const b = brokerState.broker;
      ensureAndLocate(brokerState).then((r) => answer({
        service: b.serviceId,
        mediation: "broker",
        ready: r.ready,
        started: r.started,
        probe: r.probe,
        detail: r.detail,
        transport: b.transport,
        host: b.host,
        port: b.port,
        path: b.path,
        url: b.url,
      }, r.ready || r.probe === "none" ? 200 : 503)).catch((e) => sendJSON(res, 502, { ok: false, error: msg(e) }));
      return;
    }

    // A proxied route: the honest address is the ROUTER's public port, because
    // that is where the service is reachable — through us. Ensure it for the
    // same reason a broker is ensured, so "where is it" and "is it up" are one
    // question with one answer.
    const route = id
      ? ctx.states.find((s) => s.route.serviceId === id)
      : ctx.states.find((s) => s.route.publicPort === byPort);
    if (route) {
      const rt = route.route;
      const had = !!route.child;
      const locate = (ready, detail) => answer({
        service: rt.serviceId,
        mediation: "proxy",
        ready,
        started: ready && !had,
        probe: "tcp",
        detail,
        transport: "tcp",
        host: INTERNAL_HOST,
        port: rt.publicPort,
        path: null,
        url: `http://${INTERNAL_HOST}:${rt.publicPort}`,
      }, ready ? 200 : 503);
      if (route.external) { locate(true, "held by a process bosun serve did not start; it answers on the public port directly"); return; }
      if (!route.bound) { locate(false, `the router does not hold :${rt.publicPort} (${route.bindError || "not bound"}), so nothing can reach it`); return; }
      ensureBackend(route)
        .then(() => locate(true, `bosun relays :${rt.publicPort} to the backend on :${rt.internalPort}` + (had ? "" : "; started by this call")))
        .catch((e) => locate(false, `backend did not come up: ${msg(e)}`));
      return;
    }

    sendJSON(res, 404, {
      ok: false,
      error: id
        ? `no service '${id}' is served here. /state lists what is.`
        : `no service on :${byPort || "?"}. /state lists what is.`,
    });
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
        // Brokers are named, not numbered. Most of them hold no public port at
        // all (es9-daemon on a unix socket, link-spike on multicast), so a
        // port-keyed answer says nothing about the ones broker mode exists for
        // — and a reload that ensured four daemons reported as a reload that
        // did nothing. `boundBrokers` is the subset that also took a 307 port.
        brokers: diff.brokers.map((b) => b.serviceId),
        boundBrokers: diff.bindBrokers.map((b) => b.serviceId),
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
    const stopping = u.pathname === "/control/stop";
    // Ports are identity on this surface (e2684b9) and stay so. `?service=` is
    // accepted BESIDE them because broker mode created a class of service with
    // no port to be identified by at all — es9-daemon is reached at
    // `~/.es9/control.sock` — and for those, `/where/<id>` could start the
    // daemon while nothing could stop it. Same key `/state` and `/where` print.
    // Until now `?service=` answered `no proxy route on :0`, which reads as "the
    // daemon is missing" about a daemon that is running fine
    // (FINDINGS-supervision-blind-spots.md).
    const id = u.searchParams.get("service") || "";
    const port = Number(u.searchParams.get("port"));
    const asked = id ? `service '${id}'` : `:${port}`;

    // Brokers first, and keyed exactly as `/where` keys them — the REGISTERED
    // port or the one the service actually listens on, because the rewrite
    // makes those different and that is the point of it.
    //
    // Looking here at all is the fix for a route that could be STARTED and not
    // STOPPED: `/where` lazy-spawns a brokered daemon, so the router holds its
    // child, and this handler consulted only `listeners` — where a broker
    // appears under `brokerState` if it took a 307 port, and does not appear at
    // all if it took none (a unix-socket daemon, a UDP fan-out). Every brokered
    // row therefore fell through to the "no proxy route" 404, which was both a
    // refusal and a misdiagnosis (:3028, 2026-08-24).
    //
    // Refusing to stop what we started is not a boundary, it is a missing
    // feature: an operator who cannot say "restart it, I rebuilt the binary"
    // reaches past the control surface for the pid, which is the one habit the
    // control surface exists to prevent. What stays true is the DIFFERENT
    // claim `unbindPort` makes — taking a broker's ROUTE down is no reason to
    // take its PROCESS down. An explicit stop is a separate act, asked for.
    const brokerState = id
      ? ctx.brokers.get(id)
      : [...ctx.brokers.values()].find((s) => s.broker.publicPort === port || s.broker.port === port);
    if (brokerState) { controlBroker(res, brokerState, stopping); return; }

    const l = id ? undefined : ctx.listeners.get(port);
    const state = l ? l.state : ctx.states.find((s) => s.route.serviceId === id);
    if (!state) {
      // Two situations that used to share one sentence, and that want opposite
      // responses from an operator: something IS served here — a 421 redirect to
      // another host — but has no local process to act on (go to that host's
      // router), versus nothing is served here at all (look at the registry).
      // The brokered third case is no longer among them; it is handled above.
      sendJSON(res, 404, l
        ? { ok: false, error: `:${port} is a 421 redirect to ${l.serviceId || "a service"} on another host, `
            + `so this router has no process here to ${stopping ? "stop" : "spawn"}. `
            + `Ask the bosun on that host.` }
        : { ok: false, error: `no proxy route, no broker and no redirect on this router answers to ${asked}. `
            + `GET /state lists everything it holds; if you expected one, the registry row may never have `
            + `been admitted — see /state's "rejected" and "drift".` });
      return;
    }
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
        error: `:${state.route.publicPort} is held by a process bosun serve did not start, so it has no backend to `
          + `${stopping ? "stop" : "spawn"}. Stop the external holder — the router `
          + `re-probes and reclaims the port within ${Math.round(ADOPTION_WATCH_MS / 1000)}s.`,
      });
      return;
    }
    // Same refusal one layer down: we relay to this backend but did not start
    // it, so there is no child to signal. `stopBackend` would drop the claim,
    // report `wasRunning: false`, and leave a service that is still serving
    // looking stopped — the wrong answer, not merely an incomplete one.
    if (stopping && state.adoptedBackend && !state.child) {
      sendJSON(res, 409, {
        ok: false,
        serviceId,
        adoptedBackend: true,
        error: `:${state.route.internalPort} is served by a backend bosun serve did not start, so there `
          + `is nothing here to stop. Stop that process — the router re-probes and respawns on the next request.`,
      });
      return;
    }
    if (stopping) {
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

// `/control/spawn|stop` for a BROKERED service — the lifecycle half of broker
// mode, which shipped with only its `/where` half.
//
// Spawn is `ensureAndLocate` under another name, deliberately: probe-first is
// the same right answer here as it is there, and an operator who hits spawn on
// something already running should be told `started: false`, not handed a
// second copy.
//
// The status rule is `/where`'s, not the proxy path's — 200 when the check
// passed OR there was no check to make, 503 when a check was made and failed
// (ENSURE-AND-LOCATE.md §2). A `probe: "none"` daemon answering 502/503 would
// be the coercion-to-down that PRINCIPLES.md forbids everywhere else.
function controlBroker(res, state, stopping) {
  const b = state.broker;
  const serviceId = b.serviceId;

  if (!stopping) {
    ensureAndLocate(state).then((r) => {
      const answered = r.ready || r.probe === "none";
      sendJSON(res, answered ? 200 : 503, {
        ok: answered,
        serviceId,
        mediation: "broker",
        // `up` from evidence, or from holding the child when there is no
        // evidence to be had — never from having just run the start command.
        up: r.ready || !!state.child,
        started: r.started,
        probe: r.probe,
        detail: r.detail,
        at: locatorLabel(b),
        // The 307 door, which most brokers do not have. `bound` alone cannot
        // say which of four situations a `false` is, so `door` says it —
        // `/state` reports the same word for the same reason.
        bound: !!state.bound,
        bindError: state.bindError,
        door: b.door({ bound: !!state.bound, bindFailed: state.bindError !== null, holderAnswers: !!state.aside }),
      });
    }).catch((e) => sendJSON(res, 502, { ok: false, serviceId, mediation: "broker", error: msg(e) }));
    return;
  }

  // The proxy path refuses to stop a backend it did not start (`adoptedBackend
  // && !child` → 409): bosun didn't start it, so it mustn't kill it. Same rule,
  // one difference in how the fact is obtained — a broker stores no adoption
  // flag, because there is nothing to store it FROM. `ensureAndLocate` probes
  // before it spawns and reports `started: false` on a survivor; it never
  // writes the finding down. So re-derive it from the world at the moment it
  // matters, which is where the proxy path ended up anyway: a remembered flag
  // has no `exit` event to clear it, and `recheckAdopted` exists to put it back
  // on a clock. Probing once, here, needs no clock at all.
  //
  // The shim gathers the evidence; `Bosun.Serve.brokerStopVerdict` weighs it.
  // The four-way answer is a decision, so it is typed and tested in the core
  // (ServeSpec) rather than being an if-chain out here where nothing can reach
  // it.
  probeBroker(b).then((alive) => {
    const verdict = b.stopVerdict(!!state.child, alive);
    if (verdict === "adopted") {
      sendJSON(res, 409, {
        ok: false,
        serviceId,
        mediation: "broker",
        adopted: true,
        error: `${serviceId} is running at ${locatorLabel(b)}, but bosun serve did not start it, so there `
          + `is no child here to signal — and killing a daemon it does not own is not this router's to do. `
          + `Stop that process; the next /where finds it gone and starts a fresh one.`,
      });
      return;
    }
    if (verdict === "unknown") {
      // Neither "I stopped it" nor "nothing was running" is a claim that can be
      // supported here: no child of ours to signal, and no probe that could
      // tell us whether something else is up. Report unknown WITH the reason,
      // as `Bosun.CLI.Observe` does for a probe it cannot make, rather than
      // sending back an `ok` an operator would read as "the daemon is down".
      sendJSON(res, 409, {
        ok: false,
        serviceId,
        mediation: "broker",
        adopted: null,
        error: `bosun serve holds no child for ${serviceId}, and this service publishes no readiness `
          + `signal it can check (${locatorLabel(b)}), so it can neither stop it nor claim it is already `
          + `stopped. Whether something is running there is not a question this router can answer.`,
      });
      return;
    }
    stopBroker(state).then((r) => sendJSON(res, 200, {
      ok: r.exited,
      serviceId,
      mediation: "broker",
      up: !r.exited,
      wasRunning: r.had,
      // Said plainly because it is the first thing an operator will ask after
      // stopping one of these: nothing here suspends the lazy-spawn. `/where`
      // is ensure-and-locate, so asking it again starts the service again by
      // design; `/state` is the read-only view that will show it down.
      note: r.had ? "brokered: /where will start it again on the next ask; /state observes without starting" : undefined,
      error: r.exited ? undefined : "SIGTERM then SIGKILL sent; the daemon has not exited",
    }));
  }).catch((e) => sendJSON(res, 502, { ok: false, serviceId, mediation: "broker", error: msg(e) }));
}

// ── ENSURE-AND-LOCATE ────────────────────────────────────────────────────────
//
// The operation, as an operation — not an HTTP route. `GET /where` is a thin
// adapter over it, `bosun where` is a thin client over that, and DeepStar's
// pre-flight ("is Link up? is the ES-9 in Hosted mode?") is the same client
// written in Go. Anything embedding this shim can call it directly.
//
//   ensureAndLocate(brokerState) -> Promise<{ ready, started, probe, detail }>
//
// Three questions, answered in an order that matters:
//
//   1. Is it ALREADY up? Probe first, always. These services are started
//      deliberately and often by hand, and a pre-flight that answers "I started
//      it" when it was already running is worse than useless — it is the wrong
//      answer to the question the operator asked.
//   2. If not, start it — once, single-flight, exactly as the proxy path does.
//   3. Did it become ready? Wait for the probe the PLAN chose (`Bosun.Health.
//      Probe`, flattened to a tag by the CLI), and report which one was made.
//      `probe: "none"` means NOTHING WAS CHECKED — never that a check failed.
//
// The wait happens BEFORE the answer is sent, which is the whole contract: a
// caller that follows this answer finds a service that is actually up.
export function ensureAndLocate(state) {
  const b = state.broker;
  return probeBroker(b).then((aliveAlready) => {
    if (aliveAlready) {
      return { ready: true, started: false, probe: b.probe, detail: `already running; ${probeSentence(b)} passed` };
    }
    if (b.probe === "none" && state.child) {
      // Started by us, and nothing about it is checkable. Say exactly that.
      return {
        ready: false, started: false, probe: "none",
        detail: `started by bosun (pid ${state.child.pid}); this service publishes no readiness signal serve can check, so "up" is not a claim it can make`,
      };
    }
    return ensureBrokerChild(state).then(() => probeBroker(b)).then((ready) => ({
      ready,
      started: true,
      probe: b.probe,
      detail: ready
        ? `started by bosun; ${probeSentence(b)} passed`
        : (b.probe === "none"
            ? "started by bosun; no readiness signal to check, so nothing here says it is up"
            : `started by bosun, but ${probeSentence(b)} has not passed within ${WAIT_TIMEOUT_MS}ms`),
    }));
  });
}

// Single-flight spawn for a broker. Same shape as `ensureBackend`, and
// deliberately NOT the same function: a broker has no internal-port rewrite to
// respect, no idle timer to bump, and no relay waiting on it.
function ensureBrokerChild(state) {
  if (!state.ready) {
    const settled = state.stopping || Promise.resolve();
    state.ready = settled.then(() => spawnBroker(state)).catch((err) => { state.ready = null; throw err; });
  }
  return state.ready;
}

function spawnBroker(state) {
  const b = state.broker;
  const logFile = `/tmp/bosun-serve-${sanitize(b.serviceId)}.log`;
  const out = fs.openSync(logFile, "a");
  console.log(`  ⟳ ensure ${b.serviceId}: ${b.launchCommand}  (cwd ${b.cwd}, log ${logFile})`);
  const child = spawn("bash", ["-c", b.launchCommand], { cwd: b.cwd, stdio: ["ignore", out, out], detached: true });
  state.child = child;
  child.on("exit", (code, signal) => {
    console.log(`  ⏹ ${b.serviceId} exited (code ${code}, signal ${signal})`);
    if (state.child === child) { state.child = null; state.ready = null; }
  });
  return waitForBroker(b).then((ok) => {
    if (ok) console.log(`  ✓ ${b.serviceId} ready at ${locatorLabel(b)}`);
    return ok;
  });
}

// Poll the plan's readiness probe until it passes or the deadline. `none` waits
// for nothing and claims nothing — there is no check to make, and inventing a
// grace period would be inventing evidence.
function waitForBroker(b) {
  if (b.probe === "none") return Promise.resolve(false);
  const deadline = Date.now() + WAIT_TIMEOUT_MS;
  const tick = () => probeBroker(b).then((ok) => {
    if (ok || Date.now() > deadline) return ok;
    return new Promise((r) => setTimeout(r, WAIT_POLL_MS)).then(tick);
  });
  return tick();
}

// The readiness probe the PLAN chose, made. `tcp` is `waitForPort`'s one-shot
// (the same connect the proxy path waits on); `socket` is the socket file's
// existence, which is what `Bosun.CLI.Observe`'s `SocketReady` already means.
function probeBroker(b) {
  if (b.probe === "tcp" && b.probePort !== null && b.probePort !== undefined) return probePort(b.probePort);
  if (b.probe === "socket" && b.probePath) {
    try { return Promise.resolve(fs.existsSync(b.probePath)); } catch (_) { return Promise.resolve(false); }
  }
  return Promise.resolve(false);
}

function probeSentence(b) {
  if (b.probe === "tcp") return `a TCP connect to :${b.probePort}`;
  if (b.probe === "socket") return `the socket ${b.probePath}`;
  return "no check";
}

function locatorLabel(b) {
  if (b.transport === "unix") return `unix ${b.path}`;
  if (b.transport === "none") return "(no dialable address)";
  return b.url || `${b.transport} ${b.host}:${b.port}`;
}

// Two broker entries are the SAME entry if everything the router acts on is the
// same. Used on reload to decide whether a running child carries over.
function sameBroker(a, b) {
  return a.launchCommand === b.launchCommand && a.cwd === b.cwd
    && a.transport === b.transport && a.host === b.host && a.port === b.port
    && a.path === b.path && a.probe === b.probe;
}

// The HTTP door onto a brokered service: ensure it, then get out of the way.
// 307 rather than 302/301 because the method and body must survive — a POST
// that silently became a GET on the way to the real service would be a far
// nastier bug than not redirecting at all. The Location is built from the
// transport address, not from the row's `url`: this is an HTTP redirect, and
// telling an HTTP client to go to `ws://…` helps nobody.
function brokerRedirect(state, req, res) {
  const b = state.broker;
  ensureAndLocate(state).then((r) => {
    if (b.transport !== "tcp" || b.port === null || b.port === undefined) {
      res.writeHead(503, { "content-type": "text/plain" });
      res.end(`bosun serve: ${b.serviceId} is brokered at ${locatorLabel(b)}, which is not an HTTP address.\n`
        + `Ask GET /where/${b.serviceId} on the control port for the real address.\n`);
      return;
    }
    const target = `http://${b.host}:${b.port}${req.url || ""}`;
    res.writeHead(307, {
      location: target,
      "content-type": "text/plain",
      // The point of broker mode, stated on every answer: bosun is not carrying
      // this traffic, and a client that wants to know before it commits can ask.
      "x-bosun-mediation": "broker",
      "x-bosun-ready": String(r.ready),
    });
    res.end(`bosun serve: ${b.serviceId} is brokered — go direct to ${target}\n${r.detail}\n`);
  }).catch((err) => {
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`bosun serve: could not ensure ${b.serviceId}: ${msg(err)}\n`);
  });
}

// An upgrade on a brokered public port. A browser's WebSocket does not follow
// redirects, so this connection is going to fail whatever we say — but it fails
// LOUDLY, with the address it should have used, instead of being quietly
// relayed by a router that has no business in a 30 Hz stream. Answering the
// upgrade with a redirect is the closest thing to an honest answer HTTP has.
function brokerRefuseUpgrade(state, req, socket) {
  const b = state.broker;
  ensureAndLocate(state).then(() => {
    const target = b.url || locatorLabel(b);
    const body = `bosun serve: ${b.serviceId} is brokered. Connect directly to ${target}.\n`
      + `Ask GET /where/${b.serviceId} on the control port first; it starts the service if needed.\n`;
    try {
      socket.write(
        "HTTP/1.1 307 Temporary Redirect\r\n" +
        `location: ${target}\r\n` +
        "x-bosun-mediation: broker\r\n" +
        "content-type: text/plain\r\n" +
        `content-length: ${Buffer.byteLength(body)}\r\n` +
        "connection: close\r\n\r\n" + body);
    } catch (_) {}
    try { socket.end(); } catch (_) {}
  }).catch(() => { try { socket.destroy(); } catch (_) {} });
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

// ADOPT-OR-SPAWN. Before starting a backend, ask whether one is already
// listening on the internal port — and if so, relay to it rather than starting
// a second.
//
// This is the same move `bindRoute`'s EADDRINUSE handler makes for the PUBLIC
// port, one layer down, and it closes a hole that only broker mode could open.
// `unbindPort` deliberately does not stop a brokered child (unbinding a 307 is
// no reason to take an audio interface away), and `reapOrphanBackends` runs
// only at router startup — so flipping a service from broker to proxy leaves
// the daemon we started still holding the internal port, with nothing between
// that moment and the next restart to notice. The first request then spawned a
// SECOND copy onto an occupied port: two itajaras on one Audio4c, and `/state`
// naming the pid of the loser (2026-08-23).
//
// Startup keeps the opposite policy on purpose: `reapOrphanBackends` still
// kills survivors of a previous router before binding, because a fresh router
// should be running fresh code. Adoption is for the mid-life case, where the
// alternative is not a stale backend but two live ones.
function spawnBackend(state) {
  const { route } = state;
  return probePort(route.internalPort).then((alive) => {
    if (!alive) return startBackend(state);
    console.log(
      `  ≈ :${route.internalPort} already listening — adopting it for ${route.serviceId} ` +
      `(not started by this router; no duplicate spawned)`);
    state.adoptedBackend = true;
    state.adoptedBackendAt = new Date().toISOString();
    bumpIdle(state);
  });
}

function startBackend(state) {
  const { route } = state;
  state.adoptedBackend = false;
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
    // A bridge is two pumps, and it must never outlive either of them. Only
    // `error` used to tear the pair down, so a leg that CLOSED without erroring
    // left its partner open with nothing behind it — a socket the client still
    // believes in, that no byte will ever arrive on again, and that will never
    // fire `onclose`. `pipe`'s own end-propagation covers the graceful case
    // (`up` ends ⇒ `socket.end()`), but not a destroy, and not the other
    // direction at all.
    //
    // `end`, not `destroy`: a close can follow the last write by microseconds
    // and `destroy` discards whatever is still buffered, so tearing down
    // abruptly would trade a hung socket for a truncated one. `end` flushes,
    // sends FIN, and lets the peer see a real close.
    //
    // NOTE: this is hardening, not a fix for a diagnosed fault. The one-way
    // stall of 2026-08-22 was NOT reproduced, and is not known to arrive by
    // this path — it is closed because a half-dead bridge is wrong on its own
    // terms. docs/RELAY-STALL-AND-BROKER-MODE.md §3 has the reasoning, and its
    // §2 the exclusion list; read that before spending a day re-excluding.
    const halfDead = (other) => () => { try { other.end(); } catch (_) {} };
    up.on("close", released);
    up.on("close", halfDead(socket));
    socket.on("close", halfDead(up));
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

// Stop a PROXIED backend: drop the route's bookkeeping, then `stopChild`.
function stopBackend(state) {
  clearIdle(state);
  // Drop any adoption claim: we are no longer relaying to that backend, and the
  // next request must re-probe rather than trust a stale `true`. Note we do NOT
  // signal it — an adopted backend is not ours to kill.
  state.adoptedBackend = false;
  return stopChild(state, state.route.serviceId);
}

// Stop a BROKERED daemon. `ensureBrokerChild` is deliberately not `ensureBackend`
// — a broker has no internal-port rewrite, no idle timer and no relay waiting on
// it — but STOPPING is the same act on both sides, so it is the same function.
// Duplicating the SIGTERM/grace/SIGKILL/await-exit sequence to keep the two
// paths visually separate would be duplicating the subtle part.
//
// Nothing here clears an adoption flag, because a broker keeps none: whether
// this daemon is ours is probed at the moment it is asked (`controlBroker`).
function stopBroker(state) {
  return stopChild(state, state.broker.serviceId);
}

// Signal a child and resolve only when it has actually EXITED — SIGTERM, then
// SIGKILL at the grace deadline. Stopping was previously treated as
// instantaneous (`state.child = null`, reply sent), which is a belief about the
// world stated one signal too early: the process could still hold its internal
// port, and the very next spawn would race it.
//
// Resolves `{ had, exited }`: `had` distinguishes "there was nothing running"
// from "it stopped", so a caller can report the difference instead of a blanket
// success. `label` is only for the SIGKILL line — a broker has no `route`.
function stopChild(state, label) {
  state.ready = null;
  const child = state.child;
  if (!child) {
    // A stop already in flight is the honest answer to a second stop.
    return (state.stopping || Promise.resolve()).then(() => ({ had: false, exited: true }));
  }
  state.child = null; // nothing routes to it, or reports it, from here on
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
      console.log(`  ⚑ ${label} ignored SIGTERM — SIGKILL`);
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
