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
export const readJsonUrlImpl = (url) =>
  JSON.parse(execSync(`curl -s --max-time 10 ${url}`, { maxBuffer: 64 * 1024 * 1024 }).toString());

// Effect (thunk): the user-supplied args after `node run.js` / `spago run`.
export const argv = () => process.argv.slice(2);
