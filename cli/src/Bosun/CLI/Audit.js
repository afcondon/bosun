// One-shot audit foreign for `bosun serve --audit`: spawn each route's backend,
// wait for its internal port to accept a TCP connection, tear it down, and
// report. Synchronous (spawnSync) — the no-Aff seam — and self-cleaning.

import { spawn, spawnSync } from "node:child_process";

const READY_TIMEOUT_S = 8;

// EffectFn1: uncurried — runs on auditImpl(routes), returns the result array.
export const auditImpl = (routes) => {
  const results = [];
  for (const route of routes) {
    const t0 = Date.now();
    // spawn the backend in its own group so we can kill the whole tree after.
    const child = spawn("bash", ["-c", route.launchCommand], {
      cwd: route.cwd,
      stdio: "ignore",
      detached: true,
    });
    // poll the internal port via bash's /dev/tcp (portable, TCP-level, no nc dep).
    const probe = spawnSync(
      "bash",
      ["-c",
        `for i in $(seq 1 ${READY_TIMEOUT_S * 5}); do ` +
        `(echo > /dev/tcp/127.0.0.1/${route.internalPort}) 2>/dev/null && exit 0; ` +
        `sleep 0.2; done; exit 1`],
      { timeout: (READY_TIMEOUT_S + 4) * 1000 }
    );
    const ok = probe.status === 0;
    const ms = Date.now() - t0;
    // tear down the spawned backend (whole process group).
    try { process.kill(-child.pid, "SIGTERM"); }
    catch (_) { try { child.kill("SIGTERM"); } catch (_) {} }
    results.push({
      serviceId: route.serviceId,
      publicPort: route.publicPort,
      ok,
      ms,
      message: ok ? "came up" : `did not bind :${route.internalPort} within ${READY_TIMEOUT_S}s`,
    });
  }
  return results;
};
