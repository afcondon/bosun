#!/usr/bin/env node
// What `bosun serve` does, as a test that runs against a real router.
//
//   node scripts/serve-behaviours/run.mjs              the node router
//   BOSUN_SERVE_CMD="beam/bosun" node scripts/…/run.mjs   the BEAM router
//   … run.mjs --quick     skip the cases that wait on a long timeout
//   … run.mjs --only P    run the cases whose name starts with P (and setup)
//
// It stands a scratch router up on its own control port over a throwaway
// registry, so the live router on :3997 is not touched. Each case is one
// behaviour of docs/SERVE-BEHAVIOURS.md, under the same name. The router is a
// black box here: the cases use only its ports, its control surface and the
// processes it starts.
import http from "node:http";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { spawn, execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BOSUN = path.resolve(HERE, "../..");
const STUB = path.join(HERE, "stub.mjs");
const WORK = "/tmp/bosun-behaviours";
const REGISTRY = path.join(WORK, "registry.json");
const LOG = path.join(WORK, "router.log");
const SOCKET = path.join(WORK, "broker.sock");
const COMMAND = (process.env.BOSUN_SERVE_CMD || "node cli/run.js").split(" ");
const QUICK = process.argv.includes("--quick");
const ONLY = process.argv.includes("--only") ? process.argv[process.argv.indexOf("--only") + 1] : null;

const STATUS = 8850;
const P = {
  alpha: 8851, stubborn: 8852, dead: 8853, adopted: 8854, remote: 8855,
  broker: 8856, tree: 8857, reserved: 8858, wildcard: 8859, handmade: 8860,
  added: 8861, unanchored: 8862, detached: 8863,
};
const internal = (port) => port + 20000;
const ALL_PORTS = [STATUS, ...Object.values(P), ...Object.values(P).map(internal)];

// ── reporting ────────────────────────────────────────────────────────────────
const results = [];
let current = "";
const check = (what, pass, detail = "") => {
  results.push({ name: current, what, pass: !!pass, detail });
  console.log(`  ${pass ? "✓" : "✗"} ${what}${!pass && detail !== "" ? `\n      ${detail}` : ""}`);
};
const cases = [];
const behaviour = (name, title, body) => cases.push({ name, title, body });

// ── small tools ──────────────────────────────────────────────────────────────
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (ms, condition) => {
  const deadline = Date.now() + ms;
  for (;;) {
    if (await condition()) return true;
    if (Date.now() > deadline) return false;
    await sleep(150);
  }
};
const listening = (port, host = "127.0.0.1") => new Promise((resolve) => {
  const socket = net.connect(port, host);
  const done = (answer) => { socket.destroy(); resolve(answer); };
  socket.setTimeout(700, () => done(false));
  socket.once("connect", () => done(true));
  socket.once("error", () => done(false));
});
// A field with nothing to say: `null` from the node router, left out by the BEAM one.
const absent = (value) => value === null || value === undefined;
// The process group a process is in. A backend's `pid` in /state names its group.
const groupOf = (pid) => { try { return Number(execSync(`ps -o pgid= -p ${pid}`).toString().trim()); } catch (_) { return null; } };
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (_) { return false; } };

const request = (port, target = "/", options = {}) => new Promise((resolve) => {
  const started = Date.now();
  const req = http.request(
    { host: "127.0.0.1", port, path: target, method: options.method || "GET", headers: options.headers || {}, agent: false },
    (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString();
        let json = null;
        try { json = JSON.parse(text); } catch (_) {}
        resolve({ status: res.statusCode, headers: res.headers, text, json, ms: Date.now() - started });
      });
      res.on("error", (e) => resolve({ status: 0, headers: {}, text: String(e), json: null, ms: Date.now() - started }));
    });
  req.setTimeout(options.timeout || 45000, () => req.destroy(new Error("client timeout")));
  req.on("error", (e) => resolve({ status: 0, headers: {}, text: String(e.message), json: null, ms: Date.now() - started }));
  if (options.body) req.write(options.body);
  req.end();
});
const control = (target, method = "GET") => request(STATUS, target, { method });
const state = async () => (await control("/state")).json;
const route = async (port) => ((await state()).routes || []).find((r) => r.publicPort === port);
const brokered = async (id) => ((await state()).brokered || []).find((b) => b.serviceId === id);

// A raw connection: send text, collect what comes back.
const raw = (port, text) => new Promise((resolve) => {
  const socket = net.connect(port, "127.0.0.1");
  const conversation = { socket, received: "", closed: false, send: (more) => socket.write(more) };
  socket.on("data", (d) => { conversation.received += d.toString(); });
  socket.on("close", () => { conversation.closed = true; });
  socket.on("error", () => { conversation.closed = true; });
  socket.once("connect", () => { socket.write(text); resolve(conversation); });
  socket.once("error", () => resolve(conversation));
});
const upgrade = (port, target = "/ws") =>
  raw(port, `GET ${target} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: echo\r\nConnection: Upgrade\r\nX-Test: 7\r\n\r\n`);

// ── processes this test starts itself ────────────────────────────────────────
const mine = [];
const startStub = (args) => {
  const child = spawn("node", [STUB, ...args.map(String)], { cwd: WORK, stdio: "ignore", detached: true });
  mine.push(child);
  return child;
};
const killStub = async (child) => {
  try { process.kill(-child.pid, "SIGKILL"); } catch (_) {}
  await until(3000, () => !alive(child.pid));
};

let router = null;
const startRouter = async (extraEnvironment = {}) => {
  const out = fs.openSync(LOG, "a");
  // 256 open files: what launchd gives a service, and so what the live router has
  router = spawn("bash", ["-c", 'ulimit -n 256; exec "$@"', "bash", ...COMMAND, "serve", REGISTRY], {
    cwd: BOSUN, stdio: ["ignore", out, out],
    env: { ...process.env, BOSUN_SERVE_STATUS_PORT: String(STATUS), ...extraEnvironment },
  });
  const up = await until(30000, () => listening(STATUS));
  if (!up) { console.log(`the router did not come up on :${STATUS}; see ${LOG}`); await cleanup(); process.exit(2); }
};
const stopRouter = async (signal = "SIGTERM") => {
  if (!router) return true;
  const pid = router.pid;
  try { process.kill(pid, signal); } catch (_) {}
  const gone = await until(10000, async () => !alive(pid) && !(await listening(STATUS)));
  router = null;
  return gone;
};

// A backend the router starts is titled `serve:<service>` (Bosun.ProcessTitle),
// and `ps` then shows the title in place of the command line: a backend is
// found by its title, not by `node …/stub.mjs <port>`.
const titleOf = (role) => `^serve:beh-${role}( |$)`;
const row = (id, role, port, startCommand, more = {}) =>
  ({ id, projectId: "beh", projectName: "beh", role, port, host: "mbp", environment: "native", startCommand, ...more });
const stubCommand = (port, flags = "") => `cd ${WORK} && node ${STUB} ${port}${flags === "" ? "" : " " + flags}`;
const baseRows = () => [
  row(1, "alpha", P.alpha, stubCommand(P.alpha)),
  row(2, "stubborn", P.stubborn, stubCommand(P.stubborn, "--stubborn")),
  row(3, "dead", P.dead, `cd ${WORK} && false ${P.dead}`),
  row(4, "adopted", P.adopted, stubCommand(P.adopted)),
  row(5, "remote", P.remote, stubCommand(P.remote), { host: "macmini" }),
  row(6, "broker", P.broker, stubCommand(P.broker), { serveMode: "broker" }),
  row(7, "tree", P.tree, stubCommand(P.tree, "--tree")),
  row(8, "reserved", P.reserved, ""),
  row(9, "wildcard", P.wildcard, stubCommand(P.wildcard)),
  row(10, "handmade", P.handmade, stubCommand(P.handmade)),
  row(11, "unanchored", P.unanchored, `node ${STUB} ${P.unanchored}`),
  row(14, "detached", P.detached, `cd ${WORK} && (node ${STUB} ${P.detached} --label detached &)`),
  row(12, "sock", null, `cd ${WORK} && node ${STUB} --socket ${SOCKET}`, { serveMode: "broker", url: `unix://${SOCKET}` }),
  row(13, "fan", null, `cd ${WORK} && exec sleep 611`, { serveMode: "broker" }),
];
const writeRegistry = (rows) => fs.writeFileSync(REGISTRY, JSON.stringify({ servers: rows, count: rows.length }, null, 2));

const sweepPorts = () => {
  for (const port of ALL_PORTS) {
    try {
      const pids = execSync(`lsof -ti tcp:${port} -sTCP:LISTEN 2>/dev/null || true`).toString().split("\n").filter((s) => s !== "");
      for (const pid of pids) { try { process.kill(Number(pid), "SIGKILL"); } catch (_) {} }
    } catch (_) {}
  }
  try { execSync(`pkill -KILL -f "${titleOf("sock")}" 2>/dev/null || true`); } catch (_) {}
  try { execSync(`pkill -KILL -f "[s]leep 611" 2>/dev/null || true`); } catch (_) {}
};
const cleanup = async () => {
  if (router) { try { process.kill(router.pid, "SIGKILL"); } catch (_) {} }
  for (const child of mine) { try { process.kill(-child.pid, "SIGKILL"); } catch (_) {} }
  sweepPorts();
};

// ═════════════════════════════════════════════════════════════════════════════
// The behaviours. Names match docs/SERVE-BEHAVIOURS.md.
// ═════════════════════════════════════════════════════════════════════════════
let externalHolder = null;
let wildcardHolder = null;

behaviour("C1", "the control surface answers /state, and the document reads through its description", async () => {
  const answer = await control("/state");
  check("GET /state is 200 JSON", answer.status === 200 && answer.json !== null, `status ${answer.status}`);
  const { readServeState } = await import(path.join(BOSUN, "output/Bosun.Protocol.ServeState/index.js"));
  const { Right } = await import(path.join(BOSUN, "output/Data.Either/index.js"));
  const read = readServeState(answer.json);
  check("it reads through Bosun.Protocol.ServeState", read instanceof Right, read.value0);
  const root = await control("/");
  check("GET / answers the same document", root.status === 200 && root.json && Array.isArray(root.json.routes));
  check("it names its registry file", answer.json.registry && answer.json.registry.source === REGISTRY, JSON.stringify(answer.json.registry));
});

behaviour("C2", "the control surface allows any origin", async () => {
  const preflight = await control("/control/reload", "OPTIONS");
  check("OPTIONS is 204", preflight.status === 204, `status ${preflight.status}`);
  check("with access-control-allow-origin: *", preflight.headers["access-control-allow-origin"] === "*");
  const answer = await control("/state");
  check("a JSON answer carries it too", answer.headers["access-control-allow-origin"] === "*");
});

behaviour("C3", "an unknown control path is a 404 that says so", async () => {
  const answer = await control("/nonsense");
  check("404 with ok: false", answer.status === 404 && answer.json && answer.json.ok === false, `status ${answer.status} ${answer.text}`);
});

behaviour("S1", "every port is bound on loopback only", async () => {
  const outside = Object.values(os.networkInterfaces()).flat().find((i) => i && i.family === "IPv4" && !i.internal);
  if (!outside) { check("(no other interface on this machine to try)", true); return; }
  check(`the control port refuses on ${outside.address}`, !(await listening(STATUS, outside.address)));
  check(`a public port refuses on ${outside.address}`, !(await listening(P.alpha, outside.address)));
});

behaviour("J1", "a row the router cannot use is reported with its port and a reason", async () => {
  const rejected = (await state()).rejected || [];
  const reserved = rejected.find((r) => r.serviceId === "beh:reserved");
  const unanchored = rejected.find((r) => r.serviceId === "beh:unanchored");
  check("a row with no command is refused, with its port", reserved && reserved.publicPort === P.reserved && reserved.reason !== "", JSON.stringify(reserved));
  check("a command with no `cd /abs &&` is refused, with its port", unanchored && unanchored.publicPort === P.unanchored && unanchored.reason !== "", JSON.stringify(unanchored));
  check("the router binds neither port", !(await listening(P.reserved)) && !(await listening(P.unanchored)));
});

behaviour("R1", "a service on another host is answered 421 with where to go", async () => {
  const answer = await request(P.remote, "/some/path?x=1");
  check("421", answer.status === 421, `status ${answer.status}`);
  check("location is the other host, same port, same path", /^http:\/\/[^/]+:8855\/some\/path\?x=1$/.test(answer.headers.location || ""), answer.headers.location);
  const listed = ((await state()).redirects || []).find((r) => r.publicPort === P.remote);
  check("/state lists it under redirects", listed && listed.host === "macmini", JSON.stringify(listed));
});

behaviour("A1", "a public port already held is adopted, not shadowed", async () => {
  const r = await route(P.adopted);
  check("external: true", r && r.external === true, JSON.stringify(r));
  check("up: true, pid: null, bound: false", r && r.up === true && absent(r.pid) && r.bound === false, JSON.stringify(r));
  const pid = (await request(P.adopted, "/pid")).json;
  check("the holder still answers on the port itself", pid && pid.pid === externalHolder.pid, JSON.stringify(pid));
});

behaviour("A2", "a holder on every interface is adopted too", async () => {
  const r = await route(P.wildcard);
  check("external: true for a port held on 0.0.0.0", r && r.external === true, JSON.stringify(r));
  const pid = (await request(P.wildcard, "/pid")).json;
  check("a request to the port reaches the holder, not a second copy", pid && pid.pid === wildcardHolder.pid, JSON.stringify(pid));
  check("nothing was started on the internal port", !(await listening(internal(P.wildcard))));
});

behaviour("A3", "spawn and stop are refused for an adopted route", async () => {
  const spawned = await control(`/control/spawn?port=${P.adopted}`, "POST");
  check("spawn is 409 with external: true", spawned.status === 409 && spawned.json && spawned.json.external === true, `status ${spawned.status} ${spawned.text}`);
  const stopped = await control(`/control/stop?port=${P.adopted}`, "POST");
  check("stop is 409", stopped.status === 409, `status ${stopped.status}`);
  check("the holder is untouched", alive(externalHolder.pid));
});

behaviour("P1", "the first request starts the backend on the internal port and is answered by it", async () => {
  const before = await route(P.alpha);
  check("before any request: bound, not up, no pid", before && before.bound === true && before.up === false && absent(before.pid), JSON.stringify(before));
  const answer = await request(P.alpha, "/pid");
  check("GET is 200", answer.status === 200, `status ${answer.status} ${answer.text}`);
  check("the backend listens on the internal port", await listening(internal(P.alpha)));
  const after = await route(P.alpha);
  check("/state: up, with a pid", after && after.up === true && Number.isInteger(after.pid), JSON.stringify(after));
  check("the pid names the process group the backend is in", after && after.pid === groupOf(answer.json.pid), `${after && after.pid} against group ${groupOf(answer.json.pid)}`);
});

behaviour("P2", "a request and its answer pass through whole", async () => {
  const body = "hello, backend";
  const echoed = await request(P.alpha, "/echo?x=1&y=two", { method: "POST", body, headers: { "x-custom": "abc", "content-type": "text/plain", "content-length": Buffer.byteLength(body) } });
  check("method, path and query arrive", echoed.json && echoed.json.method === "POST" && echoed.json.url === "/echo?x=1&y=two", echoed.text.slice(0, 200));
  check("a request header arrives", echoed.json && echoed.json.headers["x-custom"] === "abc");
  check("the request body arrives", echoed.json && echoed.json.body === body);
  check("a response header comes back", echoed.headers["x-stub"] === "1");
  const teapot = await request(P.alpha, "/status/418");
  check("the backend's status comes back", teapot.status === 418, `status ${teapot.status}`);
  const big = Buffer.alloc(1024 * 1024, "abcdefghij");
  const large = await request(P.alpha, "/echo", { method: "POST", body: big, headers: { "content-length": big.length } });
  let sum = 0; for (const byte of big) sum = (sum * 31 + byte) >>> 0;
  check("a 1 MB body arrives intact", large.json && large.json.bytes === big.length && large.json.sum === sum, large.text.slice(0, 120));
  const chunkedUp = await request(P.alpha, "/echo", { method: "POST", body: "chunked body", headers: { "transfer-encoding": "chunked" } });
  check("a chunked request body arrives", chunkedUp.json && chunkedUp.json.body === "chunked body", chunkedUp.text.slice(0, 200));
  const stream = await request(P.alpha, "/stream");
  check("a chunked answer arrives complete", stream.text === "one\ntwo\nthree\n", JSON.stringify(stream.text));
  const head = await request(P.alpha, "/echo", { method: "HEAD" });
  check("HEAD is answered with no body", head.status === 200 && head.text === "", `status ${head.status}`);
});

behaviour("P3", "two requests on one connection are both answered", async () => {
  const conversation = await raw(P.alpha,
    `GET /status/201 HTTP/1.1\r\nHost: x\r\n\r\n`);
  await until(3000, () => conversation.received.includes("status\n") || conversation.closed);
  if (!conversation.closed) conversation.send(`GET /status/202 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);
  await until(3000, () => /HTTP\/1\.1 202/.test(conversation.received) || conversation.closed);
  const first = /HTTP\/1\.1 201/.test(conversation.received);
  const second = /HTTP\/1\.1 202/.test(conversation.received);
  const saidClose = /connection: close/i.test(conversation.received.split("\r\n\r\n")[0] || "");
  check("the first is answered", first, conversation.received.slice(0, 200));
  check("the second is answered, or the first answer said `connection: close`", second || saidClose, conversation.received.slice(0, 300));
  conversation.socket.destroy();
});

behaviour("C4", "stop answers when the backend is gone; spawn answers when it is up", async () => {
  const pid = (await route(P.alpha)).pid;
  const stopped = await control(`/control/stop?port=${P.alpha}`, "POST");
  check("stop is 200, ok, wasRunning", stopped.status === 200 && stopped.json.ok === true && stopped.json.wasRunning === true, stopped.text);
  check("at that moment the process is gone and the internal port is free", !alive(pid) && !(await listening(internal(P.alpha))));
  const again = await control(`/control/stop?port=${P.alpha}`, "POST");
  check("a second stop is ok with wasRunning: false", again.status === 200 && again.json.ok === true && again.json.wasRunning === false, again.text);
  const r = await route(P.alpha);
  check("/state: not up, still bound", r.up === false && r.bound === true, JSON.stringify(r));
  const spawned = await control(`/control/spawn?port=${P.alpha}`, "POST");
  check("spawn is 200, up, bound", spawned.status === 200 && spawned.json.ok === true && spawned.json.up === true && spawned.json.bound === true, spawned.text);
  check("at that moment the backend is listening", await listening(internal(P.alpha)));
  const byName = await control(`/control/stop?service=beh:alpha`, "POST");
  check("a proxied route can be named by service too", byName.status === 200 && byName.json.wasRunning === true, byName.text);
});

behaviour("P4", "many requests for a backend that is down start one process", async () => {
  const answers = await Promise.all(Array.from({ length: 8 }, () => request(P.alpha, "/pid")));
  const pids = new Set(answers.map((a) => (a.json ? a.json.pid : `status ${a.status}`)));
  check("eight requests, all 200", answers.every((a) => a.status === 200), [...pids].join(" "));
  check("all answered by the same process", pids.size === 1, [...pids].join(" "));
  const running = execSync(`pgrep -f "${titleOf("alpha")}" | wc -l`).toString().trim();
  check("one backend process is running", running === "1", `${running} running`);
});

behaviour("C5", "/where says where a proxied service is, and starts it", async () => {
  await control(`/control/stop?port=${P.alpha}`, "POST");
  const byName = await control("/where/beh:alpha");
  check("200, mediation proxy, at the public port", byName.status === 200 && byName.json.mediation === "proxy" && byName.json.at && byName.json.at.port === P.alpha, byName.text);
  check("ready and started by this call", byName.json && byName.json.ready === true && byName.json.started === true, byName.text);
  const byPort = await control(`/where?port=${P.alpha}`);
  check("by port: ready, not started again", byPort.status === 200 && byPort.json.ready === true && byPort.json.started === false, byPort.text);
  const adopted = await control(`/where?port=${P.adopted}`);
  check("an adopted route is ready without being started", adopted.status === 200 && adopted.json.ready === true && adopted.json.started === false, adopted.text);
  const unknown = await control("/where/beh:nobody");
  check("an unknown service is 404", unknown.status === 404 && unknown.json.ok === false, unknown.text);
});

behaviour("P5", "a backend that dies is noticed, and the next request starts another", async () => {
  const first = (await request(P.alpha, "/pid")).json.pid;
  process.kill(first, "SIGKILL");
  const noticed = await until(3000, async () => (await route(P.alpha)).up === false);
  check("/state shows it down within 3 s", noticed);
  const second = await request(P.alpha, "/pid");
  check("the next request is answered by a new process", second.status === 200 && second.json.pid !== first, `status ${second.status}`);
});

behaviour("P6", "a backend that closes without answering is a 502", async () => {
  const answer = await request(P.alpha, "/drop");
  check("502", answer.status === 502, `status ${answer.status} ${answer.text}`);
  const after = await request(P.alpha, "/");
  check("the route still works afterwards", after.status === 200);
});

behaviour("P7", "a backend that accepts and never answers is a 504 after 8 s", async () => {
  if (QUICK) { check("(skipped with --quick)", true); return; }
  const answer = await request(P.alpha, "/hang");
  check("504", answer.status === 504, `status ${answer.status}`);
  check("after about 8 s", answer.ms > 7000 && answer.ms < 10500, `${answer.ms} ms`);
  const after = await request(P.alpha, "/");
  check("the route still works afterwards", after.status === 200);
});

behaviour("P8", "a backend that never listens is a 502", async () => {
  if (QUICK) { check("(skipped with --quick)", true); return; }
  const answer = await request(P.dead, "/");
  check("502", answer.status === 502, `status ${answer.status}`);
  check(`it does not take the full 30 s when the process has already exited (took ${answer.ms} ms)`, answer.ms < 5000, `${answer.ms} ms`);
  const r = await route(P.dead);
  check("/state: not up", r && r.up === false, JSON.stringify(r));
});

behaviour("P10", "a client that finishes sending and waits still gets its answer", async () => {
  const answer = await new Promise((resolve) => {
    const socket = net.connect({ port: P.alpha, host: "127.0.0.1", allowHalfOpen: true });
    let received = "";
    socket.on("data", (d) => { received += d.toString(); });
    socket.on("end", () => { socket.destroy(); resolve(received); });
    socket.on("error", () => resolve(received));
    socket.setTimeout(12000, () => { socket.destroy(); resolve(received + "<timed out>"); });
    socket.once("connect", () => socket.end("GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"));
  });
  check("the whole answer arrives after the client's end is closed", /^HTTP\/1\.1 200/.test(answer) && answer.includes("three"), answer.slice(0, 200));
});

behaviour("P11", "a client that asks before sending its body (Expect: 100-continue) is served", async () => {
  const conversation = await raw(P.alpha, "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\nConnection: close\r\n\r\n");
  const invited = await until(3000, () => /HTTP\/1\.1 100/.test(conversation.received));
  check("it is told to continue", invited, conversation.received.slice(0, 120));
  conversation.send("hello");
  check("and the body is answered", await until(3000, () => conversation.received.includes('"body":"hello"')), conversation.received.slice(0, 300));
  conversation.socket.destroy();
});

behaviour("P12", "a command that puts the service in the background is still served, once", async () => {
  const first = await request(P.detached, "/pid");
  check("the first request is answered by it", first.status === 200 && first.json && first.json.label === "detached", `status ${first.status} ${first.text}`);
  const second = await request(P.detached, "/pid");
  check("the second request reaches the same process", second.status === 200 && second.json.pid === first.json.pid, `status ${second.status}`);
  const running = execSync(`pgrep -f "${titleOf("detached")}" | wc -l`).toString().trim();
  check("one process is running", running === "1", `${running} running`);
  check("/state: up", (await route(P.detached)).up === true, JSON.stringify(await route(P.detached)));
});

behaviour("L1", "more connections at once than the router has files for: every one is answered", async () => {
  const answers = await Promise.all(Array.from({ length: 160 }, () => request(P.alpha, "/drip?ms=1500", { timeout: 30000 })));
  const tally = {};
  for (const a of answers) tally[a.status] = (tally[a.status] || 0) + 1;
  check("160 slow requests at once, each needing two of the router's 256 files: all answered 200", answers.every((a) => a.status === 200), JSON.stringify(tally));
  check("the router is still up", alive(router.pid) && (await control("/state")).status === 200);
  check("and serves the next request", (await request(P.alpha, "/")).status === 200);
});

behaviour("P9", "bytes that are not HTTP are answered 400", async () => {
  const conversation = await raw(P.alpha, "this is not http\r\n\r\n");
  await until(3000, () => conversation.closed || conversation.received !== "");
  check("400", /^HTTP\/1\.1 400/.test(conversation.received), conversation.received.slice(0, 80));
  conversation.socket.destroy();
});

behaviour("U1", "an upgraded connection is carried both ways, with the request replayed", async () => {
  const conversation = await upgrade(P.alpha, "/ws?room=1");
  await until(5000, () => conversation.received.includes("\n{") || conversation.received.includes("}\n") || conversation.closed);
  check("101 from the backend", /^HTTP\/1\.1 101/.test(conversation.received), conversation.received.slice(0, 80));
  check("the backend saw the same path and header", conversation.received.includes(`"url":"/ws?room=1"`) && conversation.received.includes(`"test":"7"`), conversation.received);
  conversation.send("ping-1");
  check("bytes go out and come back", await until(3000, () => conversation.received.endsWith("ping-1")), conversation.received.slice(-40));
  conversation.send("bye");
  check("when the backend closes its end, the client's end closes", await until(3000, () => conversation.closed));
  const second = await upgrade(P.alpha);
  await until(3000, () => second.received.includes("101"));
  const open = async () => (await request(P.alpha, "/upgrades")).json.upgrades;
  check("the backend holds one upgraded connection", (await open()) === 1);
  second.socket.destroy();
  check("when the client closes its end, the backend's end closes", await until(3000, async () => (await open()) === 0));
});

behaviour("C6", "a backend that ignores SIGTERM is killed, and stop still answers truthfully", async () => {
  if (QUICK) { check("(skipped with --quick)", true); return; }
  const pid = (await request(P.stubborn, "/pid")).json.pid;
  const stopped = await control(`/control/stop?port=${P.stubborn}`, "POST");
  check("stop is ok", stopped.status === 200 && stopped.json.ok === true, stopped.text);
  check("after the grace period, not before", stopped.ms >= 2500, `${stopped.ms} ms`);
  check("the process is gone", !alive(pid));
});

behaviour("C7", "stop takes the backend's children with it", async () => {
  const answer = (await request(P.tree, "/pid")).json;
  check("the backend has a child process", answer && Number.isInteger(answer.child), JSON.stringify(answer));
  await control(`/control/stop?port=${P.tree}`, "POST");
  check("the child is gone too", await until(2000, () => !alive(answer.child)));
});

behaviour("C8", "spawn and stop on a port with nothing to act on say which kind of nothing", async () => {
  const redirect = await control(`/control/spawn?port=${P.remote}`, "POST");
  check("a redirect port is 404 naming the redirect", redirect.status === 404 && /421/.test(redirect.json.error), redirect.text);
  const nothing = await control(`/control/stop?port=1`, "POST");
  check("an unknown port is 404 pointing at /state", nothing.status === 404 && /\/state/.test(nothing.json.error), nothing.text);
});

behaviour("B1", "a backend already on the internal port is relayed to, not duplicated", async () => {
  const hand = startStub([internal(P.handmade), "--label", "by-hand"]);
  await until(5000, () => listening(internal(P.handmade)));
  const answer = await request(P.handmade, "/pid");
  check("the request reaches the one started by hand", answer.json && answer.json.pid === hand.pid, answer.text);
  const r = await route(P.handmade);
  check("/state: up, adoptedBackend, no pid", r.up === true && r.adoptedBackend === true && absent(r.pid), JSON.stringify(r));
  const stopped = await control(`/control/stop?port=${P.handmade}`, "POST");
  check("stop is refused 409", stopped.status === 409 && stopped.json.adoptedBackend === true, stopped.text);
  check("and it is untouched", alive(hand.pid));
  await killStub(hand);
  check("when it goes, /state drops the claim within 8 s", await until(8000, async () => { const now = await route(P.handmade); return now.adoptedBackend === false && now.up === false; }));
  const next = await request(P.handmade, "/pid");
  check("the next request starts a backend of the router's own", next.status === 200 && Number.isInteger((await route(P.handmade)).pid), `status ${next.status}`);
});

behaviour("K1", "/where starts a brokered service and gives its real address", async () => {
  const first = await control("/where/beh:broker");
  check("200, mediation broker, ready, started", first.status === 200 && first.json.mediation === "broker" && first.json.ready === true && first.json.started === true, first.text);
  check("the address is the port it really listens on", first.json.at && first.json.at.port === internal(P.broker) && first.json.at.host === "127.0.0.1", JSON.stringify(first.json.at));
  const second = await control(`/where?port=${P.broker}`);
  check("asked again by its registered port: ready, not started", second.status === 200 && second.json.ready === true && second.json.started === false, second.text);
  const third = await control(`/where?port=${internal(P.broker)}`);
  check("and by the port it listens on", third.status === 200 && third.json.service === "beh:broker", third.text);
  const listed = await brokered("beh:broker");
  check("/state lists it under brokered, with a pid and an open door", listed && Number.isInteger(listed.pid) && listed.door === "open" && listed.bound === true, JSON.stringify(listed));
});

behaviour("K2", "the registered port of a brokered service answers 307 and carries nothing", async () => {
  const answer = await request(P.broker, "/x?y=1", { method: "POST", body: "q", headers: { "content-length": 1 } });
  check("307", answer.status === 307, `status ${answer.status}`);
  check("location is the real address with the same path", answer.headers.location === `http://127.0.0.1:${internal(P.broker)}/x?y=1`, answer.headers.location);
  check("x-bosun-mediation: broker and x-bosun-ready: true", answer.headers["x-bosun-mediation"] === "broker" && answer.headers["x-bosun-ready"] === "true", JSON.stringify(answer.headers));
  const conversation = await upgrade(P.broker);
  await until(3000, () => conversation.closed);
  check("an upgrade is refused with 307 and the connection closed", /^HTTP\/1\.1 307/.test(conversation.received) && conversation.closed, conversation.received.slice(0, 120));
});

behaviour("K3", "a brokered service the router started can be stopped; one it did not start cannot", async () => {
  const pid = (await brokered("beh:broker")).pid;
  const stopped = await control(`/control/stop?service=beh:broker`, "POST");
  check("stop is 200, wasRunning", stopped.status === 200 && stopped.json.ok === true && stopped.json.wasRunning === true, stopped.text);
  check("the process is gone", !alive(pid));
  const hand = startStub([internal(P.broker)]);
  await until(5000, () => listening(internal(P.broker)));
  const where = await control("/where/beh:broker");
  check("/where finds one started by hand: ready, not started", where.json.ready === true && where.json.started === false, where.text);
  const refused = await control(`/control/stop?port=${P.broker}`, "POST");
  check("stop is 409 with adopted: true", refused.status === 409 && refused.json.adopted === true, refused.text);
  check("and it is untouched", alive(hand.pid));
  await killStub(hand);
});

behaviour("K4", "a service on a unix socket is started and located, with no port anywhere", async () => {
  const where = await control("/where/beh:sock");
  check("200, ready, started", where.status === 200 && where.json.ready === true && where.json.started === true, where.text);
  check("transport unix, with the socket's path", where.json.at && where.json.at.transport === "unix" && where.json.at.path === SOCKET, JSON.stringify(where.json.at));
  check("the socket exists", fs.existsSync(SOCKET));
  const listed = await brokered("beh:sock");
  check("/state: door none, a pid", listed && listed.door === "none" && Number.isInteger(listed.pid), JSON.stringify(listed));
});

behaviour("K5", "a service with nothing to check is started, and never called ready", async () => {
  const first = await control("/where/beh:fan");
  check("200 with ready: false, probe none, started", first.status === 200 && first.json.ready === false && first.json.probe === "none" && first.json.started === true, first.text);
  const second = await control("/where/beh:fan");
  check("asked again: not started a second time", second.status === 200 && second.json.started === false, second.text);
  const running = execSync(`pgrep -f "[s]leep 611" | wc -l`).toString().trim();
  check("one process is running", running === "1", `${running} running`);
  const stopped = await control(`/control/stop?service=beh:fan`, "POST");
  check("stop is 200, wasRunning", stopped.status === 200 && stopped.json.wasRunning === true, stopped.text);
  const unknown = await control(`/control/stop?service=beh:fan`, "POST");
  check("a second stop is 409 with adopted: null (it cannot know)", unknown.status === 409 && unknown.json.adopted === null, unknown.text);
});

behaviour("D1", "a registry edited on disk shows as drift, and nothing changes until a reload", async () => {
  await request(P.tree, "/");      // running, and about to be removed
  await request(P.stubborn, "/");  // running, and unchanged
  const rows = baseRows().filter((r) => r.role !== "tree")
    .map((r) => (r.role === "alpha" ? { ...r, startCommand: stubCommand(P.alpha, "--label v2") } : r))
    .concat([row(20, "added", P.added, stubCommand(P.added))]);
  await sleep(1100); // a file stamp is whole seconds on some file systems
  writeRegistry(rows);
  const s = await state();
  const kinds = (s.drift || []).map((d) => `${d.publicPort}:${d.kind}`).sort().join(" ");
  check("drift names the added, the altered and the departed port", kinds === `${P.alpha}:altered ${P.tree}:departed ${P.added}:unrouted`, kinds);
  check("stale: true", s.stale === true);
  check("the removed route is still served", (await request(P.tree, "/")).status === 200);
  check("the added one is not bound", !(await listening(P.added)));
});

behaviour("D2", "reload applies the difference and leaves the rest alone", async () => {
  const stubbornPid = (await route(P.stubborn)).pid;
  const treePid = (await route(P.tree)).pid;
  const sockPid = (await brokered("beh:sock")).pid;
  const answer = await control("/control/reload", "POST");
  check("200, ok", answer.status === 200 && answer.json.ok === true, answer.text.slice(0, 200));
  check("unbound: the removed and the altered port", JSON.stringify([...answer.json.unbound].sort()) === JSON.stringify([P.alpha, P.tree]), JSON.stringify(answer.json.unbound));
  check("boundRoutes: the added and the altered port", JSON.stringify([...answer.json.boundRoutes].sort()) === JSON.stringify([P.alpha, P.added]), JSON.stringify(answer.json.boundRoutes));
  check("the answer lists every route now held", answer.json.routes.includes(P.added) && !answer.json.routes.includes(P.tree));
  check("the removed route's backend is gone and its port refuses", !alive(treePid) && !(await listening(P.tree)));
  check("the added route serves", (await request(P.added, "/")).status === 200);
  const label = (await request(P.alpha, "/pid")).json;
  check("the altered route runs the new command", label && label.label === "v2", JSON.stringify(label));
  check("an unchanged route keeps its backend", (await route(P.stubborn)).pid === stubbornPid && alive(stubbornPid));
  check("an unchanged brokered service keeps its process", (await brokered("beh:sock")).pid === sockPid && alive(sockPid));
  const s = await state();
  check("no drift afterwards", (s.drift || []).length === 0 && s.stale === false, JSON.stringify(s.drift));
  check("the adopted route is still adopted", (await route(P.adopted)).external === true);
});

behaviour("D3", "SIGHUP is the same reload", async () => {
  await sleep(1100);
  writeRegistry(baseRows().filter((r) => r.role !== "tree"));
  process.kill(router.pid, "SIGHUP");
  check("the port removed from the file stops answering within 5 s", await until(5000, async () => !(await listening(P.added))));
  check("the router is still up", alive(router.pid) && (await listening(STATUS)));
});

behaviour("D4", "a registry that cannot be read is an error in /state, not agreement", async () => {
  fs.renameSync(REGISTRY, REGISTRY + ".away");
  const s = await state();
  check("registry.error says why", s.registry && typeof s.registry.error === "string" && s.registry.error !== "", JSON.stringify(s.registry));
  check("routes are still served", (await request(P.alpha, "/")).status === 200);
  fs.renameSync(REGISTRY + ".away", REGISTRY);
  check("the error clears when the file is back", await until(7000, async () => absent((await state()).registry.error)));
});

behaviour("A4", "when an adopted port's holder goes, the router takes the port and serves it", async () => {
  await killStub(externalHolder);
  const reclaimed = await until(10000, async () => { const r = await route(P.adopted); return r.external === false && r.bound === true; });
  check("within 10 s: external false, bound true", reclaimed, JSON.stringify(await route(P.adopted)));
  check("up: false, because nothing is running", (await route(P.adopted)).up === false);
  const answer = await request(P.adopted, "/pid");
  check("the next request starts the router's own backend", answer.status === 200 && (await route(P.adopted)).pid === groupOf(answer.json.pid), `status ${answer.status}`);
});

behaviour("T1", "a router asked to stop takes its relayed backends with it and leaves brokered ones", async () => {
  const alphaPid = (await request(P.alpha, "/pid")).json.pid;
  await control("/where/beh:sock");
  const sockPid = (await brokered("beh:sock")).pid;
  check("the router exits on SIGTERM", await stopRouter("SIGTERM"));
  check("the relayed backend is gone within 5 s", await until(5000, () => !alive(alphaPid)));
  check("the brokered service is still running", alive(sockPid) && fs.existsSync(SOCKET));
  await startRouter();
  const where = await control("/where/beh:sock");
  check("the next router finds it: ready, not started", where.json.ready === true && where.json.started === false, where.text);
  const refused = await control("/control/stop?service=beh:sock", "POST");
  check("and will not stop it, because it did not start it", refused.status === 409 && refused.json.adopted === true, refused.text);
  try { process.kill(sockPid, "SIGKILL"); } catch (_) {}
});

behaviour("T2", "a router that is killed leaves a backend behind; the next router clears it before binding", async () => {
  const orphan = (await request(P.alpha, "/pid")).json.pid;
  await stopRouter("SIGKILL");
  check("the backend outlives a killed router", alive(orphan) && (await listening(internal(P.alpha))));
  await startRouter();
  check("the next router has stopped it", !alive(orphan));
  const r = await route(P.alpha);
  check("/state: bound, not up", r.bound === true && r.up === false, JSON.stringify(r));
  const answer = await request(P.alpha, "/pid");
  check("and the next request starts a fresh one", answer.status === 200 && answer.json.pid !== orphan);
});

behaviour("T3", "Ctrl-C ends the router, and no backend of its outlives the next router's start", async () => {
  const left = (await request(P.alpha, "/pid")).json.pid;
  process.kill(router.pid, "SIGINT");
  const pid = router.pid;
  check("the router is gone within 3 s of SIGINT", await until(3000, async () => !alive(pid) && !(await listening(STATUS))));
  if (alive(pid)) { try { process.kill(pid, "SIGKILL"); } catch (_) {} await sleep(500); }
  router = null;
  await startRouter();
  check("after the next router has started, the backend it left is gone", !alive(left));
});

behaviour("I1", "an idle backend is stopped, and the next request starts it again", async () => {
  await stopRouter("SIGTERM");
  await startRouter({ BOSUN_SERVE_IDLE_MS: "2000" });
  const first = (await request(P.alpha, "/pid")).json.pid;
  check("stopped within 5 s of the last request", await until(5000, async () => (await route(P.alpha)).up === false && !alive(first)));
  const second = await request(P.alpha, "/pid");
  check("the next request starts another", second.status === 200 && second.json.pid !== first);
});

behaviour("I2", "a backend with an open upgraded connection is not idle", async () => {
  const conversation = await upgrade(P.alpha);
  await until(3000, () => conversation.received.includes("101"));
  const pid = (await route(P.alpha)).pid;
  await sleep(4500);
  check("still running 4.5 s later, past the 2 s limit", alive(pid) && (await route(P.alpha)).up === true);
  conversation.send("still-here");
  check("and the connection still carries bytes", await until(2000, () => conversation.received.endsWith("still-here")));
  conversation.socket.destroy();
  check("once it closes, the backend is stopped within 5 s", await until(5000, () => !alive(pid)));
});

behaviour("I3", "a backend still sending an answer is not idle", async () => {
  const answer = await request(P.alpha, "/drip?ms=5000");
  check("a 5 s answer arrives whole, past the 2 s limit", answer.status === 200 && answer.text.endsWith("!"), `status ${answer.status} ${JSON.stringify(answer.text)}`);
});

// ═════════════════════════════════════════════════════════════════════════════
const main = async () => {
  console.log(`bosun serve behaviours — router: ${COMMAND.join(" ")} serve`);
  sweepPorts();
  await sleep(300);
  const held = [];
  for (const port of ALL_PORTS) if (await listening(port)) held.push(port);
  if (held.length > 0) { console.log(`scratch ports already held: ${held.join(" ")}; not starting`); process.exit(2); }
  fs.rmSync(WORK, { recursive: true, force: true });
  fs.mkdirSync(WORK, { recursive: true });
  writeRegistry(baseRows());
  externalHolder = startStub([P.adopted]);
  wildcardHolder = startStub([P.wildcard, "--host", "0.0.0.0"]);
  await until(5000, async () => (await listening(P.adopted)) && (await listening(P.wildcard)));
  await startRouter();

  for (const c of cases) {
    if (ONLY && !c.name.startsWith(ONLY)) continue;
    current = c.name;
    console.log(`\n${c.name}  ${c.title}`);
    try { await c.body(); }
    catch (e) { check("the case ran to its end", false, e && e.stack ? e.stack.split("\n").slice(0, 3).join(" | ") : String(e)); }
  }

  await cleanup();
  const failed = results.filter((r) => !r.pass);
  const names = [...new Set(results.map((r) => r.name))];
  const failedNames = [...new Set(failed.map((r) => r.name))];
  console.log(`\n${names.length - failedNames.length} of ${names.length} behaviours hold (${results.length - failed.length} of ${results.length} checks).`);
  if (failedNames.length > 0) console.log(`Not held: ${failedNames.join(" ")}`);
  process.exit(failed.length === 0 ? 0 : 1);
};

process.on("SIGINT", async () => { await cleanup(); process.exit(130); });
main().catch(async (e) => { console.error(e); await cleanup(); process.exit(2); });
