// The resident-mode shim (docs/EXECUTORS.md) — the substrate-agnostic half of
// every resident `bosun` daemon: the watch-loop timer + the /state + /control
// HTTP surface. The DECISIONS (what to observe, start, restart, stop) are made
// upstream in PureScript; this shim only fires the periodic tick and routes
// HTTP to the PS callbacks. Same surface shape the Chair already speaks, so it
// lights up against any executor (process via supervise, docker, …) unchanged.
import http from "node:http";

// Effect Number — wall-clock ms at the seam (the pure core never reads the
// clock; it only receives `now`, so it stays conformance-deterministic).
export const nowMs = () => Date.now();

const INTERNAL_HOST = "127.0.0.1";
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type",
};

// EffectFn1 Resident Unit — called once; runs forever (resident).
export const residentImpl = (cfg) => {
  const tick = () => {
    try { cfg.tick(); }
    catch (e) { console.error(`  ✗ tick: ${e && e.message ? e.message : e}`); }
  };
  // periodic tick; the substrate's initial bring-up/observe already ran in PS.
  setInterval(tick, cfg.intervalMs);

  const server = http.createServer((req, res) => {
    const u = new URL(req.url, "http://localhost");
    if (req.method === "OPTIONS") { res.writeHead(204, CORS); res.end(); return; }

    if (req.method === "GET" && (u.pathname === "/state" || u.pathname === "/")) {
      let body;
      try { body = cfg.stateBody(); }
      catch (e) { res.writeHead(500, CORS); res.end(String(e && e.message)); return; }
      res.writeHead(200, { "content-type": "application/json", ...CORS });
      res.end(body);
      return;
    }

    if (req.method === "POST" && u.pathname.startsWith("/control/")) {
      const verb = u.pathname.slice("/control/".length);
      const arg = u.searchParams.get("service") || u.searchParams.get("group") || "";
      let out;
      try { out = cfg.control(verb, arg); }
      catch (e) {
        res.writeHead(500, { "content-type": "application/json", ...CORS });
        res.end(JSON.stringify({ ok: false, message: String((e && e.message) || e) }));
        return;
      }
      // The SUBSTRATE's verdict decides the status. This used to answer
      // `200 {ok:true}` for every non-throwing return, so "unknown control verb"
      // and "reload: rejected — …" arrived as successes; chair-server reads this
      // `ok` to decide whether a registration was routed, so the refusal was
      // being laundered into a confirmation one layer up.
      res.writeHead(out.ok ? 200 : 400, { "content-type": "application/json", ...CORS });
      res.end(JSON.stringify({ ok: !!out.ok, message: out.message }));
      return;
    }

    res.writeHead(404, { "content-type": "text/plain", ...CORS });
    res.end("not found\n");
  });

  server.on("error", (err) =>
    console.error(`  ✗ resident /state :${cfg.statusPort} (${err.code || err.message})`));
  server.listen(cfg.statusPort, INTERNAL_HOST, () =>
    console.log(
      `  resident: /state + /control on :${cfg.statusPort}, tick ${cfg.intervalMs}ms. Ctrl-C to stop.`));
};
