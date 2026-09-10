import { execSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";

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

// EffectFn1 (pidFilePath) -> is any process in the recorded process GROUP alive?
// Reads the PGID `apply` recorded, then `kill(-pgid, 0)` — signal 0 is the
// POSIX existence check (no signal sent). The honest liveness signal for a
// UDP/socket/no-network daemon Bosun launched (es9/link/fh2). A missing file or
// a dead group reads as Down — never launched, or gone.
export const probePgidAliveImpl = (pidFile) => {
  try {
    if (!existsSync(pidFile)) return false;
    const pgid = parseInt(readFileSync(pidFile, "utf8").trim(), 10);
    if (!Number.isFinite(pgid) || pgid <= 1) return false;
    process.kill(-pgid, 0); // throws ESRCH if no process in the group
    return true;
  } catch (e) {
    return false;
  }
};

// EffectFn1 (socketPath) -> does the socket file exist? (Weak liveness — a stale
// socket can persist past the daemon, DeepStar A7 — so process-existence is
// preferred where the daemon is Bosun-launched; this is the fallback.)
export const probeSocketImpl = (socketPath) => {
  try {
    return existsSync(socketPath);
  } catch (e) {
    return false;
  }
};

// EffectFn1 (commandLine) -> did it exit 0? The HOST-side exec probe: the only
// reading that answers "is the service up, whoever started it". A non-zero exit,
// a timeout, or a missing binary all read false — never a throw, like every
// other probe here. 5s budget (a claim check shells out to lsof/deepstar; the
// 3s used for a network connect is tight for a process table walk).
export const probeExecImpl = (line) => {
  try {
    execSync(line, { stdio: "ignore", timeout: 5000 });
    return true;
  } catch (e) {
    return false;
  }
};
