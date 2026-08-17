import { execSync, spawn } from "node:child_process";
import { openSync } from "node:fs";

// EffectFn1 line -> { ok, code, message }.
//
// A backgrounded launch (line ends in `&`, e.g. `nohup … &`) is fire-and-forget:
// we `spawn` it detached and `unref`, so we neither wait on nor hold its pipes
// (an inherited stdout pipe would otherwise hang us until the server exits). Its
// exit 0 means "dispatched" — actual health is the observation edge's job, not
// apply's. Everything else (docker, ssh) is a synchronous command: run it,
// capture output, report a non-zero exit.
//
// `ok: true` here is a WEAK claim and cannot be strengthened at this seam: only
// a synchronous spawn failure can make it false, so a bad `cwd`, a missing
// binary or an EADDRINUSE exit all die inside the shell moments later and this
// still says "launched". What it must NOT do is throw the reason away — stdio
// used to be `"ignore"`, which is how a service could relaunch-fail forever
// with the explanation existing nowhere. It goes to a log file instead, named
// per launch so the observation edge's "Failed" has something to point at.
const LAUNCH_LOG = "/tmp/bosun-launch.log";

export const execLineImpl = (line) => {
  if (/&\s*$/.test(line)) {
    try {
      let out = "ignore";
      try { out = openSync(LAUNCH_LOG, "a"); } catch (_) { /* unwritable: fall back */ }
      const child = spawn("/bin/sh", ["-c", line], { detached: true, stdio: ["ignore", out, out] });
      // An async spawn failure emits `error`; unhandled, it takes the whole
      // resident daemon down — a supervisor killed by the thing it supervises
      // failing to start.
      child.on("error", (e) => console.error(`  ✗ launch failed: ${line} — ${e && e.message ? e.message : e}`));
      child.unref();
      return { ok: true, code: 0, message: `launched (backgrounded; output → ${LAUNCH_LOG})` };
    } catch (e) {
      return { ok: false, code: 1, message: (e.message || "").trim() };
    }
  }
  try {
    const out = execSync(line, {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 20000,
    }).toString();
    return { ok: true, code: 0, message: out.trim() };
  } catch (e) {
    return {
      ok: false,
      code: typeof e.status === "number" ? e.status : 1,
      message: ((e.stderr && e.stderr.toString()) || e.message || "").trim(),
    };
  }
};
