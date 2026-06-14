import { execSync, spawn } from "node:child_process";

// EffectFn1 line -> { ok, code, message }.
//
// A backgrounded launch (line ends in `&`, e.g. `nohup … &`) is fire-and-forget:
// we `spawn` it detached with stdio ignored and `unref`, so we neither wait on
// nor hold its pipes (an inherited stdout pipe would otherwise hang us until the
// server exits). Its exit 0 means "dispatched" — actual health is the
// observation edge's job, not apply's. Everything else (docker, ssh) is a
// synchronous command: run it, capture output, report a non-zero exit.
export const execLineImpl = (line) => {
  if (/&\s*$/.test(line)) {
    try {
      spawn("/bin/sh", ["-c", line], { detached: true, stdio: "ignore" }).unref();
      return { ok: true, code: 0, message: "launched (backgrounded)" };
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
