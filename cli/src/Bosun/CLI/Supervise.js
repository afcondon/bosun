// Resident half of `bosun supervise` — the watch-loop timer + the /state +
// /control HTTP surface. The DECISIONS (what to start/restart/stop) were already
// made upstream by the pure planner; this shim only fires the periodic tick and
// routes HTTP to the PS callbacks. Same surface shape as serve's controlRouter
// (CORS + JSON) so the Chair lights up against either mode unchanged.
import http from "node:http";

const INTERNAL_HOST = "127.0.0.1";
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type",
};

// EffectFn1 SuperviseConfig Unit — called once; runs forever (resident).
export const superviseImpl = (cfg) => {
  const tick = () => {
    try { cfg.tick(); }
    catch (e) { console.error(`  ✗ tick: ${e && e.message ? e.message : e}`); }
  };
  // periodic keep-alive reconcile; the initial bring-up already ran in PS.
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
      let msg;
      try { msg = cfg.control(verb, arg); }
      catch (e) { res.writeHead(500, CORS); res.end(String(e && e.message)); return; }
      res.writeHead(200, { "content-type": "application/json", ...CORS });
      res.end(JSON.stringify({ ok: true, message: msg }));
      return;
    }

    res.writeHead(404, { "content-type": "text/plain", ...CORS });
    res.end("not found\n");
  });

  server.on("error", (err) =>
    console.error(`  ✗ supervise /state :${cfg.statusPort} (${err.code || err.message})`));
  server.listen(cfg.statusPort, INTERNAL_HOST, () =>
    console.log(
      `  supervise: /state + /control on :${cfg.statusPort}, keep-alive tick ${cfg.intervalMs}ms. Ctrl-C to stop.`));
};
