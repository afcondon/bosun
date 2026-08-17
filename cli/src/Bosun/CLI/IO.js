import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import yaml from "js-yaml";

// ${BOSUN_ROOT} expansion — the portable-fixture seam. Bosun's NoAbsoluteCwd
// invariant deliberately requires service `cwd:` fields to be absolute (the
// executor builds `cd <abs> && cmd`), so a fixture cannot use relative cwds.
// This lets a compose/registry write `${BOSUN_ROOT}/fixtures/...` and travel:
// the token expands to an absolute anchor at read time, satisfying the
// invariant while decoupling the file from any one machine's checkout path.
// Default is process.cwd() — the supervisor's cwd is the repo root (start-
// router.sh cd's there), the same basis registry/fleet.json already resolves
// against. Override with BOSUN_ROOT. A no-op on composes with no token.
// (Twin of chair-server/src/Bosun/ChairServer/IO.js's expandBosunRoot.)
const expandBosunRoot = (text) =>
  text.replaceAll("${BOSUN_ROOT}", process.env.BOSUN_ROOT || process.cwd());

// EffectFn1: called as f(path), performs the read, returns the parsed value
// (which is, at runtime, exactly an argonaut Json).
export const readYamlImpl = (path) => yaml.load(expandBosunRoot(readFileSync(path, "utf8")));
export const readJsonImpl = (path) => JSON.parse(expandBosunRoot(readFileSync(path, "utf8")));

// Fetch + parse a JSON URL synchronously (the no-Aff seam — straight-line curl,
// no callbacks). Used by `bosun serve` to read the live Marginalia registry.
// `-f`: without it, a 5xx whose body is `{"error":…}` parses, ingests to zero
// services, and `bosun serve` prints "nothing to bind … Exiting." — a registry
// outage rendered as an empty registry. A source we REQUIRE should fail loudly;
// `getJsonUrl` below is the non-throwing form, for sources we merely ask.
export const readJsonUrlImpl = (url) =>
  JSON.parse(execSync(`curl -sS -f --max-time 10 ${url}`, { maxBuffer: 64 * 1024 * 1024 }).toString());

// Talk to a local daemon's control surface without throwing: an unreachable
// router is an OUTCOME (`bosun reload` must report it), not a crash. Same
// straight-line curl as readJsonUrlImpl; returns { ok, body, error }. A non-2xx
// with a JSON body still parses (no `-f`), so the daemon's own `{ok:false,…}`
// reaches the caller intact.
const jsonCurl = (args) => (url) => {
  try {
    // stdio pipes stderr rather than letting execSync forward it to ours: we
    // REPORT the failure, so curl must not also print it.
    const out = execSync(`curl -sS --max-time 8 ${args} ${url}`, {
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    }).toString();
    return { ok: true, body: out.trim() === "" ? null : JSON.parse(out), error: "" };
  } catch (e) {
    const stderr = e && e.stderr ? e.stderr.toString().trim() : "";
    return { ok: false, body: null, error: stderr || String((e && e.message) || e) };
  }
};

export const getJsonUrlImpl = jsonCurl("");
export const postJsonUrlImpl = jsonCurl("-X POST");

// Effect (thunk): the user-supplied args after `node run.js` / `spago run`.
export const argv = () => process.argv.slice(2);
