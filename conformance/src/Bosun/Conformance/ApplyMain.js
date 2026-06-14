import { execSync, spawn } from "node:child_process";

// Node twin of the Go `Bosun_Conformance_ApplyMain_execLineImpl` shim, so the
// harness runs on both columns. Backgrounded launches (`&`) are detached
// fire-and-forget; everything else is synchronous with captured output.
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
    const out = execSync(line, { stdio: ["ignore", "pipe", "pipe"], timeout: 20000 }).toString();
    return { ok: true, code: 0, message: out.trim() };
  } catch (e) {
    return {
      ok: false,
      code: typeof e.status === "number" ? e.status : 1,
      message: ((e.stderr && e.stderr.toString()) || e.message || "").trim(),
    };
  }
};
