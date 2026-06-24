import { readFileSync, writeFileSync, renameSync, copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
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

// --- Registry-edit edge (2026-06-23: Marginalia → Bosun ownership) ---
// fleet.json is the source of truth for the dev-server registry. Override its
// location with BOSUN_FLEET_PATH for tests; the bosun-router compose sets the
// production path to bosun/registry/fleet.json.

const DEFAULT_FLEET_PATH = "/Users/afc/work/afc-work/ShapedSteer/bosun/registry/fleet.json";
const MARGINALIA_BASE = process.env.MARGINALIA_API || "http://andrews-mac-mini:3100";
const BOSUN_SERVE_URL = process.env.BOSUN_SERVE_URL || "http://localhost:3997";

export const fleetPath = () => process.env.BOSUN_FLEET_PATH || DEFAULT_FLEET_PATH;

export const readFleetImpl = () => JSON.parse(readFileSync(fleetPath(), "utf8"));

// Atomic write: serialise to a tmp file, fsync via writeFileSync semantics,
// then rename. Mirror the existing backup-on-edit convention by writing a
// rolling .bak alongside the live file (single slot — the git history is the
// long-tail audit). The temp + rename pattern guarantees readers never see a
// half-written fleet.json.
export const writeFleetImpl = (json) => {
  const path = fleetPath();
  const tmp = path + ".tmp";
  const bak = path + ".bak";
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  if (existsSync(path)) copyFileSync(path, bak);
  writeFileSync(tmp, JSON.stringify(json, null, 2) + "\n");
  renameSync(tmp, path);
};

// Best-effort POST :3997/control/reload — bosun-serve re-reads fleet.json and
// re-plans. Swallow failures; the disk write is the source of truth, and a
// crashed/down router will pick up the change on its next start.
export const reloadBosunServeImpl = () => {
  try {
    execSync(`curl -sS -X POST --max-time 5 ${BOSUN_SERVE_URL}/control/reload`, {
      maxBuffer: 64 * 1024,
      stdio: ["ignore", "ignore", "ignore"],
    });
  } catch (_e) {
    // intentional no-op — see comment above
  }
};

// EffectFn1(Int → Json): fetch a Marginalia project record. Called at POST
// /api/projects/:id/servers time only, to denormalise projectName + projectSlug
// into the fleet.json row. Reads stay independent.
export const fetchMarginaliaProjectImpl = (id) =>
  JSON.parse(
    execSync(`curl -sS --max-time 8 ${MARGINALIA_BASE}/api/projects/${id}`, {
      maxBuffer: 1024 * 1024,
    }).toString()
  );
