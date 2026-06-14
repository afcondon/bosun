import { readFileSync } from "node:fs";
import yaml from "js-yaml";

// EffectFn1: called as f(path), performs the read, returns the parsed value
// (which is, at runtime, exactly an argonaut Json).
export const readYamlImpl = (path) => yaml.load(readFileSync(path, "utf8"));
export const readJsonImpl = (path) => JSON.parse(readFileSync(path, "utf8"));

// Effect (thunk): the user-supplied args after `node run.js` / `spago run`.
export const argv = () => process.argv.slice(2);
