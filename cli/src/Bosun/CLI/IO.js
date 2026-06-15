import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import yaml from "js-yaml";

// EffectFn1: called as f(path), performs the read, returns the parsed value
// (which is, at runtime, exactly an argonaut Json).
export const readYamlImpl = (path) => yaml.load(readFileSync(path, "utf8"));
export const readJsonImpl = (path) => JSON.parse(readFileSync(path, "utf8"));

// Fetch + parse a JSON URL synchronously (the no-Aff seam — straight-line curl,
// no callbacks). Used by `bosun serve` to read the live Marginalia registry.
export const readJsonUrlImpl = (url) =>
  JSON.parse(execSync(`curl -s --max-time 10 ${url}`, { maxBuffer: 64 * 1024 * 1024 }).toString());

// Effect (thunk): the user-supplied args after `node run.js` / `spago run`.
export const argv = () => process.argv.slice(2);
