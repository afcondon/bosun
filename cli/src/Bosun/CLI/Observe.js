import { execSync } from "node:child_process";

// EffectFn3 (host, port, path) -> HTTP status code string; "000" on any failure
// (DNS, refused, timeout). Synchronous on purpose — the no-Aff seam.
export const probeHttpImpl = (host, port, path) => {
  try {
    const url = `http://${host}:${port}${path}`;
    return execSync(
      `curl -s -o /dev/null -w '%{http_code}' --max-time 3 ${url}`,
      { stdio: ["ignore", "pipe", "ignore"] }
    )
      .toString()
      .trim();
  } catch (e) {
    return "000";
  }
};

// EffectFn2 (host, port) -> reachable boolean. `nc -z` exits 0 if the TCP
// connect succeeds within the timeout.
export const probeTcpImpl = (host, port) => {
  try {
    execSync(`nc -z -w 3 ${host} ${port}`, { stdio: "ignore" });
    return true;
  } catch (e) {
    return false;
  }
};
