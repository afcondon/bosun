import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import yaml from "js-yaml";

// EffectFn1: f(path) reads + parses, returning a value that IS an argonaut Json.
export const readYamlImpl = (path) => yaml.load(readFileSync(path, "utf8"));
export const readJsonImpl = (path) => JSON.parse(readFileSync(path, "utf8"));

// Fetch + parse a JSON URL synchronously (the no-Aff seam — straight-line curl).
// Lets the Chair point at the live Marginalia registry (/api/ports).
export const readJsonUrlImpl = (url) =>
  JSON.parse(execSync(`curl -s --max-time 10 ${url}`, { maxBuffer: 64 * 1024 * 1024 }).toString());

// Effect Int: BOSUN_CHAIR_SERVER_PORT or the default 3022.
export const resolvePort = () => {
  const raw = process.env.BOSUN_CHAIR_SERVER_PORT;
  const n = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? n : 3022;
};
