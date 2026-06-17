import { readFileSync } from "node:fs";
import { execSync, spawn } from "node:child_process";
import yaml from "js-yaml";

// Node twins of the Go `Bosun_Conformance_ApplyCliMain_*` shims, so the full
// file-driven apply harness runs on both columns. `Json`'s runtime rep is the
// parsed JS value, so js-yaml / JSON.parse output is a `Json` directly.
export const readJsonImpl = (path) => JSON.parse(readFileSync(path, "utf8"));
export const readYamlImpl = (path) => yaml.load(readFileSync(path, "utf8"));

// argv after the program name + script (mirrors process.argv.slice(2)).
export const argv = () => process.argv.slice(2);

// Backgrounded launches (`&`) detach fire-and-forget; everything else is
// synchronous with captured output. (Identical to ApplyMain's exec twin.)
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
